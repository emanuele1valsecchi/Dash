import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import '../services/routing_service.dart';
import 'geometry_utils.dart';

/// Every loop a route has closed so far.
///
/// Replaces the four parallel lists this state used to be kept in
/// (`_loopPolygons` / `_loopAreasM2` / `_loopRangeStart` / `_loopRangeEnd`),
/// which had to be added to, filtered and copied in lockstep in five separate
/// places — a shape where dropping one list's entry and not another's is a
/// silent corruption rather than a compile error.
///
/// Immutable: every operation returns a new instance, so a caller can compare
/// identity to know whether anything actually changed.
class ClosedLoops {
  /// The closed loop polygons, in the order they were recorded.
  final List<List<LatLng>> polygons;

  /// Enclosed area of each polygon, in square metres.
  final List<double> areasM2;

  /// The `_segments` index range each polygon was built from. Two loops whose
  /// ranges overlap *may* be the same ground — but only the geometry can say
  /// so; see [RouteLoops.finalise].
  final List<int> rangeStart;
  final List<int> rangeEnd;

  const ClosedLoops({
    required this.polygons,
    required this.areasM2,
    required this.rangeStart,
    required this.rangeEnd,
  });

  const ClosedLoops.empty()
      : polygons = const [],
        areasM2 = const [],
        rangeStart = const [],
        rangeEnd = const [];

  int get length => polygons.length;
  bool get isEmpty => polygons.isEmpty;
  bool get isNotEmpty => polygons.isNotEmpty;

  /// Summed enclosed area of every recorded loop.
  double get totalAreaM2 => areasM2.fold(0.0, (a, b) => a + b);

  /// A deep copy, for the undo history — a shallow one would let a later
  /// mutation reach back into a snapshot.
  ClosedLoops copy() => ClosedLoops(
        polygons: polygons.map(List<LatLng>.from).toList(),
        areasM2: List<double>.from(areasM2),
        rangeStart: List<int>.from(rangeStart),
        rangeEnd: List<int>.from(rangeEnd),
      );
}

/// Loop detection for a *planned* route — the pin-dropped or freehand-drawn
/// path on the route-creation map.
///
/// Pure functions over a segment list, with no widget, map or network
/// dependency, so the rules below can be tested directly. They were
/// previously private methods on `_RouteCreatePageState`, which no test could
/// reach: the screen it lived in opens a `FlutterMap`, a GPS stream and a
/// Firestore listener.
///
/// **This is not the same code as the live-run detection.** A run closes
/// loops from a GPS breadcrumb trail via
/// [GeometryUtils.findLoopClosureIndex]; a planned route closes them from
/// road-snapped *segments*, where a crossing can happen anywhere along a
/// segment rather than at a recorded point. The two share only the low-level
/// primitives. The supersede and mirror rules below are duplicated in
/// `RunSessionController` and should eventually be shared — they have already
/// had to be fixed twice, once in each place.
abstract final class RouteLoops {
  /// How close two points must be to count as the route touching itself.
  static const double proximityThresholdMeters = 5.0;

  /// Below this, a "loop" is a GPS-scale wobble rather than an enclosed area.
  static const double minLoopAreaM2 = 50.0;

