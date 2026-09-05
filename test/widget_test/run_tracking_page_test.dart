import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:network_image_mock/network_image_mock.dart';

import 'package:dash/config/app_theme.dart';
import 'package:dash/screens/run_tracking_page.dart';
import 'package:dash/services/claimed_area_repository.dart';
import 'package:dash/services/run_session_controller.dart';
import 'package:dash/services/user_appearance_service.dart';
import 'package:dash/services/water_fountain_service.dart';
import 'package:dash/services/wear_bridge.dart';
import 'package:dash/widgets/map/claimed_areas_layer.dart';

import '../helpers/fake_location_platform.dart';
import '../helpers/pump_app.dart';

/// The live-run screen. Its *tracking* maths already has 663 lines of tests
/// against `RunSessionController`; what had none is the screen on top — the
/// part that decides whether a run in progress can be walked away from.
///
/// That is the risk worth covering here. Every exit from this screen either
/// preserves a run or destroys it, and the difference is not visible: the
/// system back gesture is wired to behave like **Finish** (which offers to
/// save), never like the X button (which discards). Getting that backwards
/// silently throws away a run the user actually did — distance, loops and
/// claimed territory with it — and nothing reports an error.
void main() {
  late FakeFirebaseFirestore db;
  late FakeLocationPlatform location;
  late MockFirebaseAuth auth;

  final controller = RunSessionController.instance;
  const milan = LatLng(45.4642, 9.1900);

  const wearChannel = MethodChannel('dash/wear_bridge');
  const runServiceChannel = MethodChannel('dash/run_service');
  const ttsChannel = MethodChannel('flutter_tts');

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    setupFirebaseCoreMocks();
    await Firebase.initializeApp();
  });

  setUp(() async {
    db = FakeFirebaseFirestore();
    location = installFakeLocationPlatform();
    location.grant(milan);
    auth = MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: 'me'));

    // The screen reaches three platform channels on the way up: the watch
    // bridge, the Android foreground service, and text-to-speech. None has a
    // Dart-side seam, so each is answered at the channel instead.
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final channel in [wearChannel, runServiceChannel, ttsChannel]) {
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'nodes' || call.method == 'getData') return <Object?>[];
        return null;
      });
    }
    addTearDown(() {
      for (final channel in [wearChannel, runServiceChannel, ttsChannel]) {
        messenger.setMockMethodCallHandler(channel, null);
      }
    });

    UserAppearanceService.instance.firestoreOverride = db;
    addTearDown(UserAppearanceService.instance.clearForTest);

    WaterFountainService.instance.clientOverride =
        MockClient((_) async => http.Response('{"elements":[]}', 200));
    addTearDown(WaterFountainService.instance.resetForTest);

    // The controller is an app-lifetime singleton. A missed reset is the one
    // genuine hazard it has: the next run would inherit these breadcrumbs and
    // claim ground nobody ran.
    controller.reset();
    WearBridge.instance.resetForTest();
    addTearDown(controller.reset);
  });

  final navigatorKey = GlobalKey<NavigatorState>();

  /// The screen runs two continuous tickers (the 10 Hz stats pulse and the
  /// location-dot chase), so `pumpAndSettle` never returns here — every wait
  /// in this file is a bounded pump instead.
  Future<void> settle(WidgetTester tester, {int frames = 12}) async {
    for (var i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// Pushes the page as a real route rather than using it as `home`, so the
  /// system back gesture has something to pop and `PopScope` is actually
  /// exercised. As `home` there is no route beneath it and back is a no-op.
  Future<void> pumpPage(
    WidgetTester tester, {
    List<LatLng>? plannedRoute,
    Size surface = kPhoneSurface,
  }) async {
    await mockNetworkImagesFor(() async {
      tester.view.physicalSize = surface;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(),
        navigatorKey: navigatorKey,
        home: const Scaffold(body: Text('beneath')),
      ));

      unawaited(navigatorKey.currentState!.push(MaterialPageRoute<void>(
        builder: (_) => RunTrackingPage(
          plannedRoute: plannedRoute,
          auth: auth,
          areaRepository: ClaimedAreaRepository.withDependencies(db: db),
        ),
      )));
      await settle(tester);
    });
  }

  /// Runs the pre-run countdown out so the screen is in its recording state.
  Future<void> startRun(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    await settle(tester);
  }

  group('before the run starts', () {
    testWidgets('counts down from 5', (tester) async {
      await pumpPage(tester);

      expect(controller.isCountingDown, isTrue);
      expect(find.text('5'), findsOneWidget);

      await tester.pump(const Duration(seconds: 1));
      expect(find.text('4'), findsOneWidget);
    });

    testWidgets('STOP pauses the countdown where it stands', (tester) async {
      await pumpPage(tester);
      await tester.pump(const Duration(seconds: 1));

      await tester.tap(find.text('STOP'));
      await tester.pump();

      expect(find.text('RESUME'), findsOneWidget);
      final frozen = controller.countdownValue;
      await tester.pump(const Duration(seconds: 2));
      expect(controller.countdownValue, frozen, reason: 'a paused clock must not tick');
    });

    testWidgets('resuming restarts from 5 rather than continuing', (tester) async {
      // Deliberate: someone who stopped at 2 and comes back needs the full
      // five seconds again, not two.
      await pumpPage(tester);
      await tester.pump(const Duration(seconds: 3));
      await tester.tap(find.text('STOP'));
      await tester.pump();

      await tester.tap(find.text('RESUME'));
      await tester.pump();

      expect(controller.countdownValue, 5);
    });

    testWidgets('back leaves without any confirmation', (tester) async {
      // Nothing has been recorded yet, so there is nothing to lose and
      // nothing to ask about.
      await pumpPage(tester);
      expect(controller.hasStarted, isFalse);

      final popped = await tester.binding.handlePopRoute();

      expect(popped, isTrue, reason: 'the route should simply pop');
      await settle(tester);
      expect(find.text('Discard this run?'), findsNothing);
      expect(find.text('Finish already?'), findsNothing);
    });
  });

  group('once the run is recording', () {
    testWidgets('the countdown gives way to the stats view', (tester) async {
      await pumpPage(tester);
      await startRun(tester);

      expect(controller.hasStarted, isTrue);
      expect(controller.isCountingDown, isFalse);
      expect(find.text('5'), findsNothing);
    });

    testWidgets('back offers to finish, never to discard', (tester) async {
      // The whole point of this file. `_confirmDiscard` throws the run away
      // with no summary; back must not reach it.
      await pumpPage(tester);
      await startRun(tester);

      await tester.binding.handlePopRoute();
      await settle(tester);

      expect(find.text('Finish already?'), findsOneWidget,
          reason: 'back goes through _confirmFinish');
      expect(find.text('Discard this run?'), findsNothing,
          reason: 'back must never silently discard a recorded run');
    });

    testWidgets('back does not pop the screen on its own', (tester) async {
      // PopScope must swallow the gesture — if the route popped *and* asked,
      // the run would be gone before the answer arrived.
      await pumpPage(tester);
      await startRun(tester);

      final popped = await tester.binding.handlePopRoute();

      expect(popped, isTrue, reason: 'the gesture is handled...');
      await settle(tester);
      expect(find.byType(RunTrackingPage), findsOneWidget,
          reason: '...but the screen stays until the user answers');
    });

    testWidgets('declining the finish prompt returns to the run', (tester) async {
      await pumpPage(tester);
      await startRun(tester);

      await tester.binding.handlePopRoute();
      await settle(tester);
      await tester.tap(find.text('Cancel'));
      await settle(tester);

      expect(find.byType(RunTrackingPage), findsOneWidget);
      expect(controller.hasStarted, isTrue, reason: 'the run is still going');
    });

    testWidgets('a run with real distance finishes without the "barely moved" prompt',
        (tester) async {
      // The prompt is a guard against an accidental tap, not something to sit
      // through after a genuine run.
      await pumpPage(tester);
      await startRun(tester);

      controller.onPosition(positionAt(45.4642, 9.1900));
      controller.onPosition(positionAt(45.4642, 9.1913));
      await tester.pump();
      expect(controller.distanceMeters, greaterThan(20));

      await tester.binding.handlePopRoute();
      await settle(tester);

      expect(find.text('Finish already?'), findsNothing);
    });
  });

  group('claimed areas on the run map', () {
    Future<void> seedArea(String id, String userId) async {
      await db.collection('claimedAreas').doc(id).set({
        'userId': userId,
        'polygon': [
          {
            'outer': [
              const GeoPoint(45.4642, 9.1900),
              const GeoPoint(45.4652, 9.1900),
              const GeoPoint(45.4652, 9.1910),
              const GeoPoint(45.4642, 9.1910),
            ],
            'holes': <Map<String, dynamic>>[],
          }
        ],
        'contributions': <Map<String, dynamic>>[],
        'createdAt': Timestamp.fromDate(DateTime.utc(2026, 1, 1)),
        'updatedAt': Timestamp.fromDate(DateTime.utc(2026, 1, 1)),
      });
    }

    testWidgets('are loaded once and shown while running', (tester) async {
      await seedArea('mine', 'me');
      await seedArea('theirs', 'rival');

      // Wider than a phone on purpose. The expanded map's stats bar lays out
      // a single unwrapped Row of text, and `flutter_test`'s default font
      // draws every glyph as a square of the font size — so that row measures
      // far wider here than with a real typeface and trips a spurious overflow
      // at phone widths. The extra room keeps this test about the area layer
      // rather than about test-font metrics.
      await pumpPage(tester, surface: const Size(900, 1000));
      await startRun(tester);

      // The stats view shows a small preview map with no area layer; the
      // polygons live on the expanded map, reached by tapping the preview.
      await tester.tap(find.byType(FlutterMap).first);
      await settle(tester);

      final layer = tester.widget<ClaimedAreasLayer>(
          find.byType(ClaimedAreasLayer).first);
      expect(layer.areas.map((a) => a.id).toList()..sort(), ['mine', 'theirs']);
    });
  });

  group('permission', () {
    testWidgets('a refusal never starts a countdown', (tester) async {
      // Recording a run with no GPS would produce an empty path that still
      // looks like a completed session.
      location.deny();

      await pumpPage(tester);

      expect(controller.permissionDenied, isTrue);
      expect(controller.isCountingDown, isFalse);
      expect(controller.hasStarted, isFalse);
    });
  });
}
