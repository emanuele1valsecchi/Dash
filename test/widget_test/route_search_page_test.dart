import 'dart:convert';
import 'dart:math' as math;

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

import 'package:dash/screens/route_search_page.dart';
import 'package:dash/services/place_search_service.dart';
import 'package:dash/services/routing_service.dart';
import 'package:dash/services/user_appearance_service.dart';

import '../helpers/fake_location_platform.dart';
import '../helpers/pump_app.dart';
import '../mocks.mocks.dart' hide MockUser;

/// Route discovery by parameters — a two-step wizard over a map.
///
/// Two things are tested here. The wizard: which step you can reach, what
/// each step requires before it will let you search, and the fact that a
/// closed circuit and a plain A→B route have different requirements
/// entirely. And the *generation* underneath it — which loop candidates are
/// offered, which are thrown away, and what the user is told when none
/// survive.
///
/// The generation is the part that matters. `RoutingService` is only the
/// transport, and `routing_service_test.dart` covers it as such; the strategy
/// on top — fire several round trips, reject the ones enclosing no ground,
/// rescale the near misses, tell a rate limit apart from a genuine miss —
/// lives in this file's page and is where every reported field bug on this
/// screen has been.
///
/// Nothing in this file lets a search actually reach the network — every
/// routing call is stubbed. A test that hit ORS would be slow, flaky and a
/// drain on the shared quota.
void main() {
  late FakeLocationPlatform location;
  late MockFirebaseAuth auth;
  late MockFirebaseFunctions functions;
  late MockHttpsCallable callable;
  late MockClaimedAreaRepository areas;
  late MockRouteRepository routes;

  const milan = LatLng(45.4642, 9.1900);

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    setupFirebaseCoreMocks();
    await Firebase.initializeApp();
  });

  setUp(() {
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
    // Every routing call fails by default: no test here depends on a route
    // being found, and a stub that succeeds would silently invite one to.
    when(callable.call(any))
        .thenAnswer((_) async => throw Exception('not stubbed'));
    RoutingService.functionsOverride = functions;
    addTearDown(() => RoutingService.functionsOverride = null);

    PlaceSearchService.clientOverride =
        MockClient((_) async => http.Response('[]', 200));
    addTearDown(() => PlaceSearchService.clientOverride = null);
    addTearDown(UserAppearanceService.instance.clearForTest);
  });

  Future<void> pumpPage(WidgetTester tester) async {
    await mockNetworkImagesFor(() async {
      await pumpDashWidget(
        tester,
        RouteSearchPage(
          auth: auth,
          areaRepository: areas,
          routeRepository: routes,
        ),
        wrapInScaffold: false,
        // Tall and wide: the form is a bottom sheet over a full-screen map,
        // and the test font is ~1 em per character. See TEST_NOTES 1.2.
        surfaceSize: const Size(1100, 1900),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    });
  }

  Finder circuitSwitch() => find.byType(Switch);
  Finder nextButton() =>
      find.widgetWithText(ElevatedButton, 'Next: parameters');
  Finder backButton() => find.widgetWithText(TextButton, 'Back');

  Future<void> setCircuit(WidgetTester tester, {required bool on}) async {
    final s = tester.widget<Switch>(circuitSwitch());
    if (s.value != on) {
      await tester.tap(circuitSwitch());
      await tester.pump();
    }
  }

  /// Advances to the parameters step. A closed circuit can always advance;
  /// a direct route needs a destination first.
  Future<void> goToParameters(WidgetTester tester) async {
    await tester.tap(nextButton());
    await tester.pump();
  }

  group('the shape step', () {
    testWidgets('is where the wizard starts', (tester) async {
      await pumpPage(tester);

      expect(find.textContaining('Step 1 of 2'), findsOneWidget);
      expect(nextButton(), findsOneWidget);
      expect(backButton(), findsNothing);
    });

    testWidgets('offers the closed-circuit toggle, off by default',
        (tester) async {
      await pumpPage(tester);

      expect(find.text('Search for a closed circuit'), findsOneWidget);
      expect(tester.widget<Switch>(circuitSwitch()).value, isFalse);
    });

    testWidgets('a direct route cannot advance without a destination',
        (tester) async {
      // An A→B search with no B is meaningless, and the check is synchronous
      // here because address resolution is not.
      await pumpPage(tester);

      expect(tester.widget<ElevatedButton>(nextButton()).onPressed, isNull);
    });

    testWidgets('a closed circuit can advance immediately', (tester) async {
      // It loops back to the start, so it has no destination field to fill.
      await pumpPage(tester);

      await setCircuit(tester, on: true);

      expect(tester.widget<ElevatedButton>(nextButton()).onPressed,
          isNotNull);
    });

    testWidgets('turning the circuit on removes the destination field',
        (tester) async {
      await pumpPage(tester);
      expect(find.text('Destination'), findsOneWidget);

      await setCircuit(tester, on: true);

      expect(find.text('Destination'), findsNothing);
    });

    testWidgets('turning it back off brings the destination back',
        (tester) async {
      await pumpPage(tester);
      await setCircuit(tester, on: true);

      await setCircuit(tester, on: false);

      expect(find.text('Destination'), findsOneWidget);
    });

    testWidgets('intermediate stops are offered in either mode',
        (tester) async {
      await pumpPage(tester);
      expect(find.text('Intermediate stops'), findsOneWidget);

      await setCircuit(tester, on: true);

      expect(find.text('Intermediate stops'), findsOneWidget);
    });
  });

  group('the parameters step', () {
    testWidgets('is reached from the shape step', (tester) async {
      await pumpPage(tester);
      await setCircuit(tester, on: true);

      await goToParameters(tester);

      expect(backButton(), findsOneWidget);
      expect(nextButton(), findsNothing);
    });

    testWidgets('Back returns to the shape step', (tester) async {
      await pumpPage(tester);
      await setCircuit(tester, on: true);
      await goToParameters(tester);

      await tester.tap(backButton());
      await tester.pump();

      expect(find.textContaining('Step 1 of 2'), findsOneWidget);
      expect(nextButton(), findsOneWidget);
    });

    testWidgets('offers laps only for a closed circuit', (tester) async {
      // Laps are tied to the circuit toggle alone — a direct A→B route has
      // nothing to repeat.
      await pumpPage(tester);
      await setCircuit(tester, on: true);
      await goToParameters(tester);

      expect(find.textContaining('Laps'), findsWidgets);
    });

    testWidgets('offers no laps for a direct route', (tester) async {
      await pumpPage(tester);
      // The only text field on this step: the start uses a "Current
      // position" chip rather than a field, so the destination is index 0.
      await tester.enterText(find.byType(TextField).first, 'Duomo');
      await tester.pump();
      await goToParameters(tester);

      expect(find.textContaining('Laps'), findsNothing);
    });

    testWidgets('the shape choice survives the round trip', (tester) async {
      await pumpPage(tester);
      await setCircuit(tester, on: true);
      await goToParameters(tester);

      await tester.tap(backButton());
      await tester.pump();

      expect(tester.widget<Switch>(circuitSwitch()).value, isTrue);
    });
  });

  group('what a search requires', () {
    testWidgets('a closed circuit with no target and no stops is refused',
        (tester) async {
      // The auto-loop generator needs *something* to size the loop by:
      // either a distance/time/calorie target or stops that fix its shape.
      await pumpPage(tester);
      await setCircuit(tester, on: true);
      await goToParameters(tester);

      await tester.tap(find.byIcon(Icons.search_rounded).last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.textContaining('distance'), findsWidgets);
      verifyNever(callable.call(any));
    });
  });

  group('the map underneath', () {
    testWidgets('is there, so the shape can be seen before searching',
        (tester) async {
      await pumpPage(tester);

      expect(find.byType(FlutterMap), findsOneWidget);
    });

    testWidgets('loads claimed areas once, not as a live feed',
        (tester) async {
      await pumpPage(tester);

      verify(areas.areasStream()).called(1);
    });

    testWidgets('a failed territory load costs the overlay, not the screen',
        (tester) async {
      // A `snapshots()` stream reports failure by *erroring*, so without an
      // `onError` the failure escapes as an unhandled async error. Same
      // class as the unguarded `async void` badge loads fixed elsewhere.
      final failing = MockClaimedAreaRepository();
      when(failing.areasStream())
          .thenAnswer((_) => Stream.error(Exception('permission-denied')));

      await mockNetworkImagesFor(() async {
        await pumpDashWidget(
          tester,
          RouteSearchPage(
            auth: auth,
            areaRepository: failing,
            routeRepository: routes,
          ),
          wrapInScaffold: false,
          surfaceSize: const Size(1100, 1900),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
      });

      expect(tester.takeException(), isNull);
      expect(find.byType(FlutterMap), findsOneWidget);
    });
  });

  // ── Loop generation ───────────────────────────────────────────────────────
  //
  // A closed-circuit search with a target and no stops goes to the round-trip
  // generator: `_loopSeedCount` parallel ORS round trips, each a whole loop
  // grown out of the real road network, then filtered down to the ones that
  // are both near the requested length and actually enclose ground.
  //
  // The stub below answers as a *responsive* ORS would — it returns a loop of
  // whatever length was asked for — so a test only has to say how the road
  // network misbehaves (returns short, encloses nothing, is rate limited) and
  // then assert what the user ends up seeing.

  const mPerLat = 110540.0;
  final mPerLng = 111320.0 * math.cos(milan.latitude * math.pi / 180);
  LatLng at(double northM, double eastM) => LatLng(
        milan.latitude + northM / mPerLat,
        milan.longitude + eastM / mPerLng,
      );

  /// A closed square of the given perimeter. Encloses `(p/4)^2`, which is
  /// ~78% of what a circle of the same perimeter would — comfortably clear of
  /// the 2% floor `RouteCandidates.enclosesRealArea` applies.
  List<LatLng> squareLoop(double perimeterM) {
    final side = perimeterM / 4;
    return [at(0, 0), at(0, side), at(side, side), at(side, 0), at(0, 0)];
  }

  /// A path up one street and back down it: the full distance, no enclosed
  /// area. This is the shape a real closed-circuit search returned when its
  /// two offset waypoints road-snapped onto the same street, and it is the
  /// reason the area check exists.
  ///
  /// Deliberately more than three points, so it is rejected for enclosing
  /// nothing rather than for being too short to be a polygon at all.
  List<LatLng> outAndBack(double lengthM) {
    final half = lengthM / 2;
    return [
      for (var i = 0; i <= 4; i++) at(0, half * i / 4),
      for (var i = 3; i >= 0; i--) at(0, half * i / 4),
    ];
  }

  Map<String, dynamic> feature(List<LatLng> pts, double distance) => {
        'properties': {
          'summary': {'distance': distance},
        },
        // GeoJSON is [lon, lat].
        'geometry': {
          'coordinates': [
            for (final p in pts) [p.longitude, p.latitude],
          ],
        },
      };

  /// Answers every round-trip call with `shape(length)`, where `length` is
  /// what the generator asked for, optionally distorted by [measured] to
  /// model a road network that cannot deliver the requested size.
  void roundTripReturns(
    List<LatLng> Function(double lengthM) shape, {
    double Function(double requestedM)? measured,
  }) {
    when(callable.call(any)).thenAnswer((inv) async {
      final args = inv.positionalArguments.single as Map<String, dynamic>;
      final requested = (args['lengthMeters'] as num).toDouble();
      final actual = measured?.call(requested) ?? requested;
      final result = MockHttpsCallableResult<dynamic>();
      when(result.data).thenReturn({
        'status': 200,
        'body': {
          'features': [feature(shape(actual), actual)],
        },
      });
      return result;
    });
  }

  /// Answers every routing call with an HTTP status, which is how the shared
  /// ORS quota reports itself exhausted (429).
  void roundTripFailsWith(int status) {
    when(callable.call(any)).thenAnswer((_) async {
      final result = MockHttpsCallableResult<dynamic>();
      when(result.data).thenReturn({'status': status, 'body': <String, dynamic>{}});
      return result;
    });
  }

  /// Every argument map sent to the backend, in call order.
  List<Map<String, dynamic>> sentCalls() =>
      verify(callable.call(captureAny)).captured.cast<Map<String, dynamic>>();

  /// Every `lengthMeters` the generator asked ORS for, in call order.
  List<double> requestedLengths() => sentCalls()
      .where((a) => a['mode'] == 'round_trip')
      .map((a) => (a['lengthMeters'] as num).toDouble())
      .toList();

  /// Calls with no `mode`, i.e. plain point-to-point legs. The round-trip
  /// generator makes none of these; the legacy geometric guesser it falls
  /// back to makes nothing else, so this is how the two are told apart.
  int legacyLegCount() => sentCalls().where((a) => a['mode'] == null).length;

  /// Runs a closed-circuit search for `distanceKm`, from the current
  /// position, with no stops — the auto-loop path.
  Future<void> searchForLoop(WidgetTester tester, String distanceKm,
      {String? laps}) async {
    await setCircuit(tester, on: true);
    await goToParameters(tester);
    await tester.enterText(
        find.widgetWithText(TextField, 'Distance'), distanceKm);
    if (laps != null) {
      await tester.enterText(find.widgetWithText(TextField, 'e.g. 3'), laps);
    }
    await tester.pump();
    await tester.tap(find.widgetWithText(ElevatedButton, 'Show track'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  group('generating a loop', () {
    testWidgets('a real loop is offered', (tester) async {
      roundTripReturns(squareLoop);
      await pumpPage(tester);

      await searchForLoop(tester, '2');

      expect(find.text('Edit search'), findsOneWidget,
          reason: 'a found route puts the page into results mode');
    });

    testWidgets('an out-and-back is not offered as a loop', (tester) async {
      // The distance is exactly right and the geometry is real ORS output —
      // only the enclosed area gives it away. Offering this was a reported
      // bug: a "circuit" that ran up a road and back down it.
      roundTripReturns(outAndBack);
      await pumpPage(tester);

      await searchForLoop(tester, '2');

      expect(find.text('Edit search'), findsNothing,
          reason: 'nothing enclosing ground was found, so no results');
      expect(find.textContaining('Could not find a real loop'), findsOneWidget);
    });

    testWidgets('a rate limit is not reported as "no routes found"',
        (tester) async {
      // These are different failures and the user can act on only one of
      // them. Waiting fixes a 429; nothing fixes a genuine miss.
      roundTripFailsWith(429);
      await pumpPage(tester);

      await searchForLoop(tester, '2');

      expect(find.textContaining('busy right now'), findsOneWidget);
      expect(find.textContaining('No routes found'), findsNothing);

      // The message alone is too weak to pin this down: the legacy fallback
      // below reaches the same wording by its own route, so a test asserting
      // only the text passes even when the round trip has stopped
      // recognising a 429 at all. What a rate limit actually has to do is
      // *stop the search* rather than spend more of an exhausted quota on a
      // fallback that will be refused just the same.
      expect(legacyLegCount(), 0,
          reason: 'a 429 must not fall through to the legacy guesser');
    });

    testWidgets('a plain routing failure is reported as a miss, not a wait',
        (tester) async {
      // The mirror of the test above: a 500 is not something waiting fixes,
      // so it must not claim the service is merely busy.
      roundTripFailsWith(500);
      await pumpPage(tester);

      await searchForLoop(tester, '2');

      expect(find.textContaining('busy right now'), findsNothing);

      // An ordinary failure of *every* round trip is what a deployment
      // without the round_trip mode looks like, so the old geometric guesser
      // runs as a safety net. This is the one case where it should.
      expect(legacyLegCount(), greaterThan(0),
          reason: 'the legacy guesser is the fallback for a non-429 failure');
    });
  });

  group('correcting a loop that came back the wrong size', () {
    testWidgets('a short loop is re-requested, rescaled by how short it was',
        (tester) async {
      // ORS documents `length` as preferred, not guaranteed. A loop that
      // comes back at 70% of the requested size is re-asked for at
      // target/0.7, so the *measured* result lands on the target rather than
      // the request doing so.
      roundTripReturns(squareLoop, measured: (requested) => requested * 0.7);
      await pumpPage(tester);

      await searchForLoop(tester, '2');

      final lengths = requestedLengths();
      expect(lengths.take(4), everyElement(closeTo(2000, 1)),
          reason: 'the first pass asks for the target itself');
      expect(lengths.skip(4), isNotEmpty,
          reason: 'a near miss is worth one more call');
      expect(lengths.skip(4), everyElement(closeTo(2000 / 0.7, 1)));
    });

    testWidgets('a wildly wrong loop is not re-requested at all',
        (tester) async {
      // Below 0.55x the network does not support a loop of this size in this
      // direction, and another call would only spend more of a shared quota
      // to be told so again.
      roundTripReturns(squareLoop, measured: (requested) => requested * 0.2);
      await pumpPage(tester);

      await searchForLoop(tester, '2');

      expect(requestedLengths(), hasLength(4),
          reason: 'the four seeds, and no corrective call');
    });

    testWidgets('a loop already on target is not re-requested', (tester) async {
      roundTripReturns(squareLoop);
      await pumpPage(tester);

      await searchForLoop(tester, '2');

      expect(requestedLengths(), hasLength(4));
    });
  });

  group('laps', () {
    testWidgets('divide the target into a per-lap loop', (tester) async {
      // The user asks for 6 km over 3 laps, so each lap is 2 km — searching
      // for 6 km loops would be three times too big.
      roundTripReturns(squareLoop);
      await pumpPage(tester);

      await searchForLoop(tester, '6', laps: '3');

      expect(requestedLengths(), everyElement(closeTo(2000, 1)));
    });

    testWidgets('are named on the result', (tester) async {
      roundTripReturns(squareLoop);
      await pumpPage(tester);

      await searchForLoop(tester, '6', laps: '3');

      expect(find.textContaining('3 laps'), findsWidgets);
    });
  });

  // ── Direct A→B routes ─────────────────────────────────────────────────────
  //
  // A plain point-to-point search asks ORS for alternatives and, when none of
  // them lands near the requested distance, builds a detour instead. The
  // destination is set by picking it on the map: `_geocode` calls Nominatim
  // through a bare `http.get` with no seam, so typing an address cannot be
  // driven from a test, while map picking goes through `MapOptions.onTap`
  // exactly as a real tap would.

  /// A fake road network. Every leg is the straight line between its
  /// endpoints, [winding] times longer than the crow flies — the default
  /// matches `RouteCandidates.roadWindingFactor`, so the padding solver's own
  /// assumption about detour cost holds and it converges the way it would on
  /// a real city grid.
  void roadNetworkResponds({double winding = 1.25, int alternatives = 3}) {
    when(callable.call(any)).thenAnswer((inv) async {
      final args = inv.positionalArguments.single as Map<String, dynamic>;
      final o = args['origin'] as Map;
      final d = args['destination'] as Map;
      final from = LatLng((o['lat'] as num).toDouble(), (o['lng'] as num).toDouble());
      final to = LatLng((d['lat'] as num).toDouble(), (d['lng'] as num).toDouble());
      final base = const Distance()(from, to) * winding;
      final n = args['mode'] == 'alternatives' ? alternatives : 1;
      final result = MockHttpsCallableResult<dynamic>();
      when(result.data).thenReturn({
        'status': 200,
        'body': {
          'features': [
            // Spread the alternatives slightly, the way real variants differ.
            for (var i = 0; i < n; i++)
              feature([from, to], base * (1 + i * 0.05)),
          ],
        },
      });
      return result;
    });
  }

  /// Legs routed point to point rather than as a batch of alternatives —
  /// which, on a direct search, means the padding solver ran.
  int paddingLegCount() => sentCalls().where((a) => a['mode'] == null).length;

  /// Makes the address lookup offer one suggestion, at [point].
  ///
  /// Picking the destination *on the map* would be the other way in, but it
  /// collapses the bottom sheet — and the form's own buttons live inside
  /// that sheet, so they stop being built while it is down. Choosing a
  /// suggestion leaves the sheet where it is, and is the more common flow
  /// besides.
  void placesOffer(LatLng point, {String name = 'Test Destination'}) {
    PlaceSearchService.clientOverride = MockClient((request) async {
      if (request.url.host.contains('nominatim')) {
        return http.Response(
          jsonEncode([
            {
              'display_name': name,
              'lat': '${point.latitude}',
              'lon': '${point.longitude}',
              'importance': 0.9,
            }
          ]),
          200,
        );
      }
      // The Overpass fallback, which runs whenever Nominatim returns fewer
      // than three results — as it does here.
      return http.Response(jsonEncode({'elements': []}), 200);
    });
  }

  /// Sets the destination by choosing an address suggestion, then searches.
  /// The start is the runner's current position, which is the page's default.
  Future<void> searchDirect(WidgetTester tester, LatLng destination,
      {String? distanceKm}) async {
    placesOffer(destination);
    await tester.enterText(
        find.widgetWithText(TextField, 'Enter an address'), 'Test');
    // The field debounces before searching, and the service emits twice —
    // Nominatim first, then the merged Overpass result.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump(const Duration(milliseconds: 700));

    await tester.tap(find.text('Test Destination'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await goToParameters(tester);
    if (distanceKm != null) {
      await tester.enterText(
          find.widgetWithText(TextField, 'Distance'), distanceKm);
      await tester.pump();
    }
    await tester.tap(find.widgetWithText(ElevatedButton, 'Show track'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// A point [metres] east of Milan.
  LatLng east(double metres) => LatLng(
        milan.latitude,
        milan.longitude + metres / (111320.0 * math.cos(milan.latitude * math.pi / 180)),
      );

  group('a direct route', () {
    testWidgets('offers what the routing service suggests', (tester) async {
      roadNetworkResponds();
      await pumpPage(tester);

      await searchDirect(tester, east(1000));

      expect(find.text('Edit search'), findsOneWidget);
    });

    testWidgets('asks for alternatives rather than a single line',
        (tester) async {
      // One route is not a choice. The whole point of this screen is to offer
      // a few and let the runner pick.
      roadNetworkResponds();
      await pumpPage(tester);

      await searchDirect(tester, east(1000));

      expect(sentCalls().where((a) => a['mode'] == 'alternatives'), isNotEmpty);
    });

    testWidgets('with no target, nothing is filtered out', (tester) async {
      // Without a distance to hit, every alternative is a valid answer —
      // rejecting any of them would leave the runner with fewer options and
      // no reason why.
      roadNetworkResponds(alternatives: 3);
      await pumpPage(tester);

      await searchDirect(tester, east(1000));

      expect(paddingLegCount(), 0, reason: 'nothing to pad towards');
      expect(find.text('Edit search'), findsOneWidget);
    });
  });

  group('padding a direct route out to the target', () {
    testWidgets('a target longer than the trip is met with a detour',
        (tester) async {
      // Ranking alternatives by closeness cannot *lengthen* a trip, so a
      // 3 km target between two points 1.25 km apart was previously answered
      // with the natural 1.25 km route and no explanation. A detour is the
      // only thing that can actually reach the number the runner asked for.
      roadNetworkResponds();
      await pumpPage(tester);

      await searchDirect(tester, east(1000), distanceKm: '3');

      expect(paddingLegCount(), greaterThan(0),
          reason: 'a detour is routed leg by leg, not as alternatives');
      expect(find.text('Edit search'), findsOneWidget);
    });

    testWidgets('a target shorter than the trip is not padded', (tester) async {
      // A detour only ever adds distance. Trying to pad towards a target the
      // route already overshoots would spend requests to get further away.
      roadNetworkResponds();
      await pumpPage(tester);

      await searchDirect(tester, east(1000), distanceKm: '0.4');

      expect(paddingLegCount(), 0);
    });

    testWidgets('an unreachable target still shows the honest route',
        (tester) async {
      // The runner asked for something the road network cannot give them.
      // Showing nothing would read as "no route exists between these two
      // points", which is false and unhelpful.
      roadNetworkResponds();
      await pumpPage(tester);

      await searchDirect(tester, east(1000), distanceKm: '0.4');

      expect(find.text('Edit search'), findsOneWidget);
      expect(find.textContaining('No routes found'), findsNothing);
    });
  });
}
