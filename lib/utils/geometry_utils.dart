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

  /// Scans a live GPS breadcrumb trail for a point that closes a loop with
  /// the trail's current tip.
  ///
  /// Walks backward from the end of [breadcrumb] accumulating on-trail
  /// distance; once that distance passes [minPathMeters] it starts testing
  /// each candidate's straight-line distance to the tip against
  /// [radiusMeters]. This two-part gate (walk far enough away, then come
  /// back close enough) avoids flagging consecutive noisy GPS fixes — which
  /// are already close together — as a false "loop".
  ///
  /// Only points from index [activeStart] onward are considered, so a
  /// previously-closed loop can't be re-closed against the same trail.
  ///
  /// Returns the index of the closing point, or null if no loop is closed.
  static int? findLoopClosureIndex(
    List<LatLng> breadcrumb, {
    required int activeStart,
    double radiusMeters = 18,
    double minPathMeters = 80,
  }) {
    final n = breadcrumb.length;
    if (n - activeStart < 4) return null;

    const dist = Distance();
    final tip = breadcrumb[n - 1];

    double pathBehind = 0;
    for (int i = n - 2; i >= activeStart; i--) {
      pathBehind += dist(breadcrumb[i], breadcrumb[i + 1]);
      if (pathBehind < minPathMeters) continue;
      if (dist(breadcrumb[i], tip) <= radiusMeters) {
        return i;
      }
    }
    return null;
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
}