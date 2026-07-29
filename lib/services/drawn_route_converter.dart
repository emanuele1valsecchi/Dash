import 'package:latlong2/latlong.dart';

import 'routing_service.dart';

/// Outcome of [DrawnRouteConverter.convert]. Sealed so page code has to
/// handle every case explicitly — success, "not really a stroke", and each
/// failure kind — with no nullable in-between that could quietly turn into
/// a straight-line fallback again.
sealed class DrawnRouteConversionResult {
  const DrawnRouteConversionResult();
}

/// The gesture was too short to count as a real shape (accidental
/// tap/jitter). Pages ignore it silently, exactly like the old
/// `_minDrawPathLengthMeters` rejection did.
class DrawnRouteTooShort extends DrawnRouteConversionResult {
  const DrawnRouteTooShort();
}

/// The stroke was matched: [waypoints] and [segments] arrive already in the
/// page-state shape (`segments.length == waypoints.length - 1`, consecutive
/// segment polylines sharing their junction vertex), ready to be committed
/// one segment at a time with `_checkSelfIntersection()` between appends so
/// loop closure behaves exactly as it did with per-hop fetches.
class DrawnRouteSuccess extends DrawnRouteConversionResult {
  final List<LatLng> waypoints;
  final List<RouteSegment> segments;

  const DrawnRouteSuccess({required this.waypoints, required this.segments});

  double get distanceMeters =>
      segments.fold(0.0, (sum, seg) => sum + seg.distanceMeters);
}

enum DrawnRouteFailureKind {
  /// Actively throttled (HTTP 429) — retry after a short wait.
  rateLimited,

  /// ORS daily quota spent (HTTP 403) — retrying is pointless today.
  quotaExhausted,

  /// No walkable match for this stroke — redraw closer to real paths.
  noRoute,

  /// Routing backend unreachable (offline/timeout).
  network,

  /// Backend answered with an unexpected error/payload.
  serviceError,
}

/// The stroke could not be converted. Never carries partial geometry: a
/// failed conversion produces no route at all (acceptance criterion — an
/// explicit error beats a silently wrong route that only reveals itself
/// mid-run).
class DrawnRouteFailure extends DrawnRouteConversionResult {
  final DrawnRouteFailureKind kind;

  /// From the upstream `Retry-After` header, when the backend provided one.
  final Duration? retryAfter;

  /// Backend-provided detail (for logs/debugging, not for verbatim display).
  final String? detail;

  const DrawnRouteFailure(this.kind, {this.retryAfter, this.detail});

  /// Whether an immediate user-triggered retry has any chance of a
  /// different outcome. Quota exhaustion won't clear until the rolling
  /// 24 h window does, so offering "Retry" for it would just mislead.
  bool get isRetryable => kind != DrawnRouteFailureKind.quotaExhausted;
}

/// Converts a raw freehand stroke (one point per pixel of finger movement)
/// into a routed `waypoints + segments` pair with a SINGLE network
/// operation, via [RoutingService.matchDrawnPath].
///
/// This replaces the per-page `_sampleDrawnPath` / `_fetchRoadRouteWithRetry`
/// / `_convertDrawingToRoute` pipelines that chained one point-to-point ORS
/// request per sample (15–90 requests per stroke in the worst case — the
/// direct cause of the shared-quota exhaustion that broke routing app-wide,
/// and of every straight-line-across-a-lake fallback). Shared by
/// `route_create_page.dart` and `test_run_creator_page.dart` so the fix
/// exists exactly once (CLAUDE.md: business/data logic belongs in services,
/// not widgets).
///
/// Request bound per stroke: 1 client→function call, ≤3 upstream routing
/// calls (enforced in functions/routing.js). On any failure the caller gets
/// a typed [DrawnRouteFailure] and NO geometry — never a straight line.
class DrawnRouteConverter {
  const DrawnRouteConverter._();

  /// Below this total drawn length, the gesture is treated as an accidental
  /// tap/jitter rather than a real shape and produces no waypoints at all.
  /// (Same threshold and behavior as the old `_minDrawPathLengthMeters`.)
  static const double minStrokeLengthMeters = 20;

  /// Client-side decimation only bounds the upload payload — unlike the old
  /// 40 m sampling this deliberately stays DENSE: a map matcher works
  /// better the more shape it sees, so points are dropped only when they
  /// add no shape (closer than this to the previous kept point).
  static const double _minSpacingMeters = 5;

  /// Hard cap on points sent to the function (payload sanity; the function
  /// clamps again per backend).
  static const int _maxUploadPoints = 2000;

  /// The matched polyline is split back into consecutive segments of
  /// roughly this length so the pages' incremental loop detection
  /// (`_checkSelfIntersection` compares each new segment against the
  /// previous ones — it never inspects a single segment against itself)
  /// keeps working exactly as it did when every ORS hop was its own
  /// segment.
  static const double _targetSegmentLengthMeters = 200;
  static const int _maxSegments = 40;

  /// Sanity bound: a matched route this much longer than the drawn stroke
  /// means the matcher had to invent a huge detour the user never drew
  /// (e.g. a stroke across a river with the nearest bridge far away).
  /// Rejecting it keeps the headline distance number honest — the whole
  /// point of the feature — at the cost of asking the user to redraw.
  static const double _maxMatchedToDrawnRatio = 3.0;

