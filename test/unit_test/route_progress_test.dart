import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'package:dash/utils/route_progress.dart';

/// A ~100 m square loop just east of Milano centre, closing back on its own
/// start point — the shape that broke arrival detection in the field, since
/// its start and finish are literally the same coordinate.
///
/// Perimeter ~400 m, so it gets the minimum three checkpoints, which land
/// almost exactly on the SE, NE and NW corners.
const _sw = LatLng(45.4642, 9.19000);
const _se = LatLng(45.4642, 9.19128);
const _ne = LatLng(45.4651, 9.19128);
const _nw = LatLng(45.4651, 9.19000);

final _loop = <LatLng>[_sw, _se, _ne, _nw, _sw];

/// A deliberately tiny ~25 m square (perimeter ~100 m). Nothing anyone would
/// really run — it exists to force the case where the *last* checkpoint sits
/// within the visit radius of the start line as the crow flies, across the
/// loop's interior.
const _tinySw = LatLng(45.4642, 9.19);
const _tinySe = LatLng(45.4642, 9.19032031);
const _tinyNe = LatLng(45.46442609, 9.19032031);
const _tinyNw = LatLng(45.46442609, 9.19);

final _tinyLoop = <LatLng>[_tinySw, _tinySe, _tinyNe, _tinyNw, _tinySw];

/// A 2 km straight run north — long enough to earn a full set of checkpoints,
/// spaced far enough apart to test the look-ahead window properly.
final _longStraight = <LatLng>[
  const LatLng(45.4642, 9.19),
  const LatLng(45.48228, 9.19), // ~2 km north
];

void main() {
  group('RouteProgressTracker', () {
    group('checkpoint placement', () {
      test('places checkpoints between, not on, the route endpoints', () {
        final tracker = RouteProgressTracker(_loop);

        expect(tracker.checkpoints, hasLength(3));
        // A checkpoint on the start point would be passed before the runner
        // moved; one on the finish would just duplicate the proximity test.
        const dist = Distance();
        for (final cp in tracker.checkpoints) {
          expect(dist(cp, _sw), greaterThan(1));
        }
      });

      test('spaces them by cumulative distance, hitting the far corners', () {
        final tracker = RouteProgressTracker(_loop);
        const dist = Distance();

        expect(dist(tracker.checkpoints[0], _se), lessThan(2));
        expect(dist(tracker.checkpoints[1], _ne), lessThan(2));
        expect(dist(tracker.checkpoints[2], _nw), lessThan(2));
      });

      test('scales the count with route length, within bounds', () {
        expect(RouteProgressTracker(_loop).checkpoints, hasLength(3));
        expect(RouteProgressTracker(_longStraight).checkpoints, hasLength(12));
      });
    });

    group('degenerate routes disable the gate rather than blocking it', () {
      test('an empty route yields no checkpoints and reads as covered', () {
        final tracker = RouteProgressTracker(const []);

        expect(tracker.checkpoints, isEmpty);
        expect(tracker.progress.total, 0);
        expect(tracker.progress.isCovered, isTrue);
        expect(tracker.progress.fraction, 1);
      });

      test('a single-point route yields no checkpoints', () {
        final tracker = RouteProgressTracker(const [LatLng(45.4642, 9.19)]);
        expect(tracker.progress.isCovered, isTrue);
      });

      test('a zero-length route yields no checkpoints', () {
        // Every point identical — cumulative distance never advances.
        final tracker = RouteProgressTracker(
          const [LatLng(45.4642, 9.19), LatLng(45.4642, 9.19)],
        );
        expect(tracker.checkpoints, isEmpty);
        expect(tracker.progress.isCovered, isTrue);
      });
    });

    group('the field bug: start and finish at the same point', () {
      test('standing on the start line is not "covered"', () {
        final tracker = RouteProgressTracker(_loop);
        tracker.update(_sw);

        // This is the whole point of the class. Proximity to the finish said
        // "Route complete" here before the runner had taken a step.
        expect(tracker.progress.reached, 0);
        expect(tracker.progress.isCovered, isFalse);
        expect(tracker.progress.remaining, 3);
      });

      test('running the loop in order covers it', () {
        final tracker = RouteProgressTracker(_loop);

        tracker.update(_sw);
        expect(tracker.progress.isCovered, isFalse);

        tracker.update(_se);
        expect(tracker.progress.reached, 1);

        tracker.update(_ne);
        expect(tracker.progress.reached, 2);

        tracker.update(_nw);
        expect(tracker.progress.reached, 3);
        expect(tracker.progress.isCovered, isTrue);

        // Back at the start, having genuinely gone round.
        tracker.update(_sw);
        expect(tracker.progress.isCovered, isTrue);
      });

      test('ordering stops the final checkpoint being claimed from the start',
          () {
        // On the tiny loop the NW corner — the last checkpoint — is only ~25 m
        // from the start line across the loop's interior, well inside the 35 m
        // visit radius. An unordered proximity test would tick it off before
        // the runner moved, reintroducing the very bug this class prevents.
        const dist = Distance();
        final tracker = RouteProgressTracker(_tinyLoop);
        expect(dist(_tinySw, tracker.checkpoints.last),
            lessThan(RouteProgressTracker.defaultVisitRadiusMeters));

        tracker.update(_tinySw);

        expect(tracker.progress.isCovered, isFalse);
        expect(tracker.progress.reached, lessThan(3));
      });
    });

    group('look-ahead window', () {
      test('absorbs a single cut corner', () {
        // Skips the SE checkpoint entirely — the roundabout-at-the-crosswalk
        // case. Blocking on it would strand the runner short of the finish
        // for the rest of the run.
        final tracker = RouteProgressTracker(_loop);

        tracker.update(_ne);
        expect(tracker.progress.reached, 2);

        tracker.update(_nw);
        expect(tracker.progress.isCovered, isTrue);
      });

      test('refuses a jump past a whole limb of the route', () {
        final tracker = RouteProgressTracker(_longStraight);
        expect(tracker.checkpoints, hasLength(12));

        // Straight to the sixth checkpoint, skipping five.
        tracker.update(tracker.checkpoints[5]);

        expect(tracker.progress.reached, 0);
        expect(tracker.progress.isCovered, isFalse);
      });

      test('advances to the furthest checkpoint in the window, not the nearest',
          () {
        // A runner moving faster than the fix rate can pass several between
        // updates; re-acquiring the nearest would advance only one step and
        // leave the pointer permanently trailing.
        final tracker = RouteProgressTracker(_longStraight);

        tracker.update(tracker.checkpoints[2]);

        expect(tracker.progress.reached, 3);
      });

      test('never spans more than half a short route', () {
        // With only three checkpoints the raw constant of 2 would reach the
        // last one from the start line, silently disabling ordering.
        final tracker = RouteProgressTracker(_loop);

        tracker.update(_nw); // the final checkpoint, from a standing start
        expect(tracker.progress.isCovered, isFalse);
      });
    });

    test('progress is monotonic — backtracking never un-reaches', () {
      final tracker = RouteProgressTracker(_loop);

      tracker.update(_se);
      tracker.update(_ne);
      expect(tracker.progress.reached, 2);

      // Doubling back on itself, as a runner rounding a dead end does.
      tracker.update(_se);
      tracker.update(_sw);
      expect(tracker.progress.reached, 2);
    });
  });
}
