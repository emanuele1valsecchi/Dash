import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:mockito/mockito.dart';
import 'package:network_image_mock/network_image_mock.dart';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';

import 'package:dash/screens/explore_page.dart';
import 'package:dash/services/claimed_area_repository.dart';
import 'package:dash/services/place_search_service.dart';
import 'package:dash/services/user_appearance_service.dart';
import 'package:dash/widgets/map/area_details_sheet.dart';
import 'package:dash/widgets/map/claimed_areas_layer.dart';

import '../helpers/fake_location_platform.dart';
import '../helpers/pump_app.dart';
import '../mocks.mocks.dart' hide MockUser;

/// The map everyone sees: every player's claimed territory drawn over a
/// tile map, with the two filter toggles that decide whose ground is shown.
///
/// The filtering is the part with teeth. `_visibleAreas` compares each area's
/// `userId` against the signed-in uid to decide whether a toggle applies to
/// it, so getting it wrong does not throw — it silently shows the wrong
/// player's territory, or hides the user's own. Every assertion below reads
/// the list `ClaimedAreasLayer` is actually handed, rather than trying to
/// find polygons on a rendered map.
///
/// Tiles are network images; `mockNetworkImagesFor` keeps the test binding's
/// 400-response HTTP client from failing the render.
void main() {
  late FakeFirebaseFirestore db;
  late FakeLocationPlatform location;
  late MockFirebaseAuth auth;

  const milan = LatLng(45.4642, 9.1900);

  setUpAll(() async {
    // `ClaimedAreasLayer` resolves `FirebaseAuth.instance` in its own build to
    // decide which polygons to paint as the viewer's own. It takes no seam, so
    // a mock app is what makes the layer constructible at all. It is not what
    // this file asserts on — `ExplorePage`'s own filtering goes through the
    // injected `auth` above, and every expectation reads the list handed to
    // the layer rather than anything the layer draws.
    TestWidgetsFlutterBinding.ensureInitialized();
    setupFirebaseCoreMocks();
    await Firebase.initializeApp();
  });

  setUp(() {
    db = FakeFirebaseFirestore();
    location = installFakeLocationPlatform();
    location.grant(milan);
    auth = MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: 'me'));

    // The layer looks up player colours through this singleton; pointed at
    // the same fake database so it never reaches a real one.
    UserAppearanceService.instance.firestoreOverride = db;
    addTearDown(UserAppearanceService.instance.clearForTest);

    // The search bar hits Nominatim through this client on every keystroke.
    // Stubbed empty so no test accidentally depends on the network.
    PlaceSearchService.clientOverride =
        MockClient((_) async => http.Response('[]', 200));
    addTearDown(() => PlaceSearchService.clientOverride = null);
  });

  /// Seeds one claimed area. [sessionId] is what a "someone stole your area"
  /// notification carries, and is how the deep link finds it again.
  Future<void> seedArea({
    required String id,
    required String userId,
    String? sessionId,
    LatLng at = milan,
  }) async {
    await db.collection('claimedAreas').doc(id).set({
      'userId': userId,
      'polygon': [
        {
          'outer': [
            GeoPoint(at.latitude, at.longitude),
            GeoPoint(at.latitude + 0.001, at.longitude),
            GeoPoint(at.latitude + 0.001, at.longitude + 0.001),
            GeoPoint(at.latitude, at.longitude + 0.001),
          ],
          'holes': <Map<String, dynamic>>[],
        }
      ],
      'contributions': [
        {
          'sessionId': sessionId ?? 'session-$id',
          'durationMs': 600000,
          'avgPaceMinPerKm': 5.0,
          'conquestDate': Timestamp.fromDate(DateTime.utc(2026, 1, 1)),
        }
      ],
      'createdAt': Timestamp.fromDate(DateTime.utc(2026, 1, 1)),
      'updatedAt': Timestamp.fromDate(DateTime.utc(2026, 1, 1)),
    });
  }

  Future<void> pumpPage(WidgetTester tester, {String? targetSessionId}) async {
    await mockNetworkImagesFor(() async {
      await pumpDashWidget(
        tester,
        ExplorePage(
          targetSessionId: targetSessionId,
          auth: auth,
          areaRepository: ClaimedAreaRepository.withDependencies(db: db),
        ),
        wrapInScaffold: false,
        surfaceSize: kPhoneSurface,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
    });
  }

  /// The areas the map is actually drawing.
  List<ClaimedArea> drawnAreas(WidgetTester tester) =>
      tester.widget<ClaimedAreasLayer>(find.byType(ClaimedAreasLayer)).areas;

  List<String> drawnIds(WidgetTester tester) =>
      drawnAreas(tester).map((a) => a.id).toList()..sort();

  group('getting a location', () {
    testWidgets('shows a loading overlay until the first fix lands',
        (tester) async {
      await mockNetworkImagesFor(() async {
        await pumpDashWidget(
          tester,
          ExplorePage(
            auth: auth,
            areaRepository: ClaimedAreaRepository.withDependencies(db: db),
          ),
          wrapInScaffold: false,
          surfaceSize: kPhoneSurface,
        );
        // Deliberately no settle: the point is the frame *before* the
        // location future resolves.
        expect(find.byKey(const ValueKey('loading')), findsOneWidget);

        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
      });

      expect(find.byKey(const ValueKey('loading')), findsNothing);
    });

    testWidgets('a refusal leaves the map usable behind a banner',
        (tester) async {
      // Losing location must not cost the user the map itself — the whole
      // point of Explore is looking at territory, most of which is nowhere
      // near where you are standing.
      location.deny();

      await pumpPage(tester);

      expect(find.byKey(const ValueKey('permissionBanner')), findsOneWidget);
      expect(find.byType(ClaimedAreasLayer), findsOneWidget);
    });

    testWidgets('no banner once permission is granted', (tester) async {
      await pumpPage(tester);

      expect(find.byKey(const ValueKey('permissionBanner')), findsNothing);
    });
  });

  group('whose territory is drawn', () {
    testWidgets('everyones areas are shown by default', (tester) async {
      await seedArea(id: 'mine', userId: 'me');
      await seedArea(id: 'theirs', userId: 'rival');

      await pumpPage(tester);

      expect(drawnIds(tester), ['mine', 'theirs']);
    });

    testWidgets('hiding other players keeps only your own', (tester) async {
      await seedArea(id: 'mine', userId: 'me');
      await seedArea(id: 'theirs', userId: 'rival');
      await pumpPage(tester);

      await tester.tap(find.byIcon(Icons.grid_on_outlined));
      await tester.pump();

      expect(drawnIds(tester), ['mine']);
    });

    testWidgets('hiding your own keeps only other players', (tester) async {
      await seedArea(id: 'mine', userId: 'me');
      await seedArea(id: 'theirs', userId: 'rival');
      await pumpPage(tester);

      await tester.tap(find.byIcon(Icons.cable_outlined));
      await tester.pump();

      expect(drawnIds(tester), ['theirs']);
    });

    testWidgets('hiding both empties the map without breaking it',
        (tester) async {
      await seedArea(id: 'mine', userId: 'me');
      await seedArea(id: 'theirs', userId: 'rival');
      await pumpPage(tester);

      await tester.tap(find.byIcon(Icons.grid_on_outlined));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.cable_outlined));
      await tester.pump();

      expect(drawnAreas(tester), isEmpty);
      expect(find.byType(ClaimedAreasLayer), findsOneWidget);
    });

    testWidgets('a logically deleted area is never drawn', (tester) async {
      // Absorbed areas are flagged rather than removed, so the repository has
      // to filter them — otherwise ground someone already lost keeps showing
      // as theirs.
      await seedArea(id: 'mine', userId: 'me');
      await db.collection('claimedAreas').doc('gone').set({
        'userId': 'rival',
        'deleted': true,
        'polygon': <Map<String, dynamic>>[],
        'contributions': <Map<String, dynamic>>[],
      });

      await pumpPage(tester);

      expect(drawnIds(tester), ['mine']);
    });

    testWidgets('a signed-out viewer sees every area as someone elses',
        (tester) async {
      // No uid means nothing matches `isMine`, so the "my areas" toggle
      // governs nothing and everything is filtered as another player's.
      auth = MockFirebaseAuth();
      await seedArea(id: 'a', userId: 'me');
      await seedArea(id: 'b', userId: 'rival');
      await pumpPage(tester);

      expect(drawnIds(tester), ['a', 'b']);

      await tester.tap(find.byIcon(Icons.grid_on_outlined));
      await tester.pump();

      expect(drawnAreas(tester), isEmpty);
    });
  });

  group('arriving from a stolen-area notification', () {
    testWidgets('opens the stolen areas details sheet', (tester) async {
      // The point of the deep link: land on the map already showing *which*
      // area was taken, rather than dropping the user on their own location
      // and leaving them to find it.
      await seedArea(id: 'stolen', userId: 'rival', sessionId: 'session-42');

      await mockNetworkImagesFor(() async {
        await pumpPage(tester, targetSessionId: 'session-42');
        // The sheet is opened behind a deliberate 500 ms delay, so the camera
        // has finished moving before it slides up.
        await tester.pump(const Duration(milliseconds: 600));
        await tester.pump(const Duration(milliseconds: 400));
      });

      expect(find.byType(AreaDetailsSheet), findsOneWidget);
      expect(drawnIds(tester), ['stolen']);
    });

    testWidgets('a session that matches nothing is survivable', (tester) async {
      // The area may have been reconquered before the notification was
      // opened. That is ordinary, not an error.
      await seedArea(id: 'mine', userId: 'me');

      await pumpPage(tester, targetSessionId: 'no-such-session');

      expect(tester.takeException(), isNull);
      expect(drawnIds(tester), ['mine']);
    });
  });

  group('a failed territory load', () {
    testWidgets('costs the overlay, not the screen', (tester) async {
      // A `snapshots()` stream reports failure by *erroring*, not by
      // completing, so without an `onError` the failure escapes as an
      // unhandled async error. Same class as the unguarded `async void`
      // badge loads fixed elsewhere: the map must survive not knowing who
      // owns what.
      final failing = MockClaimedAreaRepository();
      when(failing.areasStream())
          .thenAnswer((_) => Stream.error(Exception('permission-denied')));

      await mockNetworkImagesFor(() async {
        await pumpDashWidget(
          tester,
          ExplorePage(auth: auth, areaRepository: failing),
          wrapInScaffold: false,
          surfaceSize: kPhoneSurface,
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
      });

      expect(tester.takeException(), isNull);
      expect(find.byType(ClaimedAreasLayer), findsOneWidget);
    });
  });

}