  static Future<DrawnRouteConversionResult> convert(
    List<LatLng> rawStroke,
  ) async {
    final stroke = _capCount(
      _decimate(rawStroke, _minSpacingMeters),
      _maxUploadPoints,
    );
    final drawnLength = _pathLengthMeters(stroke);
    if (stroke.length < 2 || drawnLength < minStrokeLengthMeters) {
      return const DrawnRouteTooShort();
    }

    final result = await RoutingService.matchDrawnPath(stroke);
    switch (result) {
      case DrawMatchSuccess success:
        final polyline = _dedupeConsecutive(success.polyline);
        if (polyline.length < 2) {
          return const DrawnRouteFailure(DrawnRouteFailureKind.noRoute);
        }
        final matchedLength = _pathLengthMeters(polyline);
        if (matchedLength > drawnLength * _maxMatchedToDrawnRatio) {
          return const DrawnRouteFailure(
            DrawnRouteFailureKind.noRoute,
            detail: 'matched route implausibly longer than the drawn stroke',
          );
        }
        final split = _splitIntoSegments(polyline);
        return DrawnRouteSuccess(
          waypoints: split.waypoints,
          segments: split.segments,
        );
      case DrawMatchRateLimited r:
        return DrawnRouteFailure(
          DrawnRouteFailureKind.rateLimited,
          retryAfter: r.retryAfter,
        );
      case DrawMatchQuotaExhausted():
        return const DrawnRouteFailure(DrawnRouteFailureKind.quotaExhausted);
      case DrawMatchNoRoute r:
        return DrawnRouteFailure(
          DrawnRouteFailureKind.noRoute,
          detail: r.reason,
        );
      case DrawMatchNetworkError():
        return const DrawnRouteFailure(DrawnRouteFailureKind.network);
      case DrawMatchServiceError():
        return const DrawnRouteFailure(DrawnRouteFailureKind.serviceError);
    }
  }

  // ── Geometry helpers ──────────────────────────────────────────────────────

  static double _pathLengthMeters(List<LatLng> points) {
    const dist = Distance();
    double total = 0;
    for (int i = 1; i < points.length; i++) {
      total += dist(points[i - 1], points[i]);
    }
    return total;
  }

  /// Drops points closer than [minSpacing] to the previously kept one;
  /// first and last points always survive.
  static List<LatLng> _decimate(List<LatLng> points, double minSpacing) {
    if (points.length <= 2) return List<LatLng>.from(points);
    const dist = Distance();
    final kept = <LatLng>[points.first];
    for (int i = 1; i < points.length - 1; i++) {
      if (dist(kept.last, points[i]) >= minSpacing) kept.add(points[i]);
    }
    kept.add(points.last);
    return kept;
  }

  /// Uniform-stride reduction to at most [maxCount] points (endpoints kept).
  static List<LatLng> _capCount(List<LatLng> points, int maxCount) {
    if (points.length <= maxCount) return points;
    return [
      for (int i = 0; i < maxCount; i++)
        points[(i * (points.length - 1) / (maxCount - 1)).round()],
    ];
  }

  static List<LatLng> _dedupeConsecutive(List<LatLng> points) {
    final out = <LatLng>[];
    for (final p in points) {
      if (out.isEmpty ||
          out.last.latitude != p.latitude ||
          out.last.longitude != p.longitude) {
        out.add(p);
      }
    }
    return out;
  }

  /// Splits one continuous matched polyline into consecutive
  /// [RouteSegment]s (~[_targetSegmentLengthMeters] each, junction vertex
  /// shared between neighbours) plus the matching waypoint list. Waypoints
  /// are actual vertices of the matched geometry, so — unlike the old raw
  /// finger samples — the start/finish pins now sit exactly ON the route.
  static ({List<LatLng> waypoints, List<RouteSegment> segments})
      _splitIntoSegments(List<LatLng> polyline) {
    const dist = Distance();
    final total = _pathLengthMeters(polyline);
    int segmentCount = (total / _targetSegmentLengthMeters)
        .round()
        .clamp(1, _maxSegments)
        .toInt(); // num.clamp returns num — pin it back to int
    // Can't have more segments than edges in the geometry.
    if (segmentCount > polyline.length - 1) segmentCount = polyline.length - 1;
    final targetLength = total / segmentCount;

    final waypoints = <LatLng>[polyline.first];
    final segments = <RouteSegment>[];
    var current = <LatLng>[polyline.first];
    double currentLength = 0;

    for (int i = 1; i < polyline.length; i++) {
      currentLength += dist(polyline[i - 1], polyline[i]);
      current.add(polyline[i]);
      final isLastVertex = i == polyline.length - 1;
      final quotaFull = currentLength >= targetLength &&
          segments.length < segmentCount - 1;
      if (isLastVertex || quotaFull) {
        segments.add(
          RouteSegment(polyline: current, distanceMeters: currentLength),
        );
        waypoints.add(polyline[i]);
        current = <LatLng>[polyline[i]];
        currentLength = 0;
      }
    }
    return (waypoints: waypoints, segments: segments);
  }
}