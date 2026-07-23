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
        options: HttpsCallableOptions(timeout: const Duration(seconds: 10)),
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
  /// Returns a non-empty list; falls back to a single straight-line segment
  /// if the network or API is unreachable.
  static Future<List<RouteSegment>> fetchAlternatives(
    LatLng origin,
    LatLng destination, {
    int targetCount = 3,
  }) async {
    try {
      final callable = _functions.httpsCallable(
        'orsRoute',
        options: HttpsCallableOptions(timeout: const Duration(seconds: 12)),
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
        return [straightLine(origin, destination)];
      }

      final json = _asStringMap(data['body']);
      final features = json['features'] as List<dynamic>;
      if (features.isEmpty) return [straightLine(origin, destination)];

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
    } catch (_) {
      return [straightLine(origin, destination)];
    }
  }

  /// Straight-line fallback used when ORS is unreachable or returns no route.
  static RouteSegment straightLine(LatLng from, LatLng to) {
    final meters = const Distance()(from, to);
    return RouteSegment(polyline: [from, to], distanceMeters: meters);
  }
}