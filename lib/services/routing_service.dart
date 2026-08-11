import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';

class RouteSegment {
  final List<LatLng> polyline;
  final double distanceMeters;

  const RouteSegment({required this.polyline, required this.distanceMeters});
}

/// Thrown by [RoutingService.fetchRoute] instead of returning null when
/// [RoutingService.fetchRoute]'s `throwOnRateLimit` is set and ORS responds
/// 429 — callers that chain many sequential requests (freehand-draw
/// conversion) need to tell "the API is rejecting us right now, don't
/// retry" apart from an ordinary one-off failure, since retrying or
/// reaching for an alternate route during an active rate-limit window just
/// burns more of the shared quota for no better a result.
class RoutingRateLimitedException implements Exception {
  const RoutingRateLimitedException();
}

/// Outcome of [RoutingService.matchDrawnPath]. A sealed hierarchy instead of
/// `RouteSegment?` because the freehand-draw conversion must react
/// *differently* to different failures (429 minutely rate limit vs. 403
/// daily-quota exhaustion vs. "no walkable match" vs. plain network
/// trouble) — the old nullable contract collapsed all of those into one
/// indistinguishable `null`, which is how a 403 ended up being retried and
/// amplified against a wall. Exhaustive `switch`ing over this type is
/// compiler-enforced, so no failure kind can silently fall through to a
/// straight-line fallback again.
sealed class DrawMatchResult {
  const DrawMatchResult();
}

/// The whole stroke was matched to the walkable network in one operation.
class DrawMatchSuccess extends DrawMatchResult {
  /// Road-snapped geometry for the entire stroke, start to finish.
  final List<LatLng> polyline;

  /// Walking distance along [polyline] as reported by the routing backend.
  final double distanceMeters;

  const DrawMatchSuccess({required this.polyline, required this.distanceMeters});
}

/// The backend is actively throttling (HTTP 429 — ORS's 40 req/min sliding
/// window, or the Valhalla instance's own limiter). Retrying after a short
/// wait can work; retrying immediately cannot.
class DrawMatchRateLimited extends DrawMatchResult {
  /// Parsed from the upstream `Retry-After` header when present.
  final Duration? retryAfter;

  const DrawMatchRateLimited({this.retryAfter});
}

/// The shared ORS *daily* quota is spent (HTTP 403 — 2000 directions/day on
/// the free plan, rolling 24 h window). Distinct from [DrawMatchRateLimited]
/// because retrying is pointless until the window rolls over: the UI should
/// say so instead of offering a retry.
class DrawMatchQuotaExhausted extends DrawMatchResult {
  const DrawMatchQuotaExhausted();
}

/// The service was reachable and healthy but found no walkable match for
/// this stroke (drawn over water/private ground, or with a gap no path
/// crosses). Redrawing closer to real paths is the fix, not retrying.
class DrawMatchNoRoute extends DrawMatchResult {
  final String? reason;

  const DrawMatchNoRoute({this.reason});
}

/// The backend answered, but with an unexpected error or malformed payload.
class DrawMatchServiceError extends DrawMatchResult {
  const DrawMatchServiceError();
}

/// The backend could not be reached at all (offline, timeout, function
/// unavailable).
class DrawMatchNetworkError extends DrawMatchResult {
  const DrawMatchNetworkError();
}

/// Calls the OpenRouteService foot-walking endpoint (via the `orsRoute`
/// Cloud Function, see functions/routing.js) and returns a road-snapped
/// polyline plus the walking distance in metres between [origin] and [destination].
///
///   ORS uses a dedicated foot-walking profile that honours OSM tags such as
///   highway=footway/path/pedestrian and access=yes on park paths.
///
/// The ORS API key never reaches the client: `orsRoute` holds it server-side
/// (Secret Manager) and forwards ORS's own HTTP status + JSON body back
/// verbatim, so the parsing/429 handling below is unchanged from when this
/// called ORS directly — only the transport moved.
///
/// Returns null on any failure; callers fall back to a straight-line segment.
class RoutingService {
  static final FirebaseFunctions _functions =
      FirebaseFunctions.instanceFor(region: 'europe-west1');

  static Map<String, dynamic> _asStringMap(dynamic v) =>
      Map<String, dynamic>.from(v as Map);

