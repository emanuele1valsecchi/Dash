import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'package:dash/services/routing_service.dart';
import 'package:dash/utils/geometry_utils.dart';
import 'package:dash/utils/route_loops.dart';

/// Loop detection for a *planned* route, extracted from `route_create_page`.
///
/// Distinct from the live-run detection in `RunSessionController`, which
/// closes loops from a GPS breadcrumb trail: here a crossing can happen
/// anywhere along a road-snapped segment, not only at a recorded point.
void main() {
  // ~111 m per 0.001 degrees of latitude; longitude is scaled by cos(45.46)
  // so the squares below are roughly square on the ground. None of the rules
  // depend on that, but it keeps the areas readable.
  const lat0 = 45.4642;
  const lng0 = 9.1900;

  LatLng at(double north, double east) =>
      LatLng(lat0 + north * 0.0009, lng0 + east * 0.00128);

  RouteSegment seg(List<LatLng> points) =>
      RouteSegment(polyline: points, distanceMeters: 0);

  /// One segment per edge, the way the route builder records them: each
  /// segment starts at the previous one's last point.
  List<RouteSegment> path(List<LatLng> corners) => [
        for (var i = 0; i < corners.length - 1; i++)
          seg([corners[i], corners[i + 1]]),
      ];

  /// A closed square of side `size`, with its bottom-left corner at
  /// (`north`, `east`), walked anticlockwise and returning to its start.
  List<LatLng> squareCorners({
    double north = 0,
    double east = 0,
    double size = 1,
  }) =>
      [
        at(north, east),
        at(north, east + size),
        at(north + size, east + size),
        at(north + size, east),
        at(north, east),
      ];

  group('finding a loop from the newest segment', () {
    test('a route that does not touch itself closes nothing', () {
      final segments = path([at(0, 0), at(0, 1), at(0, 2)]);

      expect(RouteLoops.findBestSelfIntersection(segments), isNull);
    });

    test('a single segment cannot close anything', () {
      expect(RouteLoops.findBestSelfIntersection(path([at(0, 0), at(0, 1)])),
          isNull);
    });

    test('an empty route closes nothing', () {
      expect(RouteLoops.findBestSelfIntersection([]), isNull);
    });

    test('a square closing back on its start is found', () {
      final segments = path(squareCorners());

      final found = RouteLoops.findBestSelfIntersection(segments);

      expect(found, isNotNull);
      expect(GeometryUtils.polygonAreaM2(found!.polygon),
          greaterThan(RouteLoops.minLoopAreaM2));
    });

    test('the polygon it returns is the square that was walked', () {
      final segments = path(squareCorners(size: 1));

      final found = RouteLoops.findBestSelfIntersection(segments)!;

      // A 1-unit square is ~100 m on a side, so ~10,000 m². Generous bounds:
      // the assertion is that it found the square, not a sliver of it.
      final area = GeometryUtils.polygonAreaM2(found.polygon);
      expect(area, greaterThan(5000));
      expect(area, lessThan(20000));
    });

    test('a wobble smaller than the minimum area is not a loop', () {
      // GPS-scale noise, not an enclosed area worth claiming.
      final tiny = [
        LatLng(lat0, lng0),
        LatLng(lat0 + 0.00002, lng0),
        LatLng(lat0 + 0.00002, lng0 + 0.00002),
        LatLng(lat0, lng0),
      ];

      expect(RouteLoops.findBestSelfIntersection(path(tiny)), isNull);
    });

    test('a big square is reported in full, not as a corner of it', () {
      // Note on what this does *not* pin: the search keeps the candidate
      // enclosing the largest area rather than the first one found, and a
      // mutation changing that to "first wins" survives this whole file.
      //
      // That is a property of the search order, not a gap in the fixtures.
      // Candidates are considered from the earliest crossed segment onward,
      // and a polygon built from an earlier segment contains every later
      // one — so on any route that does not overlap itself, first-found and
      // largest are the same candidate. They diverge only where the
      // shoelace area partly cancels (a bowtie), and there the smaller
      // candidate falls below `minLoopAreaM2` and is rejected before the
      // comparison matters. Pinning it would need a contrived
      // self-overlapping shape; recorded in TEST_NOTES instead.
      final segments = path([
        at(0, 0),
        at(0, 3),
        at(3, 3),
        at(3, 0),
        at(0, 0),
      ]);

      final found = RouteLoops.findBestSelfIntersection(segments)!;
      final area = GeometryUtils.polygonAreaM2(found.polygon);

      // The full 3x3, not a 1x1 corner of it.
      expect(area, greaterThan(60000));
    });

    test('the range it reports starts at the segment it crossed', () {
      final segments = path(squareCorners());

      final found = RouteLoops.findBestSelfIntersection(segments)!;

      expect(found.rangeStart, 0);
    });
  });

  group('recording a loop', () {
    List<LatLng> square({double north = 0, double east = 0, double size = 1}) =>
        squareCorners(north: north, east: east, size: size);

    test('a valid polygon is recorded with its area and range', () {
      final loops = RouteLoops.finalise(
        const ClosedLoops.empty(),
        square(),
        rangeStart: 0,
        rangeEnd: 3,
      );

      expect(loops.length, 1);
      expect(loops.areasM2.single, greaterThan(5000));
      expect(loops.rangeStart.single, 0);
      expect(loops.rangeEnd.single, 3);
    });

    test('a degenerate polygon is refused', () {
      final loops = RouteLoops.finalise(
        const ClosedLoops.empty(),
        [at(0, 0), at(0, 1)],
        rangeStart: 0,
        rangeEnd: 1,
      );

      expect(loops.isEmpty, isTrue);
    });

    test('a polygon under the minimum area is refused', () {
      final loops = RouteLoops.finalise(
        const ClosedLoops.empty(),
        [
          LatLng(lat0, lng0),
          LatLng(lat0 + 0.00001, lng0),
          LatLng(lat0 + 0.00001, lng0 + 0.00001),
        ],
        rangeStart: 0,
        rangeEnd: 1,
      );

      expect(loops.isEmpty, isTrue);
    });

    test('a refused polygon returns the same instance', () {
      // So a caller can skip a rebuild by comparing identity.
      const before = ClosedLoops.empty();

      final after = RouteLoops.finalise(before, [at(0, 0)],
          rangeStart: 0, rangeEnd: 1);

      expect(identical(after, before), isTrue);
    });

    test('two separate loops are both kept', () {
      var loops = RouteLoops.finalise(const ClosedLoops.empty(), square(),
          rangeStart: 0, rangeEnd: 3);

      loops = RouteLoops.finalise(loops, square(east: 5),
          rangeStart: 4, rangeEnd: 7);

      expect(loops.length, 2);
    });

    test('the total area is the sum of every loop', () {
      var loops = RouteLoops.finalise(const ClosedLoops.empty(), square(),
          rangeStart: 0, rangeEnd: 3);
      loops = RouteLoops.finalise(loops, square(east: 5),
          rangeStart: 4, rangeEnd: 7);

      expect(loops.totalAreaM2,
          closeTo(loops.areasM2[0] + loops.areasM2[1], 0.001));
    });
  });

  group('superseding', () {
    test('a bigger loop drawn around an older one replaces it', () {
      // Re-detecting a bigger loop over the same ground must not leave both
      // recorded — that double-counts the shared area and draws two
      // overlapping fills.
      var loops = RouteLoops.finalise(
        const ClosedLoops.empty(),
        squareCorners(north: 1, east: 1, size: 1),
        rangeStart: 0,
        rangeEnd: 3,
      );
      expect(loops.length, 1);

      loops = RouteLoops.finalise(
        loops,
        squareCorners(size: 3),
        rangeStart: 0,
        rangeEnd: 5,
      );

      expect(loops.length, 1, reason: 'the small one should be superseded');
      expect(loops.areasM2.single, greaterThan(60000));
    });

    test('two blocks sharing a street both survive', () {
      // The field-tested bug: pin a square, then a second square sharing one
      // of its sides. Their segment spans necessarily touch at the shared
      // edge even though neither covers the other's ground, so superseding
      // on the span alone silently deleted the first block — along with its
      // area and its XP — the instant the second closed.
      var loops = RouteLoops.finalise(
        const ClosedLoops.empty(),
        squareCorners(size: 1),
        rangeStart: 0,
        rangeEnd: 3,
      );

      loops = RouteLoops.finalise(
        loops,
        squareCorners(east: 1, size: 1),
        rangeStart: 3,
        rangeEnd: 6,
      );

      expect(loops.length, 2,
          reason: 'adjacent blocks are not the same ground');
    });

    test('a loop with a disjoint span is never touched', () {
      var loops = RouteLoops.finalise(const ClosedLoops.empty(),
          squareCorners(size: 1), rangeStart: 0, rangeEnd: 3);

      loops = RouteLoops.finalise(loops, squareCorners(size: 3),
          rangeStart: 10, rangeEnd: 15);

      expect(loops.length, 2,
          reason: 'covering the ground is not enough — the spans must overlap');
    });
  });

  group('the mirror rule', () {
    test('a loop drawn inside an existing one is discarded', () {
      // It encloses no ground that is not already claimed, so recording it
      // would inflate the route's reported area for a shape adding nothing.
      var loops = RouteLoops.finalise(const ClosedLoops.empty(),
          squareCorners(size: 3), rangeStart: 0, rangeEnd: 3);
      final areaBefore = loops.totalAreaM2;

      loops = RouteLoops.finalise(
        loops,
        squareCorners(north: 1, east: 1, size: 1),
        rangeStart: 4,
        rangeEnd: 7,
      );

      expect(loops.length, 1);
      expect(loops.totalAreaM2, closeTo(areaBefore, 0.001));
    });

    test('it is applied before superseding, so a redraw keeps the original',
        () {
      // A re-drawn, near-identical loop should keep the one already there
      // rather than swapping in a duplicate of it.
      var loops = RouteLoops.finalise(const ClosedLoops.empty(),
          squareCorners(size: 2), rangeStart: 0, rangeEnd: 3);
      final firstPolygon = loops.polygons.single;

      loops = RouteLoops.finalise(loops, squareCorners(size: 2),
          rangeStart: 0, rangeEnd: 3);

      expect(loops.length, 1);
      expect(identical(loops.polygons.single, firstPolygon), isTrue);
    });
  });

  group('clearing loops a pin move invalidated', () {
    ClosedLoops twoLoops() {
      var loops = RouteLoops.finalise(const ClosedLoops.empty(),
          squareCorners(size: 1), rangeStart: 0, rangeEnd: 3);
      return RouteLoops.finalise(loops, squareCorners(east: 5, size: 1),
          rangeStart: 10, rangeEnd: 13);
    }

    test('drops a loop whose span the move touched', () {
      final loops = RouteLoops.clearOverlappingRange(twoLoops(), 2, 4);

      expect(loops.length, 1);
      expect(loops.rangeStart.single, 10);
    });

    test('leaves untouched loops alone', () {
      final loops = RouteLoops.clearOverlappingRange(twoLoops(), 5, 6);

      expect(loops.length, 2);
    });

    test('uses the span alone, with no geometric check', () {
      // Deliberately different from superseding: here the question is which
      // loops a *structural* edit invalidated, not which ones a new loop
      // supersedes. A touched segment no longer exists in its old shape, so
      // any loop built from it is stale whatever the geometry says.
      final loops = RouteLoops.clearOverlappingRange(twoLoops(), 0, 20);

      expect(loops.isEmpty, isTrue);
    });
  });

  group('a loop closed by moving a pin', () {
    test('is found through a touched segment anywhere in the route', () {
      // Unlike the tip-only search, this one looks both backwards and
      // forwards — a dragged pin can sit anywhere.
      //
      // The touched segments must be ones the closure actually runs through.
      // A square's closure is where the last segment returns to the first
      // segment's start, so segments 0 and 3 are what a drag on that corner
      // re-routes; segments 1 and 2 are the far side of the square and
      // genuinely close nothing.
      final segments = path(squareCorners());

      final found = RouteLoops.bestLoopAfterPinMove(segments, [0, 3]);

      expect(found, isNotNull);
      expect(GeometryUtils.polygonAreaM2(found!.polygon), greaterThan(5000));
    });

    test('a move that closes nothing reports nothing', () {
      final segments = path([at(0, 0), at(0, 1), at(0, 2), at(0, 3)]);

      expect(RouteLoops.bestLoopAfterPinMove(segments, [1]), isNull);
    });

    test('an empty touched list reports nothing', () {
      expect(RouteLoops.bestLoopAfterPinMove(path(squareCorners()), []),
          isNull);
    });
  });

  group('polygon construction', () {
    test('a snap-to-waypoint close walks from that waypoint to the tip', () {
      final segments = path(squareCorners());

      final poly = RouteLoops.polygonFromWaypointIndex(segments, 0);

      expect(poly.first, at(0, 0));
      expect(poly.length, greaterThanOrEqualTo(4));
    });

    test('it skips the shared junction vertex between segments', () {
      // Each segment starts where the previous ended; keeping both copies
      // would put a duplicate point in the polygon.
      final segments = path(squareCorners());

      final poly = RouteLoops.polygonFromWaypointIndex(segments, 0);

      for (var i = 1; i < poly.length; i++) {
        expect(poly[i], isNot(poly[i - 1]));
      }
    });

    test('starting partway along gives a shorter polygon', () {
      final segments = path(squareCorners());

      final whole = RouteLoops.polygonFromWaypointIndex(segments, 0);
      final partial = RouteLoops.polygonFromWaypointIndex(segments, 2);

      expect(partial.length, lessThan(whole.length));
    });
  });

  group('ClosedLoops', () {
    test('an empty one has no area', () {
      expect(const ClosedLoops.empty().totalAreaM2, 0);
      expect(const ClosedLoops.empty().isEmpty, isTrue);
    });

    test('a copy does not share its lists with the original', () {
      // The undo history holds snapshots; a shallow copy would let a later
      // mutation reach back into one.
      final loops = RouteLoops.finalise(const ClosedLoops.empty(),
          squareCorners(), rangeStart: 0, rangeEnd: 3);

      final copy = loops.copy();
      copy.polygons.single.add(at(9, 9));

      expect(copy.polygons.single.length,
          isNot(loops.polygons.single.length));
    });
  });
}
