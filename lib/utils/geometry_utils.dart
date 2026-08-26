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
  static double pointToSegmentDistanceMeters(LatLng p, LatLng a, LatLng b) =>
      _projectOntoSegment(p, a, b).distanceMeters;

  /// Projects [p] onto segment [a]-[b], returning both how far along the
  /// segment the nearest point lies (`t`, clamped to 0..1) and how far [p]
  /// is from that point in metres.
  ///
  /// [pointToSegmentDistanceMeters] only ever needed the distance and threw
  /// `t` away; [routeGuidance] needs `t` as well, to locate a runner *along*
  /// a route rather than just near it. Both share this one implementation so
  /// the loop-detection math above and the direction arrow can't drift apart.
  static ({double t, double distanceMeters}) _projectOntoSegment(
    LatLng p,
    LatLng a,
    LatLng b,
  ) {
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
    return (t: t, distanceMeters: sqrt(dx * dx + dy * dy));
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

  /// Locates [position] against a planned [route] and works out which way the
  /// runner should be heading — the data behind the live direction arrow on
  /// the run-tracking screen.
  ///
  /// Deliberately a *bearing* guide, not turn-by-turn navigation: it needs no
  /// street names or routing-service instructions (ORS returns `steps`, but
  /// `RoutingService` discards them at parse time), works on any polyline
  /// including hand-drawn and multi-hop stitched ones, and degrades to "head
  /// that way" instead of failing outright.
  ///
  /// Pass the previous call's [RouteGuidance.segmentIndex] back in as
  /// [previousSegmentIndex]. Without it, nearest-point matching alone breaks
  /// on exactly the routes Dash cares most about: a **closed loop** runs back
  /// past its own start, so a runner completing a lap matches the very first
  /// segment again and gets told to run the whole loop over. The hint
  /// restricts matching to a window starting near the last known position,
  /// and is abandoned for a full re-scan whenever nothing in that window is
  /// within [offRouteThresholdMeters] — so genuinely leaving the route and
  /// rejoining it elsewhere still re-acquires.
  ///
  /// When off route, [RouteGuidance.targetBearingDegrees] points back at the
  /// nearest point on the route rather than further along it — "get back on"
  /// before "carry on".
  ///
  /// Returns null when [route] is too short to have a direction at all.
  static RouteGuidance? routeGuidance(
    List<LatLng> route,
    LatLng position, {
    double lookaheadMeters = 30,
    double offRouteThresholdMeters = 25,
    double turnScanMeters = 300,
    double turnThresholdDegrees = 35,
    int? previousSegmentIndex,
    int searchWindowSegments = 40,
  }) {
    if (route.length < 2) return null;
    const dist = Distance();
    final lastSegment = route.length - 2;

    ({int index, double t, double distanceMeters}) scan(int from, int to) {
      var bestIndex = from;
      var bestT = 0.0;
      var bestDist = double.infinity;
      for (int i = from; i <= to; i++) {
        final p = _projectOntoSegment(position, route[i], route[i + 1]);
        if (p.distanceMeters < bestDist) {
          bestDist = p.distanceMeters;
          bestIndex = i;
          bestT = p.t;
        }
      }
      return (index: bestIndex, t: bestT, distanceMeters: bestDist);
    }

    var match = previousSegmentIndex == null
        ? scan(0, lastSegment)
        : scan(
            // A little slack backwards absorbs GPS jitter around a vertex.
            max(0, previousSegmentIndex - 2),
            min(lastSegment, previousSegmentIndex + searchWindowSegments),
          );
    if (previousSegmentIndex != null &&
        match.distanceMeters > offRouteThresholdMeters) {
      match = scan(0, lastSegment);
    }

    final segStart = route[match.index];
    final segEnd = route[match.index + 1];
    final anchor = LatLng(
      segStart.latitude + (segEnd.latitude - segStart.latitude) * match.t,
      segStart.longitude + (segEnd.longitude - segStart.longitude) * match.t,
    );

    var remaining = dist(anchor, segEnd);
    for (int i = match.index + 1; i <= lastSegment; i++) {
      remaining += dist(route[i], route[i + 1]);
    }

    final isOffRoute = match.distanceMeters > offRouteThresholdMeters;

    // Aiming at a point *ahead* rather than at the next vertex keeps the arrow
    // steady through dense road-snapped polylines, where consecutive vertices
    // can be only a metre or two apart. Off route, aim at the anchor instead —
    // get back on the line before carrying on along it.
    final target = isOffRoute
        ? anchor
        : _pointAhead(route, match.index, anchor, lookaheadMeters);

    // Only meaningful while actually on the route; off it, the next turn is
    // not the runner's problem yet.
    final turn = isOffRoute
        ? null
        : _findNextTurn(
            route,
            match.index,
            anchor,
            maxScanMeters: turnScanMeters,
            thresholdDegrees: turnThresholdDegrees,
          );

    // Standing essentially on the target (arrived, or off-route by less than
    // the GPS noise floor) makes a position→target bearing pure noise — fall
    // back to the route's own local direction of travel so the arrow holds
    // still instead of spinning.
    final bearing = dist(position, target) < 1.0
        ? bearingDegrees(segStart, segEnd)
        : bearingDegrees(position, target);

    return RouteGuidance(
      targetBearingDegrees: bearing,
      offRouteMeters: match.distanceMeters,
      isOffRoute: isOffRoute,
      distanceRemainingMeters: remaining,
      distanceToTurnMeters: turn?.distanceMeters,
      turnAngleDegrees: turn?.angleDegrees,
      anchor: anchor,
      segmentIndex: match.index,
    );
  }

  /// The point [distanceMeters] further along [route] from [from], which must
  /// lie on segment [fromSegment]. Clamps to the route's final point when the
  /// walk runs off the end.
  static LatLng _pointAhead(
    List<LatLng> route,
    int fromSegment,
    LatLng from,
    double distanceMeters,
  ) {
    const dist = Distance();
    var walked = 0.0;
    var cursor = from;
    for (int i = fromSegment + 1; i < route.length; i++) {
      final next = route[i];
      final step = dist(cursor, next);
      if (walked + step >= distanceMeters) {
        final t = step > 0 ? (distanceMeters - walked) / step : 0.0;
        return LatLng(
          cursor.latitude + (next.latitude - cursor.latitude) * t,
          cursor.longitude + (next.longitude - cursor.longitude) * t,
        );
      }
      walked += step;
      cursor = next;
    }
    return route.last;
  }

  /// Finds the next significant change of direction ahead of [anchor], as a
  /// distance along the route and a signed angle (negative = left).
  ///
  /// Derived from the polyline's own geometry rather than routing-service
  /// instructions: ORS does return `steps`, but `RoutingService` discards them
  /// at parse time, and a route assembled from many separate ORS calls (every
  /// searched or hand-drawn route in this app) would need its instruction
  /// lists concatenated and re-indexed against the merged polyline before they
  /// could be used. Geometry works uniformly on all of them.
  ///
  /// Scans **evenly-spaced samples** rather than vertices, because vertex
  /// spacing carries no meaning: a road-snapped polyline rounds a corner with
  /// a dozen vertices each turning a few degrees — no single one of which
  /// looks like a turn — while a hand-tapped route may turn 90° at one vertex.
  /// Comparing bearings measured over a fixed [bearingWindowMeters] baseline
  /// makes both read the same, and rejects GPS-scale wobble automatically.
  ///
  /// Returns null when the route runs straight for the whole scan range, or
  /// is too short to sample.
  static ({double distanceMeters, double angleDegrees})? _findNextTurn(
    List<LatLng> route,
    int fromSegment,
    LatLng anchor, {
    required double maxScanMeters,
    required double thresholdDegrees,
    double sampleStepMeters = 5,
    double bearingWindowMeters = 20,
  }) {
    const dist = Distance();
    final span = maxScanMeters + bearingWindowMeters;

    // One forward pass emitting a sample every [sampleStepMeters]; the inner
    // while-loop handles a single long segment spanning several samples.
    final samples = <LatLng>[anchor];
    var walked = 0.0;
    var nextSampleAt = sampleStepMeters;
    var cursor = anchor;
    outer:
    for (int i = fromSegment + 1; i < route.length; i++) {
      final next = route[i];
      final step = dist(cursor, next);
      while (walked + step >= nextSampleAt) {
        final t = step > 0 ? (nextSampleAt - walked) / step : 0.0;
        samples.add(LatLng(
          cursor.latitude + (next.latitude - cursor.latitude) * t,
          cursor.longitude + (next.longitude - cursor.longitude) * t,
        ));
        nextSampleAt += sampleStepMeters;
        if (nextSampleAt > span) break outer;
      }
      walked += step;
      cursor = next;
    }

    final window = (bearingWindowMeters / sampleStepMeters).round();
    if (samples.length < window + 2) return null;

    final baseBearing = bearingDegrees(samples[0], samples[window]);
    for (int i = 1; i + window < samples.length; i++) {
      final delta = _signedAngleDeltaDegrees(
        baseBearing,
        bearingDegrees(samples[i], samples[i + window]),
      );
      if (delta.abs() >= thresholdDegrees) {
        // The threshold is crossed as the bearing window *begins* to span the
        // corner, so `delta` here is only part of the turn — a true 90° corner
        // trips at roughly 45° and would read as a gentle bend. Keep scanning
        // while the turn develops in the same direction and report its peak,
        // but keep the *distance* at the crossing: that is where the turn
        // starts to matter to the runner.
        // Stop once the angle *plateaus* rather than once it decreases: on a
        // loop that turns the same way at every corner the delta climbs
        // 90°→180°→270° monotonically, so breaking only on a decrease would
        // swallow every subsequent corner into this one. A window's worth of
        // samples with no meaningful growth means the bearing window has
        // cleared the corner and the route is straight again.
        var peak = delta;
        var flat = 0;
        for (int j = i + 1; j + window < samples.length; j++) {
          final next = _signedAngleDeltaDegrees(
            baseBearing,
            bearingDegrees(samples[j], samples[j + window]),
          );
          if (next.sign != delta.sign) break;
          if (next.abs() > peak.abs() + 0.5) {
            peak = next;
            flat = 0;
          } else if (++flat >= window) {
            break;
          }
        }
        return (distanceMeters: i * sampleStepMeters, angleDegrees: peak);
      }
    }
    return null;
  }

  /// Shortest signed rotation from [from] to [to], in (-180, 180] —
  /// negative turns left (anticlockwise), positive right.
  static double _signedAngleDeltaDegrees(double from, double to) =>
      ((to - from + 540) % 360) - 180;
}

/// Where a runner is relative to a planned route, and which way to head next.
///
/// Produced by [GeometryUtils.routeGuidance]. A plain value object with no
/// Flutter or screen-state dependency, so the same computation can drive a
/// smartwatch face later without dragging `RunTrackingPage` along with it.
class RouteGuidance {
  /// Absolute compass bearing (0° = north, increasing clockwise) the runner
  /// should be heading in. To render an arrow relative to where the runner is
  /// actually facing, rotate by `targetBearingDegrees - currentHeading`.
  final double targetBearingDegrees;

  /// Perpendicular distance from the nearest point on the route.
  final double offRouteMeters;

  /// True when [offRouteMeters] exceeded the caller's threshold. While set,
  /// [targetBearingDegrees] points back at [anchor].
  final bool isOffRoute;

  /// Remaining route distance from [anchor] to the route's final point.
  final double distanceRemainingMeters;

  /// Distance along the route to the next significant change of direction, or
  /// null when the route runs straight for the whole scan range (or the runner
  /// is off it, where the next turn isn't the immediate problem).
  final double? distanceToTurnMeters;

  /// Signed angle of that turn — negative turns left, positive right. Null
  /// exactly when [distanceToTurnMeters] is.
  final double? turnAngleDegrees;

  /// The runner's position projected onto the route — the nearest point on it.
  final LatLng anchor;

  /// Index of the segment [anchor] lies on; segment `i` spans
  /// `route[i]`→`route[i + 1]`. Feed back as
  /// [GeometryUtils.routeGuidance]'s `previousSegmentIndex` on the next call.
  final int segmentIndex;

  const RouteGuidance({
    required this.targetBearingDegrees,
    required this.offRouteMeters,
    required this.isOffRoute,
    required this.distanceRemainingMeters,
    required this.distanceToTurnMeters,
    required this.turnAngleDegrees,
    required this.anchor,
    required this.segmentIndex,
  });
}