  /// Searches the most recently added segment (`segments.last`) against every
  /// other segment in the route for a self-intersection, and returns the one
  /// enclosing the largest polygon — or null if none reaches [minLoopAreaM2].
  ///
  /// Pure search, no side effects: shared by an ordinary pin/drawn segment
  /// and by a snap-to-waypoint close, since the newly added *closing* segment
  /// can itself cross back through even earlier ground the snap target does
  /// not reach — e.g. closing back to a middle waypoint with a line that
  /// happens to pass through an earlier pin — and that bigger polygon must
  /// still win over the smaller, direct "snap target to tip" one.
  static ({List<LatLng> polygon, int rangeStart})? findBestSelfIntersection(
    List<RouteSegment> segments,
  ) {
    if (segments.length < 2) return null;

    final newPoly = segments.last.polyline;
    final prevCount = segments.length - 1;

    // Every candidate crossing found against the *entire* route (not just
    // segments added since the last loop closed) is considered, and the one
    // enclosing the largest area wins — always the biggest shape the route's
    // current geometry can produce, rather than whichever crossing happened
    // to be found first. This is also what lets a bigger loop drawn around
    // an already-closed smaller one register at all: the old scoping used to
    // exclude that smaller loop's own segments from the search entirely.
    //
    // The only segment that can share an exact coordinate with the new one
    // is the literal previous segment (routing always continues from the
    // current tip), so the shared-junction false-positive guards below only
    // need to trim vertices/edges near that one segment — every other, older
    // segment is genuinely separate geometry, and a match against it is a
    // real crossing.
    List<LatLng>? bestPolygon;
    double bestArea = 0;
    int bestStartSegment = 0;

    for (int si = 0; si < prevCount; si++) {
      final existPoly = segments[si].polyline;
      final isAdjacent = si == prevCount - 1;

      // Skip vertices too close to the shared junction to avoid false
      // positives.
      final existEnd = isAdjacent
          ? (existPoly.length - 3).clamp(0, existPoly.length)
          : existPoly.length;
      final newStart = isAdjacent ? 3 : 1;

      if (newStart >= newPoly.length || existEnd <= 0) continue;

      void considerCandidate(List<LatLng> polygon) {
        if (polygon.length < 3) return;
        final area = GeometryUtils.polygonAreaM2(polygon);
        if (area < minLoopAreaM2 || area <= bestArea) return;
        bestArea = area;
        bestPolygon = polygon;
        bestStartSegment = si;
      }

      // ── 1. Vertex proximity ──────────────────────────────────────────────
      for (int ni = newStart; ni < newPoly.length; ni++) {
        for (int ei = 0; ei < existEnd; ei++) {
          if (const Distance()(newPoly[ni], existPoly[ei]) <=
              proximityThresholdMeters) {
            considerCandidate(
              polygonFromIntersection(segments, existPoly[ei], si, ei, ni),
            );
          }
        }
      }

      // ── 2. Geometric edge crossing ───────────────────────────────────────
      // The new segment's very first edge is only excluded when `si` is the
      // literal adjacent segment (shares its start point) — for any other,
      // older segment there is no shared-junction concern, and a straight-
      // line closing segment (only 2 points, e.g. the routing fallback) has
      // no *other* edge to test, so skipping it unconditionally would mean
      // never checking it against anything.
      final edgeEnd = isAdjacent
          ? (existPoly.length - 2).clamp(0, existPoly.length - 1)
          : existPoly.length - 1;
      final crossNewStart = isAdjacent ? 1 : 0;

      for (int ei = 0; ei < edgeEnd; ei++) {
        for (int ni = crossNewStart; ni < newPoly.length - 1; ni++) {
          final pt = GeometryUtils.segmentIntersection(
            existPoly[ei],
            existPoly[ei + 1],
            newPoly[ni],
            newPoly[ni + 1],
          );
          if (pt != null) {
            considerCandidate(
              polygonFromIntersection(segments, pt, si, ei, ni),
            );
          }
        }
      }

      // ── 3. Vertex lying on the other polyline's interior ─────────────────
      // Neither check above catches a real waypoint sitting exactly *on*
      // (not just near, and not crossing) another edge — e.g. a closing line
      // that happens to pass straight through an earlier pin. Proximity only
      // compares vertex-to-vertex, and edge crossing deliberately excludes
      // matches at a segment's own endpoints, which is exactly where an
      // existing vertex sitting on a line registers. A plain
      // distance-to-segment check catches it from both sides: an old vertex
      // on a new edge, and a new vertex on an old edge.
      for (int ei = 0; ei < existEnd; ei++) {
        for (int ni = crossNewStart; ni < newPoly.length - 1; ni++) {
          if (GeometryUtils.pointToSegmentDistanceMeters(
                existPoly[ei],
                newPoly[ni],
                newPoly[ni + 1],
              ) <=
              proximityThresholdMeters) {
            considerCandidate(
              polygonFromIntersection(segments, existPoly[ei], si, ei, ni),
            );
          }
        }
      }
      for (int ni = newStart; ni < newPoly.length; ni++) {
        for (int ei = 0; ei < edgeEnd; ei++) {
          if (GeometryUtils.pointToSegmentDistanceMeters(
                newPoly[ni],
                existPoly[ei],
                existPoly[ei + 1],
              ) <=
              proximityThresholdMeters) {
            considerCandidate(
              polygonFromIntersection(segments, newPoly[ni], si, ei, ni),
            );
          }
        }
      }
    }

    final polygon = bestPolygon;
    if (polygon == null) return null;
    return (polygon: polygon, rangeStart: bestStartSegment);
  }

