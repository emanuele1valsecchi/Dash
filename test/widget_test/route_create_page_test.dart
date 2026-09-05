import 'dart:async';
import 'dart:convert';

import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:mockito/mockito.dart';
import 'package:network_image_mock/network_image_mock.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dash/screens/route_create_page.dart';
import 'package:dash/services/place_search_service.dart';
import 'package:dash/services/routing_service.dart';
import 'package:dash/services/user_appearance_service.dart';

import '../helpers/fake_location_platform.dart';
import '../helpers/pump_app.dart';
import '../mocks.mocks.dart' hide MockUser;

/// The route-planning map: drop pins, draw freehand, undo, save.
///
/// The geometry this screen is *about* — which shapes count as a closed loop,
/// which loops supersede which — lives in `RouteLoops` and is tested directly
/// in `route_loops_test.dart`. What had no coverage at all is the screen: the
/// tool modes that gate each other, the undo stack, and the fact that every
/// pin placement is an ORS round trip that can fail.
///
/// Map taps are delivered through `MapOptions.onTap` rather than by tapping
/// the widget. A synthetic tap on a `FlutterMap` goes through its own gesture
/// recognizers and yields a map coordinate derived from the camera, so the
/// test would be asserting on flutter_map's projection rather than on this
/// screen. Calling the callback is what the map does on a real tap, with the
/// coordinate chosen by the test.
void main() {
  late FakeLocationPlatform location;
  late MockFirebaseAuth auth;
  late MockFirebaseFunctions functions;
  late MockHttpsCallable callable;
  late MockClaimedAreaRepository areas;
  late MockRouteRepository routes;

  const milan = LatLng(45.4642, 9.1900);

  setUpAll(() async {
    // `ClaimedAreasLayer` reaches `FirebaseAuth.instance` in its own build to
    // decide which polygons are the viewer's own, and takes no seam. A mock
    // app is what makes it constructible; nothing here asserts on it.
    TestWidgetsFlutterBinding.ensureInitialized();
    setupFirebaseCoreMocks();
    await Firebase.initializeApp();
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    location = installFakeLocationPlatform();
    location.grant(milan);
    auth = MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: 'me'));

    areas = MockClaimedAreaRepository();
    when(areas.areasStream()).thenAnswer((_) => const Stream.empty());
    routes = MockRouteRepository();

    functions = MockFirebaseFunctions();
    callable = MockHttpsCallable();
    when(functions.httpsCallable(any, options: anyNamed('options')))
        .thenReturn(callable);
    RoutingService.functionsOverride = functions;
    addTearDown(() => RoutingService.functionsOverride = null);

    UserAppearanceService.instance.firestoreOverride = null;
    addTearDown(UserAppearanceService.instance.clearForTest);

    PlaceSearchService.clientOverride =
        MockClient((_) async => http.Response('[]', 200));
    addTearDown(() => PlaceSearchService.clientOverride = null);
  });

  /// Makes every routing call answer with a straight two-point leg between
  /// the requested endpoints, so a tapped pin produces a real segment.
  void routingSucceeds() {
    when(callable.call(any)).thenAnswer((invocation) async {
      final args = invocation.positionalArguments.first as Map<String, dynamic>;
      final o = args['origin'] as Map;
      final d = args['destination'] as Map;
      final result = MockHttpsCallableResult<dynamic>();
      when(result.data).thenReturn({
        'status': 200,
        'body': jsonDecode(jsonEncode({
          'features': [
            {
              'properties': {
                'summary': {'distance': 500.0}
              },
              'geometry': {
                'coordinates': [
                  [o['lng'], o['lat']],
                  [d['lng'], d['lat']],
                ]
              }
            }
          ]
        })),
      });
      return result;
    });
  }

  /// Leaves every routing call in flight forever, so the screen can be
  /// inspected mid-request. A `Completer` rather than a delay: an unfinished
  /// `Future.delayed` is a pending timer, which fails the test on teardown.
  void routingHangs() {
    final never = Completer<MockHttpsCallableResult<dynamic>>();
    when(callable.call(any)).thenAnswer((_) => never.future);
  }

  /// Makes every routing call fail. The screen falls back to a straight line
  /// rather than refusing the pin — see the group on that below.
  void routingFails() {
    when(callable.call(any))
        .thenAnswer((_) async => throw Exception('unreachable'));
  }

  Future<void> pumpPage(WidgetTester tester) async {
    await mockNetworkImagesFor(() async {
      await pumpDashWidget(
        tester,
        RouteCreatePage(
          auth: auth,
          areaRepository: areas,
          routeRepository: routes,
        ),
        wrapInScaffold: false,
        // Roomy: the toolbar carries three labelled tool buttons plus undo
        // and redo, and the test font is ~1 em per character. See
        // TEST_NOTES 1.2.
        surfaceSize: const Size(1000, 1600),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    });
  }

  /// Delivers a map tap at [point], the way `MapOptions.onTap` would.
  Future<void> tapMap(WidgetTester tester, LatLng point) async {
    final map = tester.widget<FlutterMap>(find.byType(FlutterMap));
    map.options.onTap!(
      TapPosition(Offset.zero, Offset.zero),
      point,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  /// A point `east` "units" east of Milan; one unit is roughly 100 m.
  LatLng at(double north, double east) =>
      LatLng(milan.latitude + north * 0.0009, milan.longitude + east * 0.00128);

  /// `find.byTooltip` matches the tooltip wrapper, not the button inside it.
  Finder undoButton() => find.widgetWithIcon(IconButton, Icons.undo_rounded);
  Finder redoButton() => find.widgetWithIcon(IconButton, Icons.redo_rounded);

  Finder toolButton(String label) => find.ancestor(
        of: find.text(label),
        matching: find.byType(InkWell),
      );

  group('the screen opens', () {
    testWidgets('with a map and the three tools', (tester) async {
      await pumpPage(tester);

      expect(find.byType(FlutterMap), findsOneWidget);
      expect(find.text('Pin'), findsOneWidget);
      expect(find.text('Draw'), findsOneWidget);
      expect(find.text('Delete'), findsOneWidget);
    });

    testWidgets('with nothing to undo or redo yet', (tester) async {
      await pumpPage(tester);

      expect(tester.widget<IconButton>(undoButton()).onPressed,
          isNull);
      expect(tester.widget<IconButton>(redoButton()).onPressed,
          isNull);
    });

    testWidgets('with delete mode unavailable on an empty route',
        (tester) async {
      // Nothing to delete, so the tool must not be selectable.
      await pumpPage(tester);

      expect(tester.widget<InkWell>(toolButton('Delete')).onTap, isNull);
    });

    testWidgets('centred on the runner\'s position once it arrives',
        (tester) async {
      await pumpPage(tester);

      final map = tester.widget<FlutterMap>(find.byType(FlutterMap));
      expect(map.options.initialCenter.latitude, closeTo(milan.latitude, 1e-6));
    });
  });

  group('dropping pins', () {
    testWidgets('the first tap places a waypoint', (tester) async {
      routingSucceeds();
      await pumpPage(tester);

      await tapMap(tester, at(0, 0));

      expect(tester.widget<IconButton>(undoButton()).onPressed,
          isNotNull, reason: 'a placed pin is an undoable step');
    });

    testWidgets('a second tap routes between them', (tester) async {
      routingSucceeds();
      await pumpPage(tester);

      await tapMap(tester, at(0, 0));
      await tapMap(tester, at(0, 1));

      verify(callable.call(any)).called(1);
    });

    testWidgets('the first pin needs no routing call at all', (tester) async {
      // There is nothing to route *from* yet — spending an ORS request on it
      // would burn the shared quota for no geometry.
      routingSucceeds();
      await pumpPage(tester);

      await tapMap(tester, at(0, 0));

      verifyNever(callable.call(any));
    });

    testWidgets('placing a pin enables delete mode', (tester) async {
      routingSucceeds();
      await pumpPage(tester);

      await tapMap(tester, at(0, 0));

      expect(tester.widget<InkWell>(toolButton('Delete')).onTap, isNotNull);
    });

    testWidgets('a routing failure still places the pin', (tester) async {
      // `fetchRoute` falls back to a straight line rather than returning
      // nothing, so a network blip costs accuracy, not the user's work.
      routingFails();
      await pumpPage(tester);

      await tapMap(tester, at(0, 0));
      await tapMap(tester, at(0, 1));

      expect(tester.widget<InkWell>(toolButton('Delete')).onTap, isNotNull);
    });
  });

  group('undo and redo', () {
    testWidgets('undo steps back to the empty route', (tester) async {
      routingSucceeds();
      await pumpPage(tester);
      await tapMap(tester, at(0, 0));

      await tester.tap(undoButton());
      await tester.pump();

      expect(tester.widget<IconButton>(undoButton()).onPressed,
          isNull);
      expect(tester.widget<IconButton>(redoButton()).onPressed,
          isNotNull);
    });

    testWidgets('redo puts the pin back', (tester) async {
      routingSucceeds();
      await pumpPage(tester);
      await tapMap(tester, at(0, 0));
      await tester.tap(undoButton());
      await tester.pump();

      await tester.tap(redoButton());
      await tester.pump();

      expect(tester.widget<IconButton>(redoButton()).onPressed,
          isNull);
      expect(tester.widget<InkWell>(toolButton('Delete')).onTap, isNotNull);
    });

    testWidgets('a new pin after an undo discards the redo branch',
        (tester) async {
      // Standard undo-stack behaviour: the future is dropped once history
      // diverges, or redo would splice in a route the user backed out of.
      routingSucceeds();
      await pumpPage(tester);
      await tapMap(tester, at(0, 0));
      await tapMap(tester, at(0, 1));
      await tester.tap(undoButton());
      await tester.pump();
      expect(tester.widget<IconButton>(redoButton()).onPressed,
          isNotNull);

      await tapMap(tester, at(1, 1));

      expect(tester.widget<IconButton>(redoButton()).onPressed,
          isNull);
    });
  });

  group('the tools gate each other', () {
    testWidgets('Draw is offered on an empty route', (tester) async {
      await pumpPage(tester);

      expect(tester.widget<InkWell>(toolButton('Draw')).onTap, isNotNull);
    });

    testWidgets('Draw is refused once a pin exists', (tester) async {
      // Freehand is one-shot per route: it lays down the first shape or
      // nothing. Appending a second stroke onto an existing route is not
      // supported, so the tool is disabled rather than misbehaving.
      routingSucceeds();
      await pumpPage(tester);

      await tapMap(tester, at(0, 0));

      expect(tester.widget<InkWell>(toolButton('Draw')).onTap, isNull);
    });

    testWidgets('selecting Delete leaves Pin mode', (tester) async {
      routingSucceeds();
      await pumpPage(tester);
      await tapMap(tester, at(0, 0));

      await tester.tap(toolButton('Delete'));
      await tester.pump();

      // A tap in delete mode means "remove this pin", never "add one".
      await tapMap(tester, at(2, 2));

      verifyNever(callable.call(any));
    });

    testWidgets('a tap while the Draw tool is selected places nothing',
        (tester) async {
      // Drawing is a press-and-drag gesture; a plain tap does nothing.
      routingSucceeds();
      await pumpPage(tester);

      await tester.tap(toolButton('Draw'));
      await tester.pump();
      await tapMap(tester, at(0, 0));

      expect(tester.widget<InkWell>(toolButton('Delete')).onTap, isNull,
          reason: 'no waypoint should have been placed');
    });
  });

  group('the route summary', () {
    testWidgets('shows distance, time and calories', (tester) async {
      routingSucceeds();
      await pumpPage(tester);

      await tapMap(tester, at(0, 0));
      await tapMap(tester, at(0, 1));

      expect(find.text('Distance'), findsOneWidget);
      expect(find.text('Est. time'), findsOneWidget);
      expect(find.text('Calories'), findsOneWidget);
    });
  });

  group('claimed areas', () {
    testWidgets('are loaded once, not listened to', (tester) async {
      // Route creation shows other players' territory so a route can be
      // planned around it, but takes one snapshot rather than a live feed —
      // the read-cost rule.
      await pumpPage(tester);

      verify(areas.areasStream()).called(1);
    });

    testWidgets('a failure to load them does not break the screen',
        (tester) async {
      when(areas.areasStream())
          .thenAnswer((_) => Stream.error(Exception('denied')));

      await pumpPage(tester);

      expect(tester.takeException(), isNull);
      expect(find.byType(FlutterMap), findsOneWidget);
    });
  });

  // ── Deleting and closing ──────────────────────────────────────────────────

  /// The waypoint pins currently on the map. Pin markers are the only 36×36
  /// ones this screen builds, which is what separates them from the other
  /// marker layer.
  int pinCount(WidgetTester tester) => tester
      .widgetList<MarkerLayer>(find.byType(MarkerLayer))
      .expand((layer) => layer.markers)
      .where((m) => m.width == 36 && m.height == 36)
      .length;

  /// The legs the route is actually drawn from. Pin count alone cannot see a
  /// leg left behind by a bad delete: the waypoint disappears while a stale
  /// segment keeps spanning where it used to be.
  int segmentCount(WidgetTester tester) => tester
      .widgetList<PolylineLayer>(find.byType(PolylineLayer))
      .first
      .polylines
      .length;

  /// Taps the pin at [index] — a real widget tap, unlike `tapMap`, because
  /// deleting is a gesture on the marker rather than on the map surface.
  ///
  /// Addressed by what the pin draws: a close icon in delete mode, its
  /// 1-based number otherwise. Indexing `find.byType(GestureDetector)`
  /// instead reaches whichever detector happens to come first in the tree —
  /// which is not a pin, and let a tap fall through to the map and place a
  /// *new* pin while the test claimed to be tapping an existing one.
  Future<void> tapPin(WidgetTester tester, int index,
      {bool deleteMode = true}) async {
    final finder = deleteMode
        ? find.byIcon(Icons.close).at(index)
        : find.text('${index + 1}');
    await tester.tap(finder, warnIfMissed: false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  /// Every origin→destination pair the screen asked ORS to route, in order.
  List<(LatLng, LatLng)> routedLegs() =>
      verify(callable.call(captureAny)).captured.map((a) {
        final args = a as Map<String, dynamic>;
        final o = args['origin'] as Map;
        final d = args['destination'] as Map;
        return (
          LatLng((o['lat'] as num).toDouble(), (o['lng'] as num).toDouble()),
          LatLng((d['lat'] as num).toDouble(), (d['lng'] as num).toDouble()),
        );
      }).toList();

  Future<void> enterDeleteMode(WidgetTester tester) async {
    await tester.tap(toolButton('Delete'));
    await tester.pump();
  }

  /// Places [n] pins in a straight line east, one "unit" apart.
  Future<void> placePins(WidgetTester tester, int n) async {
    for (var i = 0; i < n; i++) {
      await tapMap(tester, at(0, i.toDouble()));
    }
  }

  group('deleting a pin', () {
    testWidgets('removes it from the route', (tester) async {
      routingSucceeds();
      await pumpPage(tester);
      await placePins(tester, 3);
      expect(pinCount(tester), 3);

      await enterDeleteMode(tester);
      await tapPin(tester, 0);

      expect(pinCount(tester), 2);
    });

    testWidgets('a middle pin is bridged by a new leg between its neighbours',
        (tester) async {
      // Removing a pin from the middle of a route leaves a gap its two
      // adjacent legs used to span. The bridge is what keeps the route a
      // single connected path rather than two pieces with a hole.
      routingSucceeds();
      await pumpPage(tester);
      await placePins(tester, 3);
      clearInteractions(callable);

      await enterDeleteMode(tester);
      await tapPin(tester, 1);

      final legs = routedLegs();
      expect(legs, hasLength(1), reason: 'exactly one bridge, not a re-route');
      expect(legs.single.$1.longitude, closeTo(at(0, 0).longitude, 1e-9));
      expect(legs.single.$2.longitude, closeTo(at(0, 2).longitude, 1e-9),
          reason: 'the gap is bridged end to end, skipping the deleted pin');
      // Both of the deleted pin's own legs have to go, or the bridge is laid
      // alongside one of them and the route doubles back over ground the
      // user removed.
      expect(segmentCount(tester), 1);
    });

    testWidgets('an end pin needs no bridge at all', (tester) async {
      // Nothing spans a gap that is not there — spending an ORS request on
      // it would burn the shared quota for no geometry.
      routingSucceeds();
      await pumpPage(tester);
      await placePins(tester, 3);
      clearInteractions(callable);

      await enterDeleteMode(tester);
      await tapPin(tester, 2);

      verifyNever(callable.call(any));
      expect(pinCount(tester), 2);
    });

    testWidgets('a failed bridge still removes the pin', (tester) async {
      // The bridge falls back to a straight line rather than refusing the
      // delete, so a network blip costs accuracy, not the user's edit.
      routingSucceeds();
      await pumpPage(tester);
      await placePins(tester, 3);
      routingFails();

      await enterDeleteMode(tester);
      await tapPin(tester, 1);

      expect(pinCount(tester), 2);
      expect(tester.takeException(), isNull);
    });

    testWidgets('waits for a leg that is still being routed', (tester) async {
      // A delete reshuffles `_segments` while an in-flight `fetchRoute` is
      // holding an index into it. Letting the two interleave appends the
      // finished leg into a list it no longer matches.
      routingSucceeds();
      await pumpPage(tester);
      await placePins(tester, 3);
      routingHangs();
      await tapMap(tester, at(0, 3));
      expect(pinCount(tester), 4, reason: 'the fourth pin is placed at once');

      await enterDeleteMode(tester);
      await tapPin(tester, 0);

      expect(pinCount(tester), 4, reason: 'the delete is refused, not queued');
    });

    testWidgets('is not offered until the delete tool is selected',
        (tester) async {
      // A pin only becomes a delete target in delete mode; the rest of the
      // time it is numbered, and its own gesture is hold-to-drag. Asserting
      // that a *tap* in pin mode leaves the route alone would not say this:
      // the pin does not handle taps at all then, so one falls through to
      // the map and places a new pin — which is the intended behaviour, not
      // a failure to delete.
      routingSucceeds();
      await pumpPage(tester);
      await placePins(tester, 3);

      expect(find.byIcon(Icons.close), findsNothing);

      await enterDeleteMode(tester);

      expect(find.byIcon(Icons.close), findsNWidgets(3),
          reason: 'every pin becomes a delete target, and only now');
    });
  });

  group('closing the route into a loop', () {
    /// A square: four corners, then a tap back onto the first.
    Future<void> drawSquare(WidgetTester tester) async {
      await tapMap(tester, at(0, 0));
      await tapMap(tester, at(0, 4));
      await tapMap(tester, at(4, 4));
      await tapMap(tester, at(4, 0));
      await tapMap(tester, at(0, 0));
    }

    testWidgets('tapping back on the first pin closes it', (tester) async {
      routingSucceeds();
      await pumpPage(tester);

      await drawSquare(tester);

      expect(find.textContaining('Circuit closed'), findsOneWidget);
      // Closing re-adds the snapped-to waypoint on purpose, so that the two
      // lists stay in step — one leg between each consecutive pair. A route
      // that breaks this invariant renders legs against the wrong pins.
      expect(segmentCount(tester), pinCount(tester) - 1);
    });

    testWidgets('the closing leg is routed back to that waypoint',
        (tester) async {
      // Snapping closed is a real leg like any other, not a straight line
      // drawn between the two points — the route has to follow the road
      // back or the enclosed area is wrong.
      routingSucceeds();
      await pumpPage(tester);
      await tapMap(tester, at(0, 0));
      await tapMap(tester, at(0, 4));
      await tapMap(tester, at(4, 4));
      clearInteractions(callable);

      await tapMap(tester, at(0, 0));

      final legs = routedLegs();
      expect(legs, hasLength(1));
      expect(legs.single.$2.latitude, closeTo(at(0, 0).latitude, 1e-9),
          reason: 'the closing leg ends on the snapped waypoint');
    });

    testWidgets('the enclosed area is reported', (tester) async {
      routingSucceeds();
      await pumpPage(tester);

      await drawSquare(tester);

      expect(find.textContaining('Area'), findsWidgets);
    });

    testWidgets('a tap too far from any waypoint places a pin instead',
        (tester) async {
      // The snap radius is what separates "close the loop" from "carry on
      // drawing"; without it a route could never pass near its own start.
      routingSucceeds();
      await pumpPage(tester);
      await tapMap(tester, at(0, 0));
      await tapMap(tester, at(0, 4));
      await tapMap(tester, at(4, 4));

      await tapMap(tester, at(4, 0));

      expect(find.textContaining('Circuit closed'), findsNothing);
      expect(pinCount(tester), 4);
    });

    testWidgets('closing onto a middle pin leaves the tail behind',
        (tester) async {
      // Snapping back to a *middle* waypoint encloses only the part of the
      // route from there on. This is the case that isolates snapping: the
      // closing leg meets the route at a shared pin rather than crossing it,
      // so ordinary self-intersection has nothing to find and the loop
      // exists only because the tap snapped.
      routingSucceeds();
      await pumpPage(tester);
      await tapMap(tester, at(0, 0));
      await tapMap(tester, at(0, 4));
      await tapMap(tester, at(4, 4));
      await tapMap(tester, at(4, 0));

      // Near the pin, not exactly on it — 25 m off, inside the 40 m snap
      // radius. Tapping its exact coordinate would prove nothing: the
      // closing leg would land on the waypoint either way, so the loop
      // closes whether the tap snapped or simply dropped a pin there.
      await tapMap(tester, at(0, 4.25));

      expect(find.textContaining('Circuit closed'), findsOneWidget);
    });

    testWidgets('the route tip is not a snap target', (tester) async {
      // Only *earlier* waypoints can be closed onto. The tip is where the
      // route already is, so snapping to it would close a loop of nothing
      // instead of placing the pin the user asked for.
      routingSucceeds();
      await pumpPage(tester);
      await tapMap(tester, at(0, 0));
      await tapMap(tester, at(0, 4));

      await tapMap(tester, at(0, 4));

      expect(pinCount(tester), 3, reason: 'a third pin, not a closed loop');
      expect(find.textContaining('Circuit closed'), findsNothing);
    });

    testWidgets('deleting a pin afterwards clears the loop', (tester) async {
      // Removing a waypoint shifts every later index, so which loops survive
      // is no longer knowable — the screen conservatively drops all of them
      // rather than reporting an area the route no longer encloses.
      routingSucceeds();
      await pumpPage(tester);
      await drawSquare(tester);
      expect(find.textContaining('Circuit closed'), findsOneWidget);

      await enterDeleteMode(tester);
      await tapPin(tester, 1);

      expect(find.textContaining('Circuit closed'), findsNothing);
    });
  });

  // ── Drag to edit, and freehand drawing ────────────────────────────────────
  //
  // Both are real gestures rather than `MapOptions.onTap` callbacks, so they
  // are driven here as real gestures: a long press then a move for a pin, a
  // pan across the map for a stroke. The drop position is converted through
  // the map's own `RenderBox` and camera, so these also exercise the
  // coordinate handling that a synthesised callback would skip.

  /// Long-presses the pin at [index] and drags it by [by].
  Future<void> dragPin(WidgetTester tester, int index, Offset by) async {
    final gesture = await tester.startGesture(tester.getCenter(find.text('${index + 1}')));
    // Past the long-press threshold: below it this is a tap, which in pin
    // mode falls through to the map and places a pin instead.
    await tester.pump(const Duration(milliseconds: 700));
    await gesture.moveBy(by);
    await tester.pump();
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  group('dragging a pin to move it', () {
    testWidgets('re-routes both legs touching a middle pin', (tester) async {
      // The pin keeps its index, so unlike a delete nothing is bridged — the
      // two legs either side of it are rebuilt in place.
      routingSucceeds();
      await pumpPage(tester);
      await placePins(tester, 3);
      clearInteractions(callable);

      await dragPin(tester, 1, const Offset(0, -60));

      expect(routedLegs(), hasLength(2));
      expect(pinCount(tester), 3, reason: 'moved, not added or removed');
      expect(segmentCount(tester), 2);
    });

    testWidgets('re-routes only the one leg touching an end pin',
        (tester) async {
      // An end pin has a single neighbour. Rebuilding a second leg would
      // mean routing to a waypoint that is not adjacent to it.
      routingSucceeds();
      await pumpPage(tester);
      await placePins(tester, 3);
      clearInteractions(callable);

      await dragPin(tester, 0, const Offset(0, -60));

      expect(routedLegs(), hasLength(1));
    });

    testWidgets('does not move a pin in delete mode', (tester) async {
      // The same gesture target carries a delete tap there; letting it also
      // drag would make which one you get depend on how long you held.
      routingSucceeds();
      await pumpPage(tester);
      await placePins(tester, 3);
      await enterDeleteMode(tester);
      clearInteractions(callable);

      final gesture =
          await tester.startGesture(tester.getCenter(find.byIcon(Icons.close).at(1)));
      await tester.pump(const Duration(milliseconds: 700));
      await gesture.moveBy(const Offset(0, -60));
      await tester.pump();
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 400));

      verifyNever(callable.call(any));
    });

    testWidgets('a failed re-route still leaves a connected route',
        (tester) async {
      // The straight-line fallback keeps the route whole rather than
      // abandoning the move half-applied.
      routingSucceeds();
      await pumpPage(tester);
      await placePins(tester, 3);
      routingFails();

      await dragPin(tester, 1, const Offset(0, -60));

      expect(segmentCount(tester), pinCount(tester) - 1);
      expect(tester.takeException(), isNull);
    });
  });

  group('drawing a route freehand', () {
    // A *successful* conversion is not driven from here. The stroke itself is
    // captured fine — a pan over the overlay populates the drawn polyline —
    // but turning it into a route goes through `DrawnRouteConverter`, which
    // calls a map-matching backend rather than the ORS directions endpoint
    // these tests stub. That converter is 94% covered by
    // `drawn_route_converter_test.dart`, so what is missing here is the
    // page's wiring around its three results, not the conversion itself.

    testWidgets('a stroke too short to be a shape is ignored', (tester) async {
      // Jitter, or a tap that slid a few pixels. Turning that into a route
      // would drop pins the user never meant to place — and unlike a failed
      // conversion it is not worth an error, because nothing went wrong.
      routingSucceeds();
      await pumpPage(tester);
      await tester.tap(toolButton('Draw'));
      await tester.pump();

      final gesture = await tester.startGesture(const Offset(250, 500));
      await tester.pump();
      await gesture.moveBy(const Offset(3, 2));
      await tester.pump(const Duration(milliseconds: 16));
      await gesture.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));

      expect(pinCount(tester), 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('is refused once the route already has pins', (tester) async {
      // Drawing is one-shot per route: a second stroke has no defined way to
      // join what is already there.
      routingSucceeds();
      await pumpPage(tester);
      await tapMap(tester, at(0, 0));

      expect(tester.widget<InkWell>(toolButton('Draw')).onTap, isNull);
    });
  });
}
