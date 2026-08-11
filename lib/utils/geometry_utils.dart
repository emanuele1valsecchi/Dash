import 'dart:math';

import 'package:latlong2/latlong.dart';

class GeometryUtils {
  /// Finds the intersection point of segments (a1→a2) and (b1→b2).
  ///
  /// Returns null when:
  ///   • the segments are parallel / collinear (denom ≈ 0)
  ///   • the intersection falls at or very near an endpoint (ε = 1e-4)
  ///
  /// The endpoint exclusion prevents false positives at shared waypoint
  /// junctions, where consecutive ORS polylines begin/end at the same node.
  static LatLng? segmentIntersection(
    LatLng a1,
    LatLng a2,
    LatLng b1,
    LatLng b2,
  ) {
    final x1 = a1.longitude, y1 = a1.latitude;
    final x2 = a2.longitude, y2 = a2.latitude;
    final x3 = b1.longitude, y3 = b1.latitude;
    final x4 = b2.longitude, y4 = b2.latitude;

    final denom = (x1 - x2) * (y3 - y4) - (y1 - y2) * (x3 - x4);
    if (denom.abs() < 1e-12) return null; // parallel or coincident

    final t = ((x1 - x3) * (y3 - y4) - (y1 - y3) * (x3 - x4)) / denom;
    final u = -((x1 - x2) * (y1 - y3) - (y1 - y2) * (x1 - x3)) / denom;

    const eps = 1e-4;
    if (t > eps && t < 1.0 - eps && u > eps && u < 1.0 - eps) {
      return LatLng(y1 + t * (y2 - y1), x1 + t * (x2 - x1));
    }
    return null;
  }

  /// Distance in metres from [p] to the nearest point on segment [a]-[b].
  ///
  /// Uses the same local-planar (longitude/latitude-as-Cartesian, scaled to
  /// metres at the segment's own latitude) approximation as
  /// [segmentIntersection] — accurate for the short distances loop-closure
  /// checks operate over.
  ///
  /// This exists specifically to catch a case [segmentIntersection] can't:
  /// an existing waypoint sitting exactly on (not just crossing) another
  /// segment's interior — e.g. a loop's closing line happening to pass
  /// straight through an earlier pin. That point coincides with one
  /// segment's endpoint (the waypoint itself) by construction, which
  /// [segmentIntersection]'s endpoint exclusion deliberately filters out to
  /// avoid false positives at shared junctions — a real "point lies on this
  /// line" needs a distance check instead of a two-line-crossing one.
  static double pointToSegmentDistanceMeters(LatLng p, LatLng a, LatLng b) {
    final centerLat = (a.latitude + b.latitude) / 2;
    const metersPerDegreeLat = 110540.0;
    final metersPerDegreeLng = 111320.0 * cos(centerLat * pi / 180);

    final px = (p.longitude - a.longitude) * metersPerDegreeLng;
    final py = (p.latitude - a.latitude) * metersPerDegreeLat;
    final bx = (b.longitude - a.longitude) * metersPerDegreeLng;
    final by = (b.latitude - a.latitude) * metersPerDegreeLat;

    final segLenSq = bx * bx + by * by;
    var t = segLenSq > 0 ? (px * bx + py * by) / segLenSq : 0.0;
    t = t.clamp(0.0, 1.0);

    final dx = px - t * bx;
    final dy = py - t * by;
    return sqrt(dx * dx + dy * dy);
  }

  /// Computes the area of a geographic polygon in square metres.
  ///
  /// Uses the planar Shoelace formula on locally-projected Cartesian
  /// coordinates. Accurate within ~1 % for city-scale areas (≤ ~100 km²).
  ///
  /// Relative coordinates (offset from the first vertex) are used instead of
  /// absolute degree-converted values to avoid floating-point precision loss
  /// when the cross-product of large numbers is computed.
  static double polygonAreaM2(List<LatLng> points) {
    if (points.length < 3) return 0;

    final refLat = points.first.latitude;
    final refLng = points.first.longitude;

    // Scale factors at the polygon's centroid latitude.
    final centerLat =
        points.fold(0.0, (s, p) => s + p.latitude) / points.length;
    const metersPerDegreeLat = 110540.0;
    final metersPerDegreeLng = 111320.0 * cos(centerLat * pi / 180);

    double area = 0;
    final n = points.length;
    for (int i = 0; i < n; i++) {
      final j = (i + 1) % n;
      final xi = (points[i].longitude - refLng) * metersPerDegreeLng;
      final yi = (points[i].latitude - refLat) * metersPerDegreeLat;
      final xj = (points[j].longitude - refLng) * metersPerDegreeLng;
      final yj = (points[j].latitude - refLat) * metersPerDegreeLat;
      area += xi * yj - xj * yi;
    }
    return (area / 2).abs();
  }

