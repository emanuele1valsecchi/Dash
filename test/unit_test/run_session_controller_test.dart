import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import 'package:dash/services/run_session_controller.dart';
import 'package:dash/utils/geometry_utils.dart';

/// Builds a synthetic GPS fix. Defaults are deliberately "good" — accurate,
/// running-speed, valid heading — so each test only states the field it is
/// actually about.
Position _fix(
  double latitude,
  double longitude, {
  required int seconds,
  double accuracy = 5,
  double altitude = 120,
  double speed = 3,
  double heading = 90,
}) {
  return Position(
    latitude: latitude,
    longitude: longitude,
    timestamp: DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true),
    accuracy: accuracy,
    altitude: altitude,
    altitudeAccuracy: 3,
    heading: heading,
    headingAccuracy: 5,
    speed: speed,
    speedAccuracy: 1,
  );
}

/// A ~100 m square loop walked at ~10 m per fix, closing back on its own start
/// point — comfortably past `findLoopClosureIndex`'s 80 m minimum path and
/// inside its 18 m closure radius.
List<Position> _squareLoopFixes() {
  const startLat = 45.4642, startLng = 9.1900;
  const dLat = 0.000905; // ~100 m north
  const dLng = 0.001281; // ~100 m east

  const corners = <LatLng>[
    LatLng(startLat, startLng),
    LatLng(startLat, startLng + dLng),
    LatLng(startLat + dLat, startLng + dLng),
    LatLng(startLat + dLat, startLng),
    LatLng(startLat, startLng),
  ];

  final fixes = <Position>[];
  var t = 0;
  for (int c = 0; c < corners.length - 1; c++) {
    final a = corners[c], b = corners[c + 1];
    for (int step = 0; step < 10; step++) {
      final f = step / 10;
      t += 3; // ~10 m per 3 s ≈ 3.3 m/s, well under the spike threshold
      fixes.add(_fix(
        a.latitude + (b.latitude - a.latitude) * f,
        a.longitude + (b.longitude - a.longitude) * f,
        seconds: t,
      ));
    }
  }
  t += 3;
  fixes.add(_fix(startLat, startLng, seconds: t));
  return fixes;
}

/// Walks two ~100 m squares that share a side, in the order a runner would:
/// square A anticlockwise back to its own start, then straight on into square
/// B next door, which closes by re-entering A's corner at (1,0).
///
/// Using the reporter's own cardinal shorthand, where x runs east and y north:
///   A: (1,1) → (0,1) → (0,0) → (1,0) → (1,1)
///   B:        → (2,1) → (2,0) → (1,0) → (1,1)
///
/// Both squares are real, separate claims. What makes this the interesting
/// case is that B's closure necessarily reaches back *into* A's breadcrumb
/// range, along the street the two share.
List<Position> _twoAdjacentSquaresFixes() {
  const startLat = 45.4642, startLng = 9.1900;
  const dLat = 0.000905; // ~100 m north
  const dLng = 0.001281; // ~100 m east

  LatLng at(double x, double y) =>
      LatLng(startLat + dLat * y, startLng + dLng * x);

  final corners = <LatLng>[
    at(1, 1), at(0, 1), at(0, 0), at(1, 0), at(1, 1), // square A
    at(2, 1), at(2, 0), at(1, 0), at(1, 1), // square B
  ];

  final fixes = <Position>[];
  var t = 0;
  for (int c = 0; c < corners.length - 1; c++) {
    final a = corners[c], b = corners[c + 1];
    for (int step = 0; step < 10; step++) {
      final f = step / 10;
      t += 3; // ~10 m per 3 s, well under the spike threshold
      fixes.add(_fix(
        a.latitude + (b.latitude - a.latitude) * f,
        a.longitude + (b.longitude - a.longitude) * f,
        seconds: t,
      ));
    }
  }
  t += 3;
  fixes.add(_fix(corners.last.latitude, corners.last.longitude, seconds: t));
  return fixes;
}

