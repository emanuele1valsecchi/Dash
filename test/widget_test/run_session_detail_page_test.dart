import 'package:dash/config/app_theme.dart';
import 'package:dash/screens/run_session_detail_page.dart';
import 'package:dash/services/run_session_repository.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mockito/mockito.dart';

// `MockUser` is declared by both firebase_auth_mocks and our generated mocks.
import '../mocks.mocks.dart' hide MockUser;

/// One completed run, reached from the Explore map, a profile, or the
/// calendar. The page is the same wherever it is opened from.
///
/// **The load-bearing rule here is that body metrics are owner-only.** Energy
/// and heart rate describe the *runner*, not the route — unlike everything
/// else on the page — so a visitor must see only the shape of the run. That
/// is enforced by `firestore.rules` for heart rate; this screen is what makes
/// it true for what is drawn.
void main() {
  late MockRunSessionRepository sessions;
  late MockFavoriteRouteRepository favorites;
  late MockProfileService profiles;

  const runner = 'runner-1';
  const visitor = 'someone-else';

  RunSession session({
    String id = 's1',
    String name = 'Morning run',
    List<LatLng>? path,
  }) =>
      RunSession(
        id: id,
        name: name,
        distanceMeters: 4200,
        duration: const Duration(minutes: 24),
        avgPaceMinPerKm: 5.7,
        maxPaceMinPerKm: 4.2,
        elevationDifferenceMeters: 32,
        loopsCompleted: 1,
        path: path ?? const [LatLng(45.65, 9.20), LatLng(45.66, 9.21)],
        createdAt: DateTime(2026, 3, 14),
        totalAreaM2: 120000,
      );

  setUp(() {
    sessions = MockRunSessionRepository();
    favorites = MockFavoriteRouteRepository();
    profiles = MockProfileService();

    when(sessions.fetchSessionById(any)).thenAnswer((_) async => session());
    when(sessions.fetchPrivateMetrics(any)).thenAnswer((_) async => null);
    when(profiles.fetchUsername(any)).thenAnswer((_) async => 'speedy');
    when(favorites.isFavorited(any)).thenAnswer((_) async => false);
    when(favorites.favoriteSession(any, routeName: anyNamed('routeName')))
        .thenAnswer((_) async {});
    when(favorites.unfavoriteRoute(any)).thenAnswer((_) async {});
  });

  Future<void> pumpPage(
    WidgetTester tester, {
    String viewerUid = runner,
    String ownerUid = runner,
  }) async {
    tester.view.physicalSize = const Size(500, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: RunSessionDetailPage(
          sessionId: 's1',
          userId: ownerUid,
          auth: MockFirebaseAuth(
            signedIn: true,
            mockUser: MockUser(uid: viewerUid),
          ),
          sessionRepository: sessions,
          favoriteRepository: favorites,
          profileService: profiles,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('loading', () {
    testWidgets('fetches the whole session by id', (tester) async {
      // Not just the loop that claimed an area: a run can close a small loop
      // partway through a much longer route, and showing only that loop would
      // misrepresent the session.
      await pumpPage(tester);

      verify(sessions.fetchSessionById('s1')).called(1);
    });

    testWidgets('shows the run name as the title', (tester) async {
      await pumpPage(tester);

      expect(find.text('Morning run'), findsWidgets);
    });

    testWidgets('resolves the runner name', (tester) async {
      await pumpPage(tester, viewerUid: visitor, ownerUid: runner);

      verify(profiles.fetchUsername(runner)).called(1);
      expect(find.textContaining('speedy'), findsWidgets);
    });

    testWidgets('renders the measurements', (tester) async {
      await pumpPage(tester);

      expect(find.text('Distance'), findsOneWidget);
      expect(find.text('Time'), findsOneWidget);
      expect(find.text('Elevation'), findsOneWidget);
      expect(find.text('Area'), findsOneWidget);
    });

    testWidgets('a session that cannot be loaded does not crash the page',
        (tester) async {
      when(sessions.fetchSessionById(any)).thenAnswer((_) async => null);

      await pumpPage(tester);

      expect(tester.takeException(), isNull);
    });
  });

  group('body metrics are owner-only', () {
    // The distinction the whole page turns on: everything else describes where
    // the run went; these describe the person.
    testWidgets('the runner sees their own energy', (tester) async {
      await pumpPage(tester, viewerUid: runner, ownerUid: runner);

      expect(find.text('Energy'), findsOneWidget);
    });

    testWidgets('a visitor does not', (tester) async {
      await pumpPage(tester, viewerUid: visitor, ownerUid: runner);

      expect(find.text('Energy'), findsNothing);
    });

    testWidgets('the runner sees heart rate when a watch reported it',
        (tester) async {
      when(sessions.fetchPrivateMetrics(any)).thenAnswer(
        (_) async => const RunPrivateMetrics(
          avgHeartRateBpm: 152,
          maxHeartRateBpm: 178,
        ),
      );

      await pumpPage(tester, viewerUid: runner, ownerUid: runner);

      expect(find.text('Avg HR'), findsOneWidget);
      expect(find.text('Max HR'), findsOneWidget);
    });

    testWidgets('no heart rate is shown for a phone-only run', (tester) async {
      // Most runs. Absence must read as "no watch", not as a zero reading.
      await pumpPage(tester, viewerUid: runner, ownerUid: runner);

      expect(find.text('Avg HR'), findsNothing);
    });

    testWidgets('a visitor never even asks for the private metrics',
        (tester) async {
      // The rule would deny it, so the request would be a wasted round trip
      // that always fails.
      await pumpPage(tester, viewerUid: visitor, ownerUid: runner);

      verifyNever(sessions.fetchPrivateMetrics(any));
    });

    testWidgets('a visitor still sees the shape of the run', (tester) async {
      // Hiding the body metrics must not hide the run itself.
      await pumpPage(tester, viewerUid: visitor, ownerUid: runner);

      expect(find.text('Distance'), findsOneWidget);
      expect(find.text('Area'), findsOneWidget);
    });
  });

  group('turning a run into a route', () {
    // Relabelled from "Add to favourites": favouriting a run *is* copying its
    // path into a route the viewer can go and run, and the old wording
    // described the bookkeeping rather than the outcome.
    testWidgets('offers the action when not yet saved', (tester) async {
      await pumpPage(tester);

      expect(find.text('Turn into a Route'), findsOneWidget);
      expect(find.text('Remove from Routes'), findsNothing);
    });

    testWidgets('offers the reverse once it is saved', (tester) async {
      when(favorites.isFavorited(any)).thenAnswer((_) async => true);

      await pumpPage(tester);

      expect(find.text('Remove from Routes'), findsOneWidget);
    });

    testWidgets('checks the saved state by direct document read',
        (tester) async {
      // The link's ID is fully determined by user + session, so this needs no
      // query, no index, and cannot go stale behind a cache.
      await pumpPage(tester);

      verify(favorites.isFavorited('s1')).called(1);
    });

    testWidgets('saving sends only the id and a name', (tester) async {
      // Never geometry: the Cloud Function reads the session itself, because
      // no rule can check that a client-supplied polyline is the run it
      // claims to be.
      await pumpPage(tester);

      await tester.tap(find.text('Turn into a Route'));
      await tester.pumpAndSettle();

      verify(favorites.favoriteSession('s1', routeName: anyNamed('routeName')))
          .called(1);
    });

    testWidgets('removing deletes only this viewers link', (tester) async {
      when(favorites.isFavorited(any)).thenAnswer((_) async => true);

      await pumpPage(tester);
      await tester.tap(find.text('Remove from Routes'));
      await tester.pumpAndSettle();

      verify(favorites.unfavoriteRoute('s1')).called(1);
    });

    testWidgets('a visitor may also save someone elses run', (tester) async {
      // Much of the point: you turn *other people's* runs into routes to go
      // and run yourself.
      await pumpPage(tester, viewerUid: visitor, ownerUid: runner);

      expect(find.text('Turn into a Route'), findsOneWidget);
    });

    testWidgets('a run with no recorded path cannot be saved', (tester) async {
      when(sessions.fetchSessionById(any))
          .thenAnswer((_) async => session(path: const []));

      await pumpPage(tester);

      final button = tester.widget<FilledButton>(
        find.ancestor(
          of: find.text('Turn into a Route'),
          matching: find.byType(FilledButton),
        ),
      );
      expect(button.onPressed, isNull);
    });
  });
}
