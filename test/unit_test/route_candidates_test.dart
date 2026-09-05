import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'package:dash/services/routing_service.dart';
import 'package:dash/services/unit_preferences.dart';
import 'package:dash/utils/route_candidates.dart';
import 'package:dash/utils/unit_formatter.dart';

/// The candidate-selection rules behind route search, extracted from
/// `route_search_page`. Two of the three have a reported field bug behind
/// them, which is why they are worth testing away from the screen.
void main() {
  const milan = LatLng(45.4642, 9.1900);
  const metric = UnitFormatter.metric;

  /// A closed square of `side` metres starting at [milan], as a segment whose
  /// reported distance is its real perimeter.
  RouteSegment squareLoop({double side = 400}) {
    final ne = RouteCandidates.offset(milan, side, 0);
    final corner = RouteCandidates.offset(ne, side, 90);
    final e = RouteCandidates.offset(milan, side, 90);
    return RouteSegment(
      polyline: [milan, ne, corner, e, milan],
      distanceMeters: side * 4,
    );
  }

  /// An out-and-back along one line: real geometry, real distance, no area.
  RouteSegment outAndBack({double length = 800}) {
    final far = RouteCandidates.offset(milan, length, 90);
    final mid = RouteCandidates.offset(milan, length / 2, 90);
    return RouteSegment(
      polyline: [milan, mid, far, mid, milan],
      distanceMeters: length * 2,
    );
  }

  group('enclosesRealArea', () {
    test('accepts a square loop', () {
      expect(RouteCandidates.enclosesRealArea(squareLoop()), isTrue);
    });

    test('rejects an out-and-back along the same road', () {
      // The reported bug: a closed-circuit search returned a "route" that
      // ran up a street and back down it. Real ORS geometry and the right
      // distance, but the shoelace area cancels to about zero because the
      // two offset waypoints had snapped onto the same street.
      expect(RouteCandidates.enclosesRealArea(outAndBack()), isFalse);
    });

    test('accepts a lopsided loop', () {
      // The 2% floor is generous on purpose — a long thin circuit round a
      // park is a perfectly good route and must not be mistaken for a
      // degenerate one.
      final long = RouteCandidates.offset(milan, 1000, 90);
      final longUp = RouteCandidates.offset(long, 100, 0);
      final up = RouteCandidates.offset(milan, 100, 0);

      final seg = RouteSegment(
        polyline: [milan, long, longUp, up, milan],
        distanceMeters: 2200,
      );

      expect(RouteCandidates.enclosesRealArea(seg), isTrue);
    });

    test('rejects a polyline too short to be a closed shape', () {
      final seg = RouteSegment(
        polyline: [milan, RouteCandidates.offset(milan, 100, 90)],
        distanceMeters: 100,
      );

      expect(RouteCandidates.enclosesRealArea(seg), isFalse);
    });

    test('rejects a zero-distance segment rather than dividing by it', () {
      final seg = RouteSegment(polyline: [milan, milan, milan, milan],
          distanceMeters: 0);

      expect(RouteCandidates.enclosesRealArea(seg), isFalse);
    });

    test('the threshold is a fraction of the circle of equal perimeter', () {
      // A circle is the most area a given perimeter can enclose, so the test
      // is scale-free: the same shape passes at any size.
      expect(RouteCandidates.enclosesRealArea(squareLoop(side: 50)), isTrue);
      expect(RouteCandidates.enclosesRealArea(squareLoop(side: 5000)), isTrue);
    });
  });

  group('dedupeSimilar', () {
    RouteSegment loopAt(LatLng centre, {required double meters}) {
      final a = RouteCandidates.offset(centre, 100, 0);
      final b = RouteCandidates.offset(centre, 100, 120);
      final c = RouteCandidates.offset(centre, 100, 240);
      return RouteSegment(polyline: [a, b, c, a], distanceMeters: meters);
    }

    test('keeps a single candidate', () {
      final one = [loopAt(milan, meters: 1000)];

      expect(RouteCandidates.dedupeSimilar(one), hasLength(1));
    });

    test('collapses two candidates over the same ground', () {
      // Different seeds, or a padded side and a natural alternative, can
      // converge on the same streets — offering the user the same route
      // twice reads as a bug.
      final dupes = [
        loopAt(milan, meters: 1000),
        loopAt(milan, meters: 1010),
      ];

      expect(RouteCandidates.dedupeSimilar(dupes), hasLength(1));
    });

    test('keeps the first of a duplicate pair', () {
      // Callers pass their preferred candidate first.
      final first = loopAt(milan, meters: 1000);
      final second = loopAt(milan, meters: 1010);

      final kept = RouteCandidates.dedupeSimilar([first, second]);

      expect(identical(kept.single, first), isTrue);
    });

    test('keeps two loops of the same length in different places', () {
      // Same length is not enough — two loops from the same start in
      // opposite directions are genuinely different routes.
      final far = RouteCandidates.offset(milan, 5000, 90);
      final both = [
        loopAt(milan, meters: 1000),
        loopAt(far, meters: 1000),
      ];

      expect(RouteCandidates.dedupeSimilar(both), hasLength(2));
    });

    test('keeps two loops over the same ground at different lengths', () {
      // Same place is not enough either: a 1 km and a 3 km loop from one
      // start are different offers.
      final both = [
        loopAt(milan, meters: 1000),
        loopAt(milan, meters: 3000),
      ];

      expect(RouteCandidates.dedupeSimilar(both), hasLength(2));
    });

    test('an empty list stays empty', () {
      expect(RouteCandidates.dedupeSimilar([]), isEmpty);
    });
  });

  group('deriveTarget', () {
    RouteTarget derive({
      String time = '',
      String distance = '',
      String calories = '',
      UnitFormatter units = metric,
    }) =>
        RouteCandidates.deriveTarget(
          timeText: time,
          distanceText: distance,
          caloriesText: calories,
          units: units,
        );

    test('no entries at all is empty, not a conflict', () {
      final t = derive();

      expect(t.isEmpty, isTrue);
      expect(t.isConflict, isFalse);
      expect(t.targetKm, isNull);
    });

    test('a distance alone resolves to itself', () {
      final t = derive(distance: '5');

      expect(t.targetKm, closeTo(5.0, 1e-9));
    });

    test('a time is converted at the walking pace', () {
      // 45 minutes at 9 min/km is 5 km.
      final t = derive(time: '45');

      expect(t.targetKm, closeTo(5.0, 1e-9));
    });

    test('calories are converted at the per-km rate', () {
      // 350 kcal at 70 kcal/km is 5 km.
      final t = derive(calories: '350');

      expect(t.targetKm, closeTo(5.0, 1e-9));
    });

    test('entries that agree are averaged', () {
      final t = derive(time: '45', distance: '5', calories: '350');

      expect(t.targetKm, closeTo(5.0, 1e-6));
    });

    test('entries that disagree slightly are still accepted', () {
      // All three are derived from the same magic constants, so they are
      // never expected to agree exactly — the tolerance is loose on purpose.
      final t = derive(time: '45', distance: '5.5');

      expect(t.isConflict, isFalse);
      expect(t.targetKm, isNotNull);
    });

    test('entries that disagree wildly are a conflict', () {
      // 45 minutes implies 5 km; 20 km is a different request entirely, and
      // silently averaging to 12.5 would answer neither.
      final t = derive(time: '45', distance: '20');

      expect(t.isConflict, isTrue);
      expect(t.targetKm, isNull);
    });

    test('a single entry can never conflict with itself', () {
      final t = derive(distance: '42');

      expect(t.isConflict, isFalse);
      expect(t.targetKm, closeTo(42.0, 1e-9));
    });

    test('unparseable text is ignored, not treated as zero', () {
      // Half-typed input must not resolve to a 0 km target.
      final t = derive(distance: 'five', time: '45');

      expect(t.targetKm, closeTo(5.0, 1e-9));
    });

    test('whitespace is ignored', () {
      expect(derive(distance: '  5  ').targetKm, closeTo(5.0, 1e-9));
    });

    test('a typed distance is read in the user\'s own units', () {
      // Everything downstream is metric; this is the one conversion
      // boundary, and getting it wrong makes a miles user search for the
      // wrong distance entirely.
      const imperial = UnitFormatter(
        distanceUnit: DistanceUnit.miles,
        areaUnit: AreaUnit.imperial,
        rateDisplay: RateDisplay.pace,
        elevationUnit: ElevationUnit.feet,
        energyUnit: EnergyUnit.kcal,
        clockFormat: ClockFormat.h24,
        weekStart: WeekStart.monday,
      );

      final t = derive(distance: '5', units: imperial);

      expect(t.targetKm, closeTo(8.047, 0.01),
          reason: '5 miles is about 8 km');
    });
  });

  group('totalKm', () {
    test('a single lap is just the loop', () {
      expect(RouteCandidates.totalKm(4000), closeTo(4.0, 1e-9));
    });

    test('laps multiply the measured loop back up', () {
      // The finder searches for a per-lap size, so a 3-lap search over a
      // 12 km target looks for ~4 km and must report 12.
      expect(RouteCandidates.totalKm(4000, laps: 3), closeTo(12.0, 1e-9));
    });
  });

  group('offset', () {
    test('north increases latitude only', () {
      final p = RouteCandidates.offset(milan, 1000, 0);

      expect(p.latitude, greaterThan(milan.latitude));
      expect(p.longitude, closeTo(milan.longitude, 1e-9));
    });

    test('east increases longitude only', () {
      final p = RouteCandidates.offset(milan, 1000, 90);

      expect(p.longitude, greaterThan(milan.longitude));
      expect(p.latitude, closeTo(milan.latitude, 1e-9));
    });

    test('the distance it moves is the distance asked for', () {
      for (final bearing in [0.0, 45.0, 90.0, 200.0, 330.0]) {
        final p = RouteCandidates.offset(milan, 1500, bearing);

        expect(const Distance()(milan, p), closeTo(1500, 15),
            reason: 'bearing $bearing');
      }
    });

    test('a full turn comes back to the start', () {
      final there = RouteCandidates.offset(milan, 800, 90);
      final back = RouteCandidates.offset(there, 800, 270);

      expect(const Distance()(milan, back), lessThan(1));
    });
  });

  group('polylineCentroid', () {
    test('is the mean of the points', () {
      final c = RouteCandidates.polylineCentroid([
        const LatLng(0, 0),
        const LatLng(2, 0),
        const LatLng(0, 2),
        const LatLng(2, 2),
      ]);

      expect(c.latitude, closeTo(1.0, 1e-9));
      expect(c.longitude, closeTo(1.0, 1e-9));
    });

    test('a single point is its own centroid', () {
      final c = RouteCandidates.polylineCentroid([milan]);

      expect(c, milan);
    });
  });

  group('the tuning constants', () {
    test('the match band is far tighter than the conflict band', () {
      // Two different questions: "do the user's own entries roughly agree"
      // versus "is this generated route the length they asked for". Sharing
      // one number let an 8 km search return 8.7 km.
      expect(RouteCandidates.matchTolerance,
          lessThan(RouteCandidates.conflictTolerance));
    });

    test('the winding factor assumes roads are longer than straight lines',
        () {
      expect(RouteCandidates.roadWindingFactor, greaterThan(1.0));
    });

    test('pace and energy match the planning constants', () {
      // A planned route and a found one must report the same numbers for the
      // same distance.
      expect(RouteCandidates.paceMinPerKm, 9.0);
      expect(RouteCandidates.calPerKm, 70.0);
    });
  });

  group('a circle bounds the area a perimeter can enclose', () {
    test('the formula used by enclosesRealArea', () {
      // Sanity check on the maths itself: a circle of circumference C has
      // area C^2 / 4pi, and no shape of that perimeter can beat it.
      const c = 1000.0;
      final circleArea = (c * c) / (4 * math.pi);
      final squareArea = (c / 4) * (c / 4);

      expect(squareArea, lessThan(circleArea));
    });
  });
}
