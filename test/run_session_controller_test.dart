import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import 'package:dash_application/services/run_session_controller.dart';

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
}