  /// Searches segment [testIdx] against every *other* segment in the route
  /// (both earlier and later — unlike [findBestSelfIntersection], which only
  /// ever looks backwards from the last segment) for a self-intersection,
  /// returning the one enclosing the largest polygon, or null.
  ///
  /// Mirrors [findBestSelfIntersection]'s three strategies exactly, just
  /// without the "the new segment is always last" assumption baked in — a
  /// dragged pin's touched segment can sit anywhere in the route.
  static ({List<LatLng> polygon, int rangeStart, int rangeEnd})?
      findLoopThroughSegment(List<RouteSegment> segments, int testIdx) {
    List<LatLng>? bestPolygon;
    double bestArea = 0;
    int bestA = 0;
    int bestB = 0;

    for (int si = 0; si < segments.length; si++) {
      if (si == testIdx) continue;
      final a = math.min(si, testIdx);
      final b = math.max(si, testIdx);
      final polyA = segments[a].polyline;
      final polyB = segments[b].polyline;
      final isAdjacent = b == a + 1;

      // Trim vertices right at the shared junction when the two segments are
      // literally consecutive (segment `a` ends exactly where `b` begins) —
      // same reasoning as the adjacency trim above, just applicable on either
      // side here instead of always "the previous segment".
      final aEnd = isAdjacent
          ? (polyA.length - 3).clamp(0, polyA.length)
          : polyA.length;
      final bStart = isAdjacent ? 3 : 0;
      if (bStart >= polyB.length || aEnd <= 0) continue;

      void considerCandidate(LatLng point, int edgeA, int edgeB) {
        final polygon =
            polygonBetweenSegments(segments, point, a, edgeA, b, edgeB);
        if (polygon.length < 3) return;
        final area = GeometryUtils.polygonAreaM2(polygon);
        if (area < minLoopAreaM2 || area <= bestArea) return;
        bestArea = area;
        bestPolygon = polygon;
        bestA = a;
        bestB = b;
      }

      // 1. Vertex proximity
      for (int ai = 0; ai < aEnd; ai++) {
        for (int bi = bStart; bi < polyB.length; bi++) {
          if (const Distance()(polyA[ai], polyB[bi]) <=
              proximityThresholdMeters) {
            considerCandidate(polyA[ai], ai, bi);
          }
        }
      }

      // 2. Geometric edge crossing
      final aEdgeEnd = isAdjacent
          ? (polyA.length - 2).clamp(0, polyA.length - 1)
          : polyA.length - 1;
      final bEdgeStart = isAdjacent ? 1 : 0;
      for (int ai = 0; ai < aEdgeEnd; ai++) {
        for (int bi = bEdgeStart; bi < polyB.length - 1; bi++) {
          final pt = GeometryUtils.segmentIntersection(
            polyA[ai],
            polyA[ai + 1],
            polyB[bi],
            polyB[bi + 1],
          );
          if (pt != null) considerCandidate(pt, ai, bi);
        }
      }

      // 3. Vertex lying on the other polyline's interior
      for (int ai = 0; ai < aEnd; ai++) {
        for (int bi = bEdgeStart; bi < polyB.length - 1; bi++) {
          if (GeometryUtils.pointToSegmentDistanceMeters(
                polyA[ai],
                polyB[bi],
                polyB[bi + 1],
              ) <=
              proximityThresholdMeters) {
            considerCandidate(polyA[ai], ai, bi);
          }
        }
      }
      for (int bi = bStart; bi < polyB.length; bi++) {
        for (int ai = 0; ai < aEdgeEnd; ai++) {
          if (GeometryUtils.pointToSegmentDistanceMeters(
                polyB[bi],
                polyA[ai],
                polyA[ai + 1],
              ) <=
              proximityThresholdMeters) {
            considerCandidate(polyB[bi], ai, bi);
          }
        }
      }
    }

    final polygon = bestPolygon;
    if (polygon == null) return null;
    return (polygon: polygon, rangeStart: bestA, rangeEnd: bestB);
  }

