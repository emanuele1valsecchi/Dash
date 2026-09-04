import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'package:dash/widgets/map/enhanced_map_gestures.dart';

import '../helpers/pump_app.dart';

/// The gesture layer wrapped around every interactive map in the app.
///
/// TEST_NOTES calls this "the most intricate untested logic in the app, and
/// the most likely to regress silently", and silence is the point: none of
/// what follows throws when it breaks. A dead zone that stops working makes
/// the map twitch under an ordinary pinch; a release correction that stops
/// working makes it jump sideways when fingers lift. Both are things you feel
/// rather than see in a stack trace, on six screens at once.
///
/// Everything here drives raw pointer events, because that is what the widget
/// itself listens to — it deliberately uses a `Listener` rather than joining
/// the gesture arena, so it can observe a pinch without competing with
/// flutter_map's own recognizer.
void main() {
  late MapController controller;

  const size = Size(600, 600);

  Future<void> pumpMap(WidgetTester tester, {double threshold = 8.0}) async {
    controller = MapController();
    addTearDown(controller.dispose);

    await pumpDashWidget(
      tester,
      EnhancedMapGestures(
        mapController: controller,
        rotationThresholdDeg: threshold,
        child: FlutterMap(
          mapController: controller,
          options: const MapOptions(
            initialCenter: LatLng(45.4642, 9.1900),
            initialZoom: 13,
            // Exactly what every screen wrapping this widget sets. Leaving
            // flutter_map's own rotate enabled makes it fight the widget
            // under test — and its rotation is what the assertions would
            // then be measuring. Fling is dropped too, so a released gesture
            // does not keep animating the camera under the next assertion.
            interactionOptions: InteractionOptions(
              flags: InteractiveFlag.all &
                  ~InteractiveFlag.rotate &
                  ~InteractiveFlag.flingAnimation,
            ),
          ),
          // No TileLayer: tiles are network images and paint nothing useful
          // here. The gesture layer does not care what is underneath it.
          children: const [],
        ),
      ),
      surfaceSize: size,
    );
    await tester.pump();
  }

  /// Lifts every finger and pumps past flutter_map's own double-tap
  /// detection window, which starts a timer on pointer-up. Without this a
  /// test whose fingers barely moved ends with that timer still pending and
  /// fails on `!timersPending` rather than on anything it asserted.
  Future<void> release(WidgetTester tester, List<TestGesture> gestures) async {
    for (final g in gestures) {
      await g.up();
    }
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// A point [distance] away from [from] at [degrees], in the widget's own
  /// coordinate space — so a twist can be expressed as the angle it makes.
  Offset at(Offset from, double degrees, {double distance = 200}) {
    final rad = degrees * math.pi / 180;
    return from + Offset(math.cos(rad) * distance, math.sin(rad) * distance);
  }

  /// Puts two fingers down horizontally and twists the second one to
  /// [degrees], which is exactly the angle the widget measures between them.
  Future<List<TestGesture>> twistTo(WidgetTester tester, double degrees) async {
    const anchor = Offset(200, 300);
    final a = await tester.startGesture(anchor, pointer: 1);
    final b = await tester.startGesture(at(anchor, 0), pointer: 2);
    await tester.pump();

    await b.moveTo(at(anchor, degrees));
    await tester.pump();
    return [a, b];
  }

  group('the rotation dead zone', () {
    testWidgets('a small twist rotates nothing at all', (tester) async {
      // The whole reason this widget exists: an ordinary pinch involves a few
      // degrees of incidental twist, and the map must not follow it.
      await pumpMap(tester);
      final before = controller.camera.rotation;

      final gestures = await twistTo(tester, 5);

      expect(controller.camera.rotation, before);
      await release(tester, gestures);
    });

    testWidgets('a twist past the threshold does rotate', (tester) async {
      await pumpMap(tester);
      final before = controller.camera.rotation;

      final gestures = await twistTo(tester, 20);

      expect(controller.camera.rotation, isNot(before));
      await release(tester, gestures);
    });

    testWidgets('rotation picks up from zero, not from the threshold',
        (tester) async {
      // Without subtracting the dead-zone amount the map would jump by the
      // whole threshold the instant it is crossed — the exact judder the
      // dead zone was added to remove.
      await pumpMap(tester);
      final before = controller.camera.rotation;

      final gestures = await twistTo(tester, 10);
      final applied = (controller.camera.rotation - before).abs();

      expect(applied, closeTo(2, 0.5),
          reason: 'a 10 degree twist past an 8 degree dead zone is 2 degrees');
      await release(tester, gestures);
    });

    testWidgets('the threshold is configurable', (tester) async {
      await pumpMap(tester, threshold: 20);
      final before = controller.camera.rotation;

      final gestures = await twistTo(tester, 10);

      expect(controller.camera.rotation, before,
          reason: '10 degrees is inside a 20 degree dead zone');
      await release(tester, gestures);
    });

    testWidgets('one finger never rotates, however far it travels',
        (tester) async {
      // A single-finger drag is a pan. Rotation needs exactly two.
      await pumpMap(tester);
      final before = controller.camera.rotation;

      final g = await tester.startGesture(const Offset(200, 300), pointer: 1);
      await tester.pump();
      await g.moveTo(const Offset(400, 100));
      await tester.pump();

      expect(controller.camera.rotation, before);
      await release(tester, [g]);
    });
  });

  group('a third finger', () {
    testWidgets('stops rotation rather than re-basing onto a different pair',
        (tester) async {
      // Silently re-basing would make the map lurch when a palm or a third
      // finger brushes the screen mid-twist.
      await pumpMap(tester);
      const anchor = Offset(200, 300);
      final a = await tester.startGesture(anchor, pointer: 1);
      final b = await tester.startGesture(at(anchor, 0), pointer: 2);
      await tester.pump();

      final c = await tester.startGesture(const Offset(100, 100), pointer: 3);
      await tester.pump();
      final afterThird = controller.camera.rotation;

      await b.moveTo(at(anchor, 40));
      await tester.pump();

      expect(controller.camera.rotation, afterThird,
          reason: 'with three fingers down nothing should rotate');

      await release(tester, [a, b, c]);
    });

    testWidgets('lifting back to two re-arms with a fresh dead zone',
        (tester) async {
      // The re-arm is what stops the map snapping to catch up with however
      // far the fingers moved while the third was down.
      await pumpMap(tester);
      const anchor = Offset(200, 300);
      final a = await tester.startGesture(anchor, pointer: 1);
      final b = await tester.startGesture(at(anchor, 0), pointer: 2);
      await tester.pump();
      final c = await tester.startGesture(const Offset(100, 100), pointer: 3);
      await tester.pump();

      // Move well past the threshold while the third finger is down...
      await b.moveTo(at(anchor, 40));
      await tester.pump();
      await c.up();
      await tester.pump();
      final afterRearm = controller.camera.rotation;

      // ...then a small twist from the new base must still be inside the
      // dead zone, which it only is if the base was reset to 40 degrees.
      await b.moveTo(at(anchor, 44));
      await tester.pump();

      expect(controller.camera.rotation, afterRearm,
          reason: 'the dead zone should be measured from the new base');

      await release(tester, [a, b]);
    });
  });

  group('the multi-touch release jump', () {
    testWidgets('the camera is restored when one finger lifts mid-pinch',
        (tester) async {
      // Flutter's ScaleGestureRecognizer recomputes its focal point the
      // instant a pointer is removed, jumping from the midpoint of two
      // fingers to the position of the one still down, and flutter_map turns
      // that discontinuity into a real pan. The fix restores the last
      // known-good camera.
      await pumpMap(tester);
      const anchor = Offset(200, 300);
      final a = await tester.startGesture(anchor, pointer: 1);
      final b = await tester.startGesture(at(anchor, 0), pointer: 2);
      await tester.pump();

      // A move with 2+ fingers down is what records the stable camera.
      await b.moveTo(at(anchor, 0, distance: 260));
      await tester.pump();
      final stable = controller.camera.center;

      // Stand in for the recognizer's focal-point discontinuity. The real one
      // is produced deep inside Flutter's ScaleGestureRecognizer and cannot
      // be provoked reliably from synthetic pointers, so the camera is
      // displaced directly — the widget's contract is "restore the last
      // known-good camera when a 2+ touch drops below 2", and that is what
      // is being checked. Without this displacement the assertion is
      // vacuous: it passes whether or not the correction exists.
      controller.move(const LatLng(45.50, 9.25), controller.camera.zoom);
      await tester.pump();
      expect(controller.camera.center.latitude, closeTo(45.50, 1e-6),
          reason: 'the simulated jump should have landed');

      await b.up();
      await tester.pump();

      expect(controller.camera.center.latitude, closeTo(stable.latitude, 1e-6),
          reason: 'the jump should have been undone on release');
      expect(controller.camera.center.longitude,
          closeTo(stable.longitude, 1e-6));

      await release(tester, [a]);
    });

    testWidgets('a plain single-finger drag is left completely alone',
        (tester) async {
      // The correction must not touch ordinary panning — an earlier version
      // disabled native fling outright and lost momentum panning with it.
      await pumpMap(tester);

      final g = await tester.startGesture(const Offset(300, 300), pointer: 1);
      await tester.pump();
      await g.moveTo(const Offset(200, 300));
      await tester.pump();
      final afterDrag = controller.camera.center;

      await g.up();
      await tester.pump();

      expect(controller.camera.center, afterDrag,
          reason: 'no multi-finger drop happened, so nothing should be undone');
    });
  });

  group('lifecycle', () {
    testWidgets('disposing mid-gesture does not throw', (tester) async {
      // The settle runs in a microtask and checks `mounted`; without that
      // check, navigating away mid-pinch would fire into a dead State.
      await pumpMap(tester);
      const anchor = Offset(200, 300);
      final a = await tester.startGesture(anchor, pointer: 1);
      await tester.startGesture(at(anchor, 0), pointer: 2);
      await tester.pump();
      await a.moveTo(at(anchor, 30));
      await tester.pump();

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();

      expect(tester.takeException(), isNull);
    });
  });
}