  /// Formats an area in square metres as a string in km² — always, never
  /// m² or hectares, so every area shown anywhere in the app (loop-closure
  /// banners, claimed-area details, run results) uses one consistent unit.
  /// Decimal precision scales with magnitude rather than staying fixed at 2
  /// places, since a fixed 2 decimals would round most ordinary loop sizes
  /// (a few hundred to a few thousand m²) straight down to "0.00 km²".
  static String formatAreaKm2(double areaM2) {
    final km2 = areaM2 / 1000000;
    if (km2 >= 1) return '${km2.toStringAsFixed(2)} km²';
    if (km2 >= 0.01) return '${km2.toStringAsFixed(3)} km²';
    return '${km2.toStringAsFixed(4)} km²';
  }

  /// Scans a live GPS breadcrumb trail for the point that closes the
  /// *biggest* loop with the trail's current tip.
  ///
  /// Walks backward from the end of [breadcrumb] accumulating on-trail
  /// distance; once that distance passes [minPathMeters] it starts testing
  /// each candidate's straight-line distance to the tip against
  /// [radiusMeters]. This two-part gate (walk far enough away, then come
  /// back close enough) avoids flagging consecutive noisy GPS fixes — which
  /// are already close together — as a false "loop".
  ///
  /// The whole trail is considered, including points that already belong to
  /// a previously-closed loop — re-crossing old ground (e.g. running a
  /// bigger loop around one already closed) must still register. Every
  /// qualifying point is checked, not just the first one found, and the
  /// *earliest* one (farthest back along the trail) wins, since that's the
  /// point that encloses the most area — callers that need to avoid
  /// double-counting against a loop already recorded for an overlapping
  /// stretch of trail should dedupe on the returned range themselves (see
  /// `RunTrackingPage._checkLoopClosure`).
  ///
  /// Returns the index of the closing point, or null if no loop is closed.
  static int? findLoopClosureIndex(
    List<LatLng> breadcrumb, {
    double radiusMeters = 18,
    double minPathMeters = 80,
  }) {
    final n = breadcrumb.length;
    if (n < 4) return null;

    const dist = Distance();
    final tip = breadcrumb[n - 1];

    double pathBehind = 0;
    int? earliestClosure;
    for (int i = n - 2; i >= 0; i--) {
      pathBehind += dist(breadcrumb[i], breadcrumb[i + 1]);
      if (pathBehind < minPathMeters) continue;
      if (dist(breadcrumb[i], tip) <= radiusMeters) {
        earliestClosure = i;
      }
    }
    return earliestClosure;
  }

  /// Cosmetic Catmull-Rom smoothing for polyline rendering — inserts curved
  /// interpolation between each pair of [points] so real-world turns render
  /// as smooth curves instead of angular vertices (a Google-Maps-style
  /// look), while still passing through every original point exactly, so
  /// the drawn line never strays from the actual routed path. Purely for how
  /// a route line is drawn — not used for any distance/loop-closure math.
  static List<LatLng> smoothPolyline(List<LatLng> points, {int subdivisions = 6}) {
    if (points.length < 3) return points;

    // Centripetal parametrization (alpha = 0.5) avoids the self-intersecting
    // loops a uniform Catmull-Rom can produce on unevenly-spaced points —
    // e.g. dense OSM nodes on a curve next to sparse ones on a straight
    // stretch, which road-snapped ORS polylines mix constantly.
    double knotDelta(LatLng a, LatLng b) {
      final dLat = b.latitude - a.latitude;
      final dLng = b.longitude - a.longitude;
      return max(sqrt(sqrt(dLat * dLat + dLng * dLng)), 1e-6);
    }

    // Phantom points mirrored across each real endpoint, so the first and
    // last real segments get curved too instead of only the interior ones.
    final first = points.first;
    final second = points[1];
    final last = points.last;
    final secondLast = points[points.length - 2];
    final padded = <LatLng>[
      LatLng(2 * first.latitude - second.latitude, 2 * first.longitude - second.longitude),
      ...points,
      LatLng(2 * last.latitude - secondLast.latitude, 2 * last.longitude - secondLast.longitude),
    ];

    final result = <LatLng>[first];
    for (int i = 0; i < points.length - 1; i++) {
      final p0 = padded[i];
      final p1 = padded[i + 1];
      final p2 = padded[i + 2];
      final p3 = padded[i + 3];

      final t1 = knotDelta(p0, p1);
      final t2 = t1 + knotDelta(p1, p2);
      final t3 = t2 + knotDelta(p2, p3);

      for (int s = 1; s <= subdivisions; s++) {
        final t = t1 + (t2 - t1) * (s / subdivisions);
        result.add(_catmullRomPoint(p0, p1, p2, p3, t1, t2, t3, t));
      }
    }
    return result;
  }