  /// Client-side callable timeout for a single `orsRoute` call (any of
  /// its modes). Must stay comfortably above the Cloud Function's own
  /// server-side fetch timeout (`ORS_TIMEOUT_MS` = 12s in
  /// functions/routing.js) — otherwise the client gives up and throws
  /// *before* the function itself would, and that gets treated identically
  /// to an ordinary routing failure (no route found), not a timeout. This
  /// was previously 10s for `fetchRoute` (below the server's 12s) and 12s
  /// for `fetchAlternatives` (right at the edge) — both a race the client
  /// could lose on any call that took ORS a little longer than usual,
  /// which is more likely for longer legs. 18s leaves ~6s of margin over
  /// the server's own timeout for Cloud Function invocation overhead
  /// (cold starts, etc.), while still being short enough that a genuinely
  /// unreachable service fails within a reasonable UX budget.
  static const Duration _callTimeout = Duration(seconds: 18);

  /// [throwOnRateLimit] makes an HTTP 429 throw [RoutingRateLimitedException]
  /// instead of just returning null — off by default so existing callers
  /// (single-tap pin placement, pin deletion, snap-to-close) keep their
  /// original "null on any failure" contract. Only freehand-draw conversion
  /// opts in, since it's the one caller that chains many sequential requests
  /// and needs to react to active throttling instead of retrying into it.
  static Future<RouteSegment?> fetchRoute(
      LatLng origin, LatLng destination, {bool throwOnRateLimit = false}) async {
    try {
      final callable = _functions.httpsCallable(
        'orsRoute',
        options: HttpsCallableOptions(timeout: _callTimeout),
      );
      final result = await callable.call(<String, dynamic>{
        'origin': {'lat': origin.latitude, 'lng': origin.longitude},
        'destination': {'lat': destination.latitude, 'lng': destination.longitude},
      });

      final data = _asStringMap(result.data);
      final statusCode = data['status'] as int;

      if (statusCode != 200) {
        debugPrint(
          'RoutingService.fetchRoute: HTTP $statusCode for '
          '(${origin.latitude},${origin.longitude}) -> '
          '(${destination.latitude},${destination.longitude})',
        );
        if (throwOnRateLimit && statusCode == 429) {
          throw const RoutingRateLimitedException();
        }
        return null;
      }

      // ORS returns a GeoJSON FeatureCollection.
      // Structure:
      //   features[0].geometry.coordinates  → List<[lon, lat]>
      //   features[0].properties.summary.distance → metres (double)
      final json = _asStringMap(data['body']);
      final features = json['features'] as List<dynamic>;
      if (features.isEmpty) return null;

      final feature = _asStringMap(features[0]);
      final props = _asStringMap(feature['properties']);
      final summary = _asStringMap(props['summary']);
      final double distance = (summary['distance'] as num).toDouble();

      final geometry = _asStringMap(feature['geometry']);
      final rawCoords = geometry['coordinates'] as List<dynamic>;

      // GeoJSON coordinates are [longitude, latitude] — flip to LatLng(lat, lng).
      final polyline = rawCoords
          .map((c) => LatLng(
                (c[1] as num).toDouble(),
                (c[0] as num).toDouble(),
              ))
          .toList();

      return RouteSegment(polyline: polyline, distanceMeters: distance);
    } on RoutingRateLimitedException {
      rethrow;
    } catch (e) {
      debugPrint(
        'RoutingService.fetchRoute: $e for '
        '(${origin.latitude},${origin.longitude}) -> '
        '(${destination.latitude},${destination.longitude})',
      );
      return null;
    }
  }

  /// Requests up to [targetCount] alternative foot-walking routes from ORS
  /// via the same `orsRoute` proxy (its POST/geojson mode — the GET endpoint
  /// does not support alternatives).
  ///
  /// By default, returns a non-empty list, falling back to a single
  /// straight-line segment if the network or API is unreachable — this is
  /// the original contract, preserved for any future caller that just wants
  /// *something* to draw. [throwOnRateLimit]/[allowStraightLineFallback]
  /// (both opt-in, mirroring [fetchRoute]'s own `throwOnRateLimit`) let a
  /// caller that's about to filter/present these as vetted results — route
  /// search, not route creation — tell a real HTTP 429 apart from an
  /// ordinary failure, and refuse the straight-line fallback outright so a
  /// failure can never be mistaken for a genuine road-snapped alternative.
  static Future<List<RouteSegment>> fetchAlternatives(
    LatLng origin,
    LatLng destination, {
    int targetCount = 3,
    bool throwOnRateLimit = false,
    bool allowStraightLineFallback = true,
  }) async {
    List<RouteSegment> fallback() =>
        allowStraightLineFallback ? [straightLine(origin, destination)] : [];

    try {
      final callable = _functions.httpsCallable(
        'orsRoute',
        options: HttpsCallableOptions(timeout: _callTimeout),
      );
      final result = await callable.call(<String, dynamic>{
        'origin': {'lat': origin.latitude, 'lng': origin.longitude},
        'destination': {'lat': destination.latitude, 'lng': destination.longitude},
        'mode': 'alternatives',
        'targetCount': targetCount,
      });

      final data = _asStringMap(result.data);
      final statusCode = data['status'] as int;
      if (statusCode != 200) {
        debugPrint(
          'RoutingService.fetchAlternatives: HTTP $statusCode for '
          '(${origin.latitude},${origin.longitude}) -> '
          '(${destination.latitude},${destination.longitude})',
        );
        if (throwOnRateLimit && statusCode == 429) {
          throw const RoutingRateLimitedException();
        }
        return fallback();
      }

      final json = _asStringMap(data['body']);
      final features = json['features'] as List<dynamic>;
      if (features.isEmpty) return fallback();

      return features.map((f) {
        final feature = _asStringMap(f);
        final props = _asStringMap(feature['properties']);
        final summary = _asStringMap(props['summary']);
        final dist = (summary['distance'] as num).toDouble();
        final coords =
            _asStringMap(feature['geometry'])['coordinates'] as List<dynamic>;
        final poly = coords
            .map((c) => LatLng(
                  (c[1] as num).toDouble(),
                  (c[0] as num).toDouble(),
                ))
            .toList();
        return RouteSegment(polyline: poly, distanceMeters: dist);
      }).toList();
    } on RoutingRateLimitedException {
      rethrow;
    } catch (e) {
      debugPrint(
        'RoutingService.fetchAlternatives: $e for '
        '(${origin.latitude},${origin.longitude}) -> '
        '(${destination.latitude},${destination.longitude})',
      );
      return fallback();
    }
  }

  /// Requests one closed foot-walking loop of roughly [lengthMeters]
  /// starting and ending at [start], via the `orsRoute` proxy's
  /// `round_trip` mode (ORS's native `options.round_trip` — the routing
  /// engine itself grows the loop out of the real road network, so unlike
  /// a chain of [fetchRoute] calls through synthetic offset waypoints it
  /// can't strand across rivers or highways, and one call replaces three).
  ///
  /// [seed] varies the loop's overall direction (different seeds →
  /// geometrically different candidate loops); [points] its roundness
  /// (higher = rounder — more enclosed area for the same distance). ORS
  /// documents `length` as a preferred value, not a guarantee: callers
  /// that need a tolerance re-request with the length rescaled by the
  /// measured ratio, keeping the same [seed] so the loop grows/shrinks in
  /// place instead of jumping direction.
  ///
  /// Same contract as [fetchRoute]: null on any failure, and
  /// [throwOnRateLimit] opts an HTTP 429 into
  /// [RoutingRateLimitedException] instead — route search's loop
  /// generator fires several of these in parallel and must stop probing
  /// into an active rate-limit window rather than retry into it.
  static Future<RouteSegment?> fetchRoundTrip(
    LatLng start, {
    required double lengthMeters,
    int points = 5,
    int seed = 0,
    bool throwOnRateLimit = false,
  }) async {
    try {
      final callable = _functions.httpsCallable(
        'orsRoute',
        options: HttpsCallableOptions(timeout: _callTimeout),
      );
      final result = await callable.call(<String, dynamic>{
        'origin': {'lat': start.latitude, 'lng': start.longitude},
        'mode': 'round_trip',
        'lengthMeters': lengthMeters,
        'points': points,
        'seed': seed,
      });

      final data = _asStringMap(result.data);
      final statusCode = data['status'] as int;
      if (statusCode != 200) {
        debugPrint(
          'RoutingService.fetchRoundTrip: HTTP $statusCode for '
          '(${start.latitude},${start.longitude}) '
          'length=${lengthMeters.round()}m seed=$seed',
        );
        if (throwOnRateLimit && statusCode == 429) {
          throw const RoutingRateLimitedException();
        }
        return null;
      }

      // Same GeoJSON FeatureCollection shape as the other directions
      // responses — one feature carrying the whole loop.
      final json = _asStringMap(data['body']);
      final features = json['features'] as List<dynamic>;
      if (features.isEmpty) return null;

      final feature = _asStringMap(features[0]);
      final props = _asStringMap(feature['properties']);
      final summary = _asStringMap(props['summary']);
      final double distance = (summary['distance'] as num).toDouble();

      final geometry = _asStringMap(feature['geometry']);
      final rawCoords = geometry['coordinates'] as List<dynamic>;
      final polyline = rawCoords
          .map((c) => LatLng(
                (c[1] as num).toDouble(),
                (c[0] as num).toDouble(),
              ))
          .toList();
      if (polyline.length < 2) return null;

      return RouteSegment(polyline: polyline, distanceMeters: distance);
    } on RoutingRateLimitedException {
      rethrow;
    } catch (e) {
      debugPrint(
        'RoutingService.fetchRoundTrip: $e for '
        '(${start.latitude},${start.longitude}) '
        'length=${lengthMeters.round()}m seed=$seed',
      );
      return null;
    }
  }