/// Walks a big square, then a smaller square wholly inside it — the shape
/// that made the reported area grow without any new ground being claimed.
List<Position> _loopInsideLoopFixes() {
  const startLat = 45.4642, startLng = 9.1900;
  const dLat = 0.000905, dLng = 0.001281; // ~100 m per unit

  LatLng at(double x, double y) =>
      LatLng(startLat + dLat * y, startLng + dLng * x);

  final corners = <LatLng>[
    // Outer ~200 m square.
    at(0, 0), at(2, 0), at(2, 2), at(0, 2), at(0, 0),
    // Cut inside and run a ~100 m square entirely within it.
    at(0.5, 0.5), at(1.5, 0.5), at(1.5, 1.5), at(0.5, 1.5), at(0.5, 0.5),
  ];

  final fixes = <Position>[];
  var t = 0;
  for (int c = 0; c < corners.length - 1; c++) {
    final a = corners[c], b = corners[c + 1];
    for (int step = 0; step < 12; step++) {
      final f = step / 12;
      t += 5;
      fixes.add(_fix(
        a.latitude + (b.latitude - a.latitude) * f,
        a.longitude + (b.longitude - a.longitude) * f,
        seconds: t,
      ));
    }
  }
  t += 5;
  fixes.add(_fix(corners.last.latitude, corners.last.longitude, seconds: t));
  return fixes;
}

void main() {
  // The off-route buzz calls HapticFeedback, which needs a binding.
  TestWidgetsFlutterBinding.ensureInitialized();

  final controller = RunSessionController.instance;

  // The controller is a singleton, so every test must start from a known
  // state — which is exactly the property the reset test below is about.
  setUp(controller.reset);

  group('RunSessionController tracking', () {
    test('accumulates distance across accepted fixes', () {
      controller.onPosition(_fix(45.4642, 9.1900, seconds: 0));
      controller.onPosition(_fix(45.4642, 9.1913, seconds: 30));

      // ~100 m east at this latitude.
      expect(controller.distanceMeters, closeTo(100, 10));
      expect(controller.breadcrumb.length, 2);
    });

    test('drops fixes worse than the accuracy threshold', () {
      controller.onPosition(_fix(45.4642, 9.1900, seconds: 0));
      controller.onPosition(
        _fix(45.4642, 9.1913, seconds: 30, accuracy: 50),
      );

      expect(controller.breadcrumb.length, 1);
      expect(controller.distanceMeters, 0);
    });

    test('discards a GPS spike implying an impossible speed', () {
      controller.onPosition(_fix(45.4642, 9.1900, seconds: 0));
      // ~800 m in one second — far past the 8 m/s cap.
      controller.onPosition(_fix(45.4642, 9.2003, seconds: 1));

      expect(controller.breadcrumb.length, 1);
      expect(controller.distanceMeters, 0);
    });

    test('computes pace over the trailing window', () {
      controller.onPosition(_fix(45.4642, 9.1900, seconds: 0));
      controller.onPosition(_fix(45.4642, 9.1913, seconds: 30));

      // 100 m in 30 s = 5:00 min/km.
      expect(controller.currentPaceMinPerKm, isNotNull);
      expect(controller.currentPaceMinPerKm, closeTo(5.0, 0.5));
      expect(controller.bestPaceMinPerKm, closeTo(5.0, 0.5));
    });

    test('records elevation difference from altitude samples', () {
      controller.onPosition(_fix(45.4642, 9.1900, seconds: 0, altitude: 100));
      controller.onPosition(_fix(45.4642, 9.1913, seconds: 30, altitude: 135));

      expect(controller.elevationDifferenceMeters, closeTo(35, 0.1));
    });
  });

  group('RunSessionController loop detection', () {
    test('closes a loop when the trail returns to its start', () {
      for (final fix in _squareLoopFixes()) {
        controller.onPosition(fix);
      }

      expect(controller.loopsCompleted, 1);
      expect(controller.closedLoops.single.length, greaterThan(3));
    });

    test('does not close a loop on an out-and-back', () {
      // Straight out ~150 m and straight back along the same line. It returns
      // to its start, but encloses no area, so it must not register.
      var t = 0;
      for (int i = 0; i <= 15; i++) {
        t += 3;
        controller.onPosition(_fix(45.4642, 9.1900 + i * 0.000128, seconds: t));
      }
      for (int i = 14; i >= 0; i--) {
        t += 3;
        controller.onPosition(_fix(45.4642, 9.1900 + i * 0.000128, seconds: t));
      }

      expect(controller.loopsCompleted, 0);
    });

    test('keeps both blocks when a second loop is run next door', () {
      // Reported from the field against route creation, but the live run had
      // the same bug: superseding on breadcrumb-range overlap alone, B's
      // closure reaches back along the shared street into A's range and
      // deleted A — losing a real claim, its area and its XP.
      for (final fix in _twoAdjacentSquaresFixes()) {
        controller.onPosition(fix);
      }

      expect(controller.loopsCompleted, 2);

      final areas = controller.closedLoops
          .map(GeometryUtils.polygonAreaM2)
          .toList()
        ..sort();
      // Two separate ~100 m squares, neither swallowed by the other.
      expect(areas[0], closeTo(10000, 1500));
      expect(areas[1], closeTo(10000, 1500));

      // And they really are side by side rather than two copies of one block.
      final centroids = controller.closedLoops
          .map((loop) =>
              loop.fold(0.0, (s, p) => s + p.longitude) / loop.length)
          .toList()
        ..sort();
      expect(centroids[1] - centroids[0], greaterThan(0.0008));
    });
  });

  group('RunSessionController overlapping loops', () {
    test('a loop run inside another claims no extra area', () {
      for (final fix in _loopInsideLoopFixes()) {
        controller.onPosition(fix);
      }

      // The inner square encloses only ground the outer one already covers,
      // so it must not be recorded as a second claim — doing so reported
      // roughly a third more area than was actually taken.
      expect(controller.loopsCompleted, 1);

      final outerAreaM2 = controller.closedLoops
          .map(GeometryUtils.polygonAreaM2)
          .fold(0.0, (a, b) => a + b);
      // ~200 m square, and emphatically not that plus the ~100 m one.
      expect(outerAreaM2, closeTo(40000, 6000));
      expect(controller.claimedAreaM2, closeTo(outerAreaM2, 1));
    });
  });

  group('RunSessionController reset', () {
    // The singleton's one genuine hazard: a missed reset means the next run
    // inherits this one's breadcrumbs and claims ground nobody ran.
    test('a second run starts completely clean', () {
      for (final fix in _squareLoopFixes()) {
        controller.onPosition(fix);
      }
      expect(controller.distanceMeters, greaterThan(0));
      expect(controller.loopsCompleted, 1);
      expect(controller.breadcrumb, isNotEmpty);

      controller.reset();

      expect(controller.distanceMeters, 0);
      expect(controller.loopsCompleted, 0);
      expect(controller.breadcrumb, isEmpty);
      expect(controller.path, isEmpty);
      expect(controller.currentPosition, isNull);
      expect(controller.currentPaceMinPerKm, isNull);
      expect(controller.bestPaceMinPerKm, isNull);
      expect(controller.elevationDifferenceMeters, 0);
      expect(controller.lastHeading, isNull);
      expect(controller.guidance, isNull);
      expect(controller.elapsed, Duration.zero);
      expect(controller.hasStarted, isFalse);
      expect(controller.isPaused, isFalse);
      expect(controller.plannedRoute, isNull);
      expect(controller.isLoadingLocation, isTrue);
      expect(controller.permissionDenied, isFalse);
    });

    test('a loop from a previous run cannot leak into the next one', () {
      for (final fix in _squareLoopFixes()) {
        controller.onPosition(fix);
      }
      controller.reset();

      // Two fixes nowhere near the old loop: without a clean reset the stale
      // breadcrumbs would still be sitting there closing their own loop.
      controller.onPosition(_fix(45.5000, 9.2000, seconds: 0));
      controller.onPosition(_fix(45.5000, 9.2013, seconds: 30));

      expect(controller.breadcrumb.length, 2);
      expect(controller.loopsCompleted, 0);
    });
  });

  group('RunSessionController notifications', () {
    test('notifies listeners on each accepted fix', () {
      var notifications = 0;
      void listener() => notifications++;
      controller.addListener(listener);
      addTearDown(() => controller.removeListener(listener));

      controller.onPosition(_fix(45.4642, 9.1900, seconds: 0));
      controller.onPosition(_fix(45.4642, 9.1913, seconds: 30));

      expect(notifications, 2);
    });

    test('does not notify for a rejected fix', () {
      controller.onPosition(_fix(45.4642, 9.1900, seconds: 0));

      var notifications = 0;
      void listener() => notifications++;
      controller.addListener(listener);
      addTearDown(() => controller.removeListener(listener));

      controller.onPosition(_fix(45.4642, 9.1913, seconds: 30, accuracy: 99));

      expect(notifications, 0);
    });
  });

  group('RunSessionController countdown', () {
    // A five-second pre-run countdown driven by `Timer.periodic`. Run on a
    // virtual clock so a case costs microseconds rather than five real seconds.
    test('starts at five', () {
      fakeAsync((async) {
        controller.startCountdown();

        expect(controller.isCountingDown, isTrue);
        expect(controller.countdownValue, 5);
      });
    });

    test('ticks down one second at a time', () {
      fakeAsync((async) {
        controller.startCountdown();

        async.elapse(const Duration(seconds: 1));
        expect(controller.countdownValue, 4);

        async.elapse(const Duration(seconds: 2));
        expect(controller.countdownValue, 2);
      });
    });

    test('pausing freezes the clock', () {
      fakeAsync((async) {
        controller.startCountdown();
        async.elapse(const Duration(seconds: 2));
        expect(controller.countdownValue, 3);

        controller.pauseCountdown();
        async.elapse(const Duration(seconds: 3));

        expect(controller.countdownPaused, isTrue);
        expect(controller.countdownValue, 3, reason: 'frozen while paused');
      });
    });

    test('resuming restarts from five rather than continuing', () {
      // Deliberate: a runner who paused with one second left needs time to get
      // back to the start line, not to be launched the instant they resume.
      fakeAsync((async) {
        controller.startCountdown();
        async.elapse(const Duration(seconds: 4));
        expect(controller.countdownValue, 1);

        controller.toggleCountdownPause(); // pause
        controller.toggleCountdownPause(); // resume

        expect(controller.countdownValue, 5);
        expect(controller.countdownPaused, isFalse);
      });
    });

    test('a paused countdown never starts the run on its own', () {
      fakeAsync((async) {
        controller.startCountdown();
        controller.pauseCountdown();

        async.elapse(const Duration(minutes: 1));

        expect(controller.hasStarted, isFalse);
      });
    });
  });

  group('RunSessionController pause during a run', () {
    test('a fix arriving while paused is ignored entirely', () {
      // `onPosition` returns immediately when paused — a runner waiting at a
      // crossing must not accumulate distance from GPS drift.
      controller.onPosition(_fix(45.4642, 9.1900, seconds: 0));
      final before = controller.distanceMeters;

      controller.togglePause();
      controller.onPosition(_fix(45.4642, 9.1913, seconds: 30));

      expect(controller.isPaused, isTrue);
      expect(controller.distanceMeters, before);
    });

    test('the breadcrumb does not grow while paused', () {
      controller.onPosition(_fix(45.4642, 9.1900, seconds: 0));
      final before = controller.breadcrumb.length;

      controller.togglePause();
      controller.onPosition(_fix(45.4642, 9.1913, seconds: 30));

      expect(controller.breadcrumb.length, before);
    });

    test('resuming accepts fixes again', () {
      controller.onPosition(_fix(45.4642, 9.1900, seconds: 0));
      controller.togglePause();
      controller.onPosition(_fix(45.4642, 9.1913, seconds: 30));

      controller.togglePause();
      controller.onPosition(_fix(45.4642, 9.1913, seconds: 60));

      expect(controller.isPaused, isFalse);
      expect(controller.distanceMeters, greaterThan(0));
    });
  });

  group('RunSessionController heart rate', () {
    // Reported by the watch over the Data Layer; the phone measures none of it.
    // It ends up in the owner-only private subcollection, never on the public
    // session document.
    test('starts with none', () {
      expect(controller.heartRateBpm, isNull);
      expect(controller.avgHeartRateBpm, isNull);
      expect(controller.maxHeartRateBpm, isNull);
    });

    test('records what the watch reports', () {
      controller.reportHeartRate(current: 148, average: 152, max: 178);

      expect(controller.heartRateBpm, 148);
      expect(controller.avgHeartRateBpm, 152);
      expect(controller.maxHeartRateBpm, 178);
    });

    test('notifies listeners so the readout repaints', () {
      var notifications = 0;
      void listener() => notifications++;
      controller.addListener(listener);
      addTearDown(() => controller.removeListener(listener));

      controller.reportHeartRate(current: 148);

      expect(notifications, 1);
    });

    test('a reset run reports no heart rate', () {
      controller.reportHeartRate(current: 148, average: 152, max: 178);

      controller.reset();

      expect(controller.heartRateBpm, isNull);
      expect(controller.avgHeartRateBpm, isNull);
      expect(controller.maxHeartRateBpm, isNull);
    });
  });

  group('RunSessionController claimed area', () {
    test('is zero before any loop closes', () {
      expect(controller.claimedAreaM2, 0);
      expect(controller.loopsCompleted, 0);
    });

    test('reports the area of a closed loop', () {
      for (final fix in _squareLoopFixes()) {
        controller.onPosition(fix);
      }

      expect(controller.loopsCompleted, 1);
      // A ~100 m square is about 10,000 m2; generous bounds for GPS geometry.
      expect(controller.claimedAreaM2, greaterThan(5000));
      expect(controller.claimedAreaM2, lessThan(20000));
    });

    test('matches the polygon the loop actually encloses', () {
      for (final fix in _squareLoopFixes()) {
        controller.onPosition(fix);
      }

      final expected =
          GeometryUtils.polygonAreaM2(controller.closedLoops.single);
      expect(controller.claimedAreaM2, closeTo(expected, 0.001));
    });
  });

  group('RunSessionController route guidance', () {
    // A straight line running east, dense enough that the guidance search has
    // real segments to match against.
    List<LatLng> straightRoute() => [
          for (var i = 0; i <= 40; i++) LatLng(45.4642, 9.1900 + i * 0.0002),
        ];

    test('reports no guidance without a planned route', () {
      controller.onPosition(_fix(45.4642, 9.1900, seconds: 0));

      expect(controller.guidance, isNull);
      expect(controller.routeProgress, isNull);
    });

    test('produces guidance once a route is armed', () {
      controller.armGuidanceForTesting(straightRoute());

      controller.onPosition(_fix(45.4642, 9.1900, seconds: 0));

      expect(controller.guidance, isNotNull);
    });

    test('a runner on the line is not flagged off route', () {
      controller.armGuidanceForTesting(straightRoute());

      for (var i = 0; i < 6; i++) {
        controller.onPosition(
          _fix(45.4642, 9.1900 + i * 0.0002, seconds: i * 5),
        );
      }

      expect(controller.guidance!.isOffRoute, isFalse);
    });

    // Drifting north, away from the line. One step per fix, sized so the
    // implied pace stays under the 8 m/s spike cap — a fix that trips that
    // cap is discarded before guidance ever sees it, so an instantaneous
    // teleport off the route would test nothing at all.
    const stepDegrees = 0.00025; // ~28 m north per fix
    void driftNorth(int steps) {
      for (var i = 1; i <= steps; i++) {
        controller.onPosition(
          _fix(45.4642 + stepDegrees * i, 9.1900, seconds: i * 5),
        );
      }
    }

    test('a single stray fix does not trigger off-route', () {
      // Debounced over several consecutive fixes: cutting a roundabout at the
      // crosswalk should not buzz the runner and swing the arrow around.
      controller.armGuidanceForTesting(straightRoute());
      controller.onPosition(_fix(45.4642, 9.1900, seconds: 0));

      // ~56 m north of the line — well past the 35 m threshold, but once.
      controller.onPosition(_fix(45.4647, 9.1900, seconds: 10));

      expect(controller.guidance!.offRouteFixes, 1);
      expect(controller.guidance!.isOffRoute, isFalse);
    });

    test('four consecutive strays are still not enough', () {
      // The threshold is five. Pinned so that loosening the debounce has to
      // be a deliberate edit, not an accident.
      controller.armGuidanceForTesting(straightRoute());
      controller.onPosition(_fix(45.4642, 9.1900, seconds: 0));

      driftNorth(5); // the first step is inside 35 m, so four count

      expect(controller.guidance!.offRouteFixes, 4);
      expect(controller.guidance!.isOffRoute, isFalse);
    });

    test('a sustained deviation does trigger it', () {
      controller.armGuidanceForTesting(straightRoute());
      controller.onPosition(_fix(45.4642, 9.1900, seconds: 0));

      driftNorth(6);

      expect(controller.guidance!.isOffRoute, isTrue);
    });

    test('the arrow points back at the route once off it', () {
      // Off route the guidance aims at the nearest point on the line, not
      // further along it — the runner has to get back first.
      controller.armGuidanceForTesting(straightRoute());
      controller.onPosition(_fix(45.4642, 9.1900, seconds: 0));

      driftNorth(6);

      // Due north of the line, so the way back is due south.
      expect(controller.guidance!.targetBearingDegrees, closeTo(180, 5));
      expect(controller.guidance!.offRouteMeters, greaterThan(35));
    });

    test('rejoining clears it immediately, without a debounce', () {
      // Asymmetric on purpose: a runner who has rejoined is told at once, even
      // though leaving takes five fixes to confirm.
      controller.armGuidanceForTesting(straightRoute());
      controller.onPosition(_fix(45.4642, 9.1900, seconds: 0));
      driftNorth(6);
      expect(controller.guidance!.isOffRoute, isTrue);

      // Walk back in at the same plausible pace. Still off route the whole
      // way, because forgiveness happens at the tighter 25 m.
      var t = 30;
      for (var i = 5; i >= 1; i--) {
        t += 5;
        controller
            .onPosition(_fix(45.4642 + stepDegrees * i, 9.1900, seconds: t));
      }
      expect(controller.guidance!.isOffRoute, isTrue,
          reason: 'hysteresis - forgiven at 25 m, not at the 35 m it left on');

      // One single fix back on the line is enough — no debounce on the way in.
      controller.onPosition(_fix(45.4642, 9.1900, seconds: t + 5));
      expect(controller.guidance!.isOffRoute, isFalse);
    });

    test('route progress is tracked alongside guidance', () {
      controller.armGuidanceForTesting(straightRoute());

      controller.onPosition(_fix(45.4642, 9.1900, seconds: 0));

      expect(controller.routeProgress, isNotNull);
    });

    test('a reset run forgets the route', () {
      controller.armGuidanceForTesting(straightRoute());
      controller.onPosition(_fix(45.4642, 9.1900, seconds: 0));
      expect(controller.guidance, isNotNull);

      controller.reset();

      expect(controller.plannedRoute, isNull);
      expect(controller.guidance, isNull);
      expect(controller.routeProgress, isNull);
    });
  });
}