  /// One point along the Barry-Goldman recursive Catmull-Rom formula, for
  /// `t` in `[t1, t2]` (knot `t0` is always 0 — see [smoothPolyline]).
  static LatLng _catmullRomPoint(
    LatLng p0,
    LatLng p1,
    LatLng p2,
    LatLng p3,
    double t1,
    double t2,
    double t3,
    double t,
  ) {
    double interp(double v0, double v1, double a, double b) =>
        v0 + (v1 - v0) * (t - a) / (b - a);

    double axis(double p0v, double p1v, double p2v, double p3v) {
      final a1 = interp(p0v, p1v, 0, t1);
      final a2 = interp(p1v, p2v, t1, t2);
      final a3 = interp(p2v, p3v, t2, t3);
      final b1 = interp(a1, a2, 0, t2);
      final b2 = interp(a2, a3, t1, t3);
      return interp(b1, b2, t1, t2);
    }

    return LatLng(
      axis(p0.latitude, p1.latitude, p2.latitude, p3.latitude),
      axis(p0.longitude, p1.longitude, p2.longitude, p3.longitude),
    );
  }

  /// Initial compass bearing (0°=north, 90°=east, increasing clockwise)
  /// travelling from [from] to [to] — the standard great-circle bearing
  /// formula.
  static double bearingDegrees(LatLng from, LatLng to) {
    final lat1 = from.latitude * pi / 180;
    final lat2 = to.latitude * pi / 180;
    final dLng = (to.longitude - from.longitude) * pi / 180;
    final y = sin(dLng) * cos(lat2);
    final x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLng);
    return (atan2(y, x) * 180 / pi + 360) % 360;
  }

  /// [count] points evenly spaced along [path] by *cumulative distance*
  /// (not vertex index — a GPS breadcrumb trail or road-snapped polyline is
  /// never evenly sampled), each paired with the local direction-of-travel
  /// bearing there. Used to place directional arrow markers along a route
  /// so a viewer can tell which way it was run, not just where it starts
  /// and ends. Spacing skips both of [path]'s own endpoints (`k` runs
  /// `1..count` against `count + 1` equal spans) since those typically
  /// already have their own start/finish markers.
  static List<({LatLng point, double bearingDegrees})> arrowPositions(
    List<LatLng> path, {
    required int count,
  }) {
    if (path.length < 2 || count <= 0) return const [];
    const dist = Distance();

    final cumulative = <double>[0];
    for (int i = 1; i < path.length; i++) {
      cumulative.add(cumulative.last + dist(path[i - 1], path[i]));
    }
    final total = cumulative.last;
    if (total <= 0) return const [];

    final result = <({LatLng point, double bearingDegrees})>[];
    for (int k = 1; k <= count; k++) {
      final target = total * k / (count + 1);
      int seg = 1;
      while (seg < cumulative.length - 1 && cumulative[seg] < target) {
        seg++;
      }
      final segStart = path[seg - 1];
      final segEnd = path[seg];
      final segLen = cumulative[seg] - cumulative[seg - 1];
      final t = segLen > 0 ? (target - cumulative[seg - 1]) / segLen : 0.0;
      result.add((
        point: LatLng(
          segStart.latitude + (segEnd.latitude - segStart.latitude) * t,
          segStart.longitude + (segEnd.longitude - segStart.longitude) * t,
        ),
        bearingDegrees: bearingDegrees(segStart, segEnd),
      ));
    }
    return result;
  }
}