  /// The largest loop any of [touchedSegments] now closes, or null. Used
  /// after a pin is dragged: a move can close a brand new loop, or re-close a
  /// bigger or smaller one, exactly as placing a new pin can.
  static ({List<LatLng> polygon, int rangeStart, int rangeEnd})?
      bestLoopAfterPinMove(
    List<RouteSegment> segments,
    List<int> touchedSegments,
  ) {
    List<LatLng>? bestPolygon;
    double bestArea = 0;
    int bestRangeStart = 0;
    int bestRangeEnd = 0;
    for (final ti in touchedSegments) {
      final found = findLoopThroughSegment(segments, ti);
      if (found == null) continue;
      final area = GeometryUtils.polygonAreaM2(found.polygon);
      if (area <= bestArea) continue;
      bestArea = area;
      bestPolygon = found.polygon;
      bestRangeStart = found.rangeStart;
      bestRangeEnd = found.rangeEnd;
    }
    final polygon = bestPolygon;
    if (polygon == null) return null;
    return (
      polygon: polygon,
      rangeStart: bestRangeStart,
      rangeEnd: bestRangeEnd
    );
  }

  /// Builds the loop polygon for a snap-to-waypoint close.
  static List<LatLng> polygonFromWaypointIndex(
    List<RouteSegment> segments,
    int idx,
  ) {
    final poly = <LatLng>[];
    for (int s = idx; s < segments.length; s++) {
      final pts = segments[s].polyline;
      final start = s == idx ? 0 : 1; // skip shared junction vertex
      for (int i = start; i < pts.length; i++) {
        poly.add(pts[i]);
      }
    }
    return poly;
  }

  /// Builds the loop polygon for a geometric self-intersection against the
  /// route's *last* segment.
  static List<LatLng> polygonFromIntersection(
    List<RouteSegment> segments,
    LatLng intersection,
    int segIdx,
    int edgeIdx,
    int newEdgeIdx,
  ) {
    final poly = <LatLng>[intersection];

    // Vertices of the intersected segment after the crossing edge.
    final iPoly = segments[segIdx].polyline;
    for (int i = edgeIdx + 1; i < iPoly.length; i++) {
      poly.add(iPoly[i]);
    }

    // All intermediate segments entirely inside the loop.
    for (int s = segIdx + 1; s < segments.length - 1; s++) {
      for (final p in segments[s].polyline) {
        poly.add(p);
      }
    }

    // New segment from its start up to the crossing edge.
    final newPoly = segments.last.polyline;
    for (int i = 0; i <= newEdgeIdx; i++) {
      poly.add(newPoly[i]);
    }

    return poly;
  }

  /// Builds the loop polygon between two crossing segments,
  /// order-independent — walks the route from whichever crossing point comes
  /// first (in segment-index order) through every segment in between to the
  /// other crossing point. Generalises [polygonFromIntersection], which
  /// assumes the "new" segment is always the route's last one.
  static List<LatLng> polygonBetweenSegments(
    List<RouteSegment> segments,
    LatLng intersection,
    int segA,
    int edgeA,
    int segB,
    int edgeB,
  ) {
    final lo = math.min(segA, segB);
    final hi = math.max(segA, segB);
    final loEdge = segA == lo ? edgeA : edgeB;
    final hiEdge = segA == hi ? edgeA : edgeB;

    final poly = <LatLng>[intersection];

    final loPoly = segments[lo].polyline;
    for (int i = loEdge + 1; i < loPoly.length; i++) {
      poly.add(loPoly[i]);
    }

    for (int s = lo + 1; s < hi; s++) {
      for (final p in segments[s].polyline) {
        poly.add(p);
      }
    }

    final hiPoly = segments[hi].polyline;
    for (int i = 0; i <= hiEdge; i++) {
      poly.add(hiPoly[i]);
    }

    return poly;
  }

