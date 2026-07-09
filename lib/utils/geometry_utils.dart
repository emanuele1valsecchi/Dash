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
}