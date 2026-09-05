import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'package:dash/utils/geometry_utils.dart';

/// `findLoopClosureIndex` decides, on every GPS fix of a live run, whether the
/// trail has just closed a loop — and therefore how much ground the runner
/// claims and how much XP they earn. It had **no direct test**: it was only
/// exercised through `RunSessionController`, whose fixtures each have a single
/// qualifying closure point, so they cannot tell the real rule from its
/// opposite. A mutation returning the *nearest* closure instead of the
/// farthest survived the entire suite.
///
/// The rule under test is the one CLAUDE.md documents: the search runs over
/// the **whole** breadcrumb trail on every fix, and returns the
/// **farthest-back** qualifying point, so it always reports the *biggest*
/// loop currently closable. Returning the nearest one instead silently
/// shrinks the claim — the runner sees a small polygon where they ran a big
/// one, and is scored on it.
void main() {
  const base = LatLng(45.4642, 9.1900);
  const mPerLat = 110540.0;
  final mPerLng = 111320.0 * math.cos(base.latitude * math.pi / 180);

  /// A point [northM] north and [eastM] east of [base].
  LatLng at(double northM, double eastM) => LatLng(
        base.latitude + northM / mPerLat,
        base.longitude + eastM / mPerLng,
      );

  /// Fills [corners] in at ~[stepM] intervals, the way a real trail arrives.
  ///
  /// The function accumulates path length between *consecutive* breadcrumbs,
  /// so density is not cosmetic: a four-point square would walk back past a
  /// closure candidate in one 300 m stride and never sample the points in
  /// between.
  List<LatLng> trail(List<LatLng> corners, {double stepM = 20}) {
    const dist = Distance();
    final out = <LatLng>[corners.first];
    for (var i = 0; i < corners.length - 1; i++) {
      final a = corners[i], b = corners[i + 1];
      final legM = dist(a, b);
      final steps = math.max(1, (legM / stepM).round());
      for (var s = 1; s <= steps; s++) {
        final t = s / steps;
        out.add(LatLng(
          a.latitude + (b.latitude - a.latitude) * t,
          a.longitude + (b.longitude - a.longitude) * t,
        ));
      }
    }
    return out;
  }

  /// A closed square of [side] metres, anticlockwise from the origin.
  List<LatLng> square(double side) => [
        at(0, 0),
        at(0, side),
        at(side, side),
        at(side, 0),
        at(0, 0),
      ];

  group('what closes a loop', () {
    test('a trail that never comes back closes nothing', () {
      final straight = trail([at(0, 0), at(0, 600)]);

      expect(GeometryUtils.findLoopClosureIndex(straight), isNull);
    });

    test('too few fixes to be a shape close nothing', () {
      expect(
        GeometryUtils.findLoopClosureIndex([at(0, 0), at(0, 20), at(0, 40)]),
        isNull,
      );
    });

    test('a lap back to the start closes', () {
      final lap = trail(square(200));

      expect(GeometryUtils.findLoopClosureIndex(lap), 0);
    });

    test('passing near the start but outside the radius does not close', () {
      // 40 m away is a parallel street, not the same spot. The default
      // radius is 18 m.
      final nearMiss = trail([
        at(0, 0),
        at(0, 300),
        at(300, 300),
        at(300, 0),
        at(40, 0),
      ]);

      expect(GeometryUtils.findLoopClosureIndex(nearMiss), isNull);
    });

    test('a tight cluster of fixes is not a loop', () {
      // Standing still with drifting GPS returns to the same spot over and
      // over. Without the minimum path length that would claim territory for
      // waiting at a traffic light.
      final jitter = trail([
        at(0, 0),
        at(0, 10),
        at(10, 10),
        at(10, 0),
        at(0, 0),
      ], stepM: 2);

      expect(GeometryUtils.findLoopClosureIndex(jitter), isNull);
    });

    test('the minimum path length is what rejects it, and is adjustable', () {
      final small = trail([
        at(0, 0),
        at(0, 10),
        at(10, 10),
        at(10, 0),
        at(0, 0),
      ], stepM: 2);

      expect(GeometryUtils.findLoopClosureIndex(small), isNull);
      expect(GeometryUtils.findLoopClosureIndex(small, minPathMeters: 20), 0);
    });

    test('a wider radius forgives a looser return', () {
      final nearMiss = trail([
        at(0, 0),
        at(0, 300),
        at(300, 300),
        at(300, 0),
        at(40, 0),
      ]);

      expect(GeometryUtils.findLoopClosureIndex(nearMiss), isNull);
      expect(
        GeometryUtils.findLoopClosureIndex(nearMiss, radiusMeters: 50),
        0,
      );
    });
  });

  group('it reports the biggest loop closable, not the most recent', () {
    /// A big lap, then a small one from the same corner. The trail passes
    /// within the closure radius of its own start **twice** — once at the end
    /// of the big lap, once at the end of the small one — so the two rules
    /// give visibly different answers.
    List<LatLng> bigThenSmall() {
      final big = trail(square(300));
      final small = trail(square(80));
      return [...big, ...small.skip(1)];
    }

    test('the farthest-back qualifying fix wins', () {
      final path = bigThenSmall();

      // Index 0 is the start of the *big* lap. The end of the big lap is
      // also a valid closure, and is the one a nearest-match search returns.
      expect(GeometryUtils.findLoopClosureIndex(path), 0);
    });

    test('so the claimed polygon is the big lap, not the small one', () {
      // The index is only a means to an end — what it costs the runner is
      // area, so assert in the units the mistake is actually felt in.
      final path = bigThenSmall();
      final idx = GeometryUtils.findLoopClosureIndex(path)!;

      final claimed = GeometryUtils.polygonAreaM2(path.sublist(idx));

      // Closing at index 0 encloses the whole trail: the 300 m lap plus the
      // 80 m one inside it, ~96400 m2. The number that matters is the one it
      // is *not* — a nearest-match search closes at the end of the big lap
      // and claims the 80 m square alone, ~6400 m2, fifteen times smaller.
      expect(claimed, greaterThan(80000));
    });

    test('a lap run twice round still reports the whole thing', () {
      // Two identical laps: every fix of the second lap has a twin on the
      // first, so a nearest-match search would report only the second lap.
      final one = trail(square(200));
      final twice = [...one, ...one.skip(1)];

      expect(GeometryUtils.findLoopClosureIndex(twice), 0);
    });
  });
}