  /// Records [polygon] as a closed loop, superseding any already-closed loop
  /// that it both overlaps in `[rangeStart, rangeEnd]` segment span *and*
  /// geometrically covers.
  ///
  /// Returns [loops] unchanged — the same instance — when the polygon is
  /// rejected, so a caller can skip a rebuild by comparing identity.
  ///
  /// **The span test alone is not enough**, which a field test caught: pin a
  /// square, then pin a second square sharing one of its sides, and the two
  /// loops' spans necessarily touch at the shared edge's segment even though
  /// neither covers the other. That dropped the first square the instant the
  /// second closed. Loops with disjoint ranges are untouched either way.
  ///
  /// The mirror image of the same rule is applied *first*: a loop drawn
  /// wholly inside one already recorded encloses no ground that is not
  /// already claimed, so recording it would inflate the route's reported area
  /// for a shape that adds nothing. Checking it before the supersede pass
  /// means a re-drawn, near-identical loop keeps the original rather than
  /// swapping in a duplicate.
  static ClosedLoops finalise(
    ClosedLoops loops,
    List<LatLng> polygon, {
    required int rangeStart,
    required int rangeEnd,
  }) {
    if (polygon.length < 3) return loops;
    final area = GeometryUtils.polygonAreaM2(polygon);
    if (area < minLoopAreaM2) return loops;

    for (final existing in loops.polygons) {
      if (GeometryUtils.polygonCoversPolygon(existing, polygon)) return loops;
    }

    final newPolygons = <List<LatLng>>[];
    final newAreas = <double>[];
    final newRangeStart = <int>[];
    final newRangeEnd = <int>[];
    for (int i = 0; i < loops.length; i++) {
      // Sharing a segment span is necessary but not sufficient: two blocks
      // claimed by one route share the street between them, so their spans
      // touch even though neither covers the other's ground. The geometric
      // check is what distinguishes "drawn around it" from "next door to it".
      final supersedes = loops.rangeStart[i] <= rangeEnd &&
          rangeStart <= loops.rangeEnd[i] &&
          GeometryUtils.polygonCoversPolygon(polygon, loops.polygons[i]);
      if (supersedes) continue;
      newPolygons.add(loops.polygons[i]);
      newAreas.add(loops.areasM2[i]);
      newRangeStart.add(loops.rangeStart[i]);
      newRangeEnd.add(loops.rangeEnd[i]);
    }
    newPolygons.add(polygon);
    newAreas.add(area);
    newRangeStart.add(rangeStart);
    newRangeEnd.add(rangeEnd);

    return ClosedLoops(
      polygons: newPolygons,
      areasM2: newAreas,
      rangeStart: newRangeStart,
      rangeEnd: newRangeEnd,
    );
  }

  /// Drops every closed loop whose own span overlaps `[rangeStart, rangeEnd]`.
  ///
  /// The counterpart, for an in-place pin move, of the overlap check
  /// [finalise] runs when a *new* loop supersedes an old one. Needed because
  /// a moved pin's touched segments no longer exist in their old shape, so
  /// any loop built from them is stale regardless of whether the move goes on
  /// to close a new loop over the same ground.
  ///
  /// Deliberately keeps the pure span test with no geometric check: here the
  /// question is which loops a *structural* edit invalidated, not which ones
  /// a new loop supersedes.
  static ClosedLoops clearOverlappingRange(
    ClosedLoops loops,
    int rangeStart,
    int rangeEnd,
  ) {
    final newPolygons = <List<LatLng>>[];
    final newAreas = <double>[];
    final newRangeStart = <int>[];
    final newRangeEnd = <int>[];
    for (int i = 0; i < loops.length; i++) {
      final overlaps =
          loops.rangeStart[i] <= rangeEnd && rangeStart <= loops.rangeEnd[i];
      if (overlaps) continue;
      newPolygons.add(loops.polygons[i]);
      newAreas.add(loops.areasM2[i]);
      newRangeStart.add(loops.rangeStart[i]);
      newRangeEnd.add(loops.rangeEnd[i]);
    }
    return ClosedLoops(
      polygons: newPolygons,
      areasM2: newAreas,
      rangeStart: newRangeStart,
      rangeEnd: newRangeEnd,
    );
  }
}