  /// Converts a whole freehand-drawn stroke into one road-snapped walking
  /// route via the `matchDrawnPath` Cloud Function (functions/routing.js),
  /// which map-matches the full polyline in a single upstream operation —
  /// replacing the old chain of 15–90 sequential [fetchRoute] calls per
  /// stroke that exhausted the shared ORS quota.
  ///
  /// The function normalizes both backends (Valhalla trace_route / ORS
  /// multi-waypoint directions) into one response shape, so this method has
  /// a single parser and — unlike [fetchRoute] — NEVER returns null and
  /// NEVER falls back to a straight line: every outcome is an explicit
  /// [DrawMatchResult] case the caller must handle. Server-side request
  /// bound: at most 3 upstream calls per invocation (see routing.js).
  ///
  /// [stroke] should be the lightly decimated finger path (see
  /// DrawnRouteConverter, which is the intended caller), not the raw
  /// one-point-per-pixel list.
  static Future<DrawMatchResult> matchDrawnPath(List<LatLng> stroke) async {
    try {
      final callable = _functions.httpsCallable(
        'matchDrawnPath',
        // Generous relative to the 5–10 s UX budget: worst case the server
        // makes two upstream attempts at 12 s each; the drawing UI shows a
        // progress indicator for the (rare) slow tail.
        options: HttpsCallableOptions(timeout: const Duration(seconds: 30)),
      );
      final result = await callable.call(<String, dynamic>{
        'points': [
          for (final p in stroke) {'lat': p.latitude, 'lng': p.longitude},
        ],
      });

      final data = _asStringMap(result.data);
      final status = data['status'] as String?;
      switch (status) {
        case 'ok':
          final raw = data['polyline'] as List<dynamic>;
          final polyline = raw
              .map((c) => LatLng(
                    (c[0] as num).toDouble(),
                    (c[1] as num).toDouble(),
                  ))
              .toList();
          if (polyline.length < 2) {
            return const DrawMatchNoRoute(reason: 'empty geometry');
          }
          return DrawMatchSuccess(
            polyline: polyline,
            distanceMeters: (data['distanceMeters'] as num).toDouble(),
          );
        case 'rate_limited':
          final seconds = data['retryAfterSeconds'];
          return DrawMatchRateLimited(
            retryAfter:
                seconds is num ? Duration(seconds: seconds.toInt()) : null,
          );
        case 'quota_exhausted':
          return const DrawMatchQuotaExhausted();
        case 'no_route':
          return DrawMatchNoRoute(reason: data['message'] as String?);
        default:
          return const DrawMatchServiceError();
      }
    } catch (e) {
      // Covers the callable's HttpsError('unavailable') (upstream
      // unreachable), transport timeouts, and any malformed payload — all
      // of which mean the same thing to the drawing UI: try again later.
      debugPrint('RoutingService.matchDrawnPath: $e');
      return const DrawMatchNetworkError();
    }
  }

  /// Straight-line fallback used when ORS is unreachable or returns no route.
  static RouteSegment straightLine(LatLng from, LatLng to) {
    final meters = const Distance()(from, to);
    return RouteSegment(polyline: [from, to], distanceMeters: meters);
  }
}