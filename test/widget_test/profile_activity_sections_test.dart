import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mockito/mockito.dart';
import 'package:network_image_mock/network_image_mock.dart';

import 'package:dash/services/route_repository.dart';
import 'package:dash/services/run_session_repository.dart';
import 'package:dash/widgets/dash_route_card.dart';
import 'package:dash/widgets/dash_run_card.dart';
import 'package:dash/widgets/profile/profile_activity_sections.dart';

import '../helpers/pump_app.dart';
import '../mocks.mocks.dart';

/// One widget renders the Runs and Routes rows on both profile screens. The
/// interesting parts are whose data it asks for and how it fails.
void main() {
  late MockRunSessionRepository sessions;
  late MockRouteRepository routes;

  setUp(() {
    sessions = MockRunSessionRepository();
    routes = MockRouteRepository();
    when(sessions.fetchUserSessions(userId: anyNamed('userId')))
        .thenAnswer((_) async => []);
    when(routes.fetchUserRoutes()).thenAnswer((_) async => []);
    when(routes.fetchRoutesForUser(any, publicOnly: anyNamed('publicOnly')))
        .thenAnswer((_) async => []);
  });

  RunSession run(String id, {String name = 'Morning run'}) => RunSession(
        id: id,
        name: name,
        distanceMeters: 5000,
        duration: const Duration(minutes: 30),
        avgPaceMinPerKm: 6,
        maxPaceMinPerKm: 4,
        elevationDifferenceMeters: 20,
        loopsCompleted: 1,
        path: const [LatLng(45.46, 9.19), LatLng(45.47, 9.20)],
        createdAt: DateTime(2026, 3, 14),
        totalAreaM2: 12000,
      );

  SavedRoute route(String id, {String name = 'Park loop', bool isPublic = true}) =>
      SavedRoute(
        id: id,
        userId: 'them',
        name: name,
        routePolyline: const [LatLng(45.46, 9.19), LatLng(45.47, 9.20)],
        distanceMeters: 4000,
        estimatedTimeMin: 36,
        estimatedCalories: 280,
        isLoop: true,
        loopAreaM2: 9000,
        isPublic: isPublic,
        createdAt: DateTime(2026, 3, 14),
      );

  Future<void> pumpSections(
    WidgetTester tester, {
    String userId = 'them',
    bool isCurrentUser = false,
  }) async {
    await mockNetworkImagesFor(() async {
      await pumpDashWidget(
        tester,
        ProfileActivitySections(
          userId: userId,
          isCurrentUser: isCurrentUser,
          displayName: 'Ada',
          sessionRepository: sessions,
          routeRepository: routes,
        ),
        surfaceSize: const Size(900, 1600),
      );
      // Fixed pumps: the cards embed maps that keep animating.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    });
  }

  group('what it asks for', () {
    testWidgets('another user\'s runs, by their id', (tester) async {
      await pumpSections(tester, userId: 'them');

      verify(sessions.fetchUserSessions(userId: 'them')).called(1);
    });

    testWidgets('only another user\'s *published* routes', (tester) async {
      // The extra filter is not cosmetic: Firestore rejects a query it
      // cannot prove is safe, so without `publicOnly` the whole query is
      // denied rather than returning a subset.
      await pumpSections(tester, userId: 'them', isCurrentUser: false);

      verify(routes.fetchRoutesForUser('them', publicOnly: true)).called(1);
      verifyNever(routes.fetchUserRoutes());
    });

    testWidgets('your own routes through the cached path, private included',
        (tester) async {
      await pumpSections(tester, userId: 'me', isCurrentUser: true);

      verify(routes.fetchUserRoutes()).called(1);
      verifyNever(
          routes.fetchRoutesForUser(any, publicOnly: anyNamed('publicOnly')));
    });
  });

  group('rendering', () {
    testWidgets('shows a card per run', (tester) async {
      when(sessions.fetchUserSessions(userId: anyNamed('userId')))
          .thenAnswer((_) async => [run('r1'), run('r2', name: 'Evening run')]);

      await pumpSections(tester);

      expect(find.byType(DashRunCard), findsWidgets);
    });

    testWidgets('shows a card per route', (tester) async {
      when(routes.fetchRoutesForUser(any, publicOnly: anyNamed('publicOnly')))
          .thenAnswer((_) async => [route('x1')]);

      await pumpSections(tester);

      expect(find.byType(DashRouteCard), findsWidgets);
    });

    testWidgets('an empty history says so under each heading', (tester) async {
      await pumpSections(tester);

      expect(find.text('No runs yet'), findsOneWidget);
      expect(find.text('No routes yet'), findsOneWidget);
    });

    testWidgets('both headings are always present', (tester) async {
      await pumpSections(tester);

      expect(find.text('Runs'), findsOneWidget);
      expect(find.text('Routes'), findsOneWidget);
    });
  });

  group('failure is per row, not per widget', () {
    // The two rows come from different collections with different rules. An
    // earlier version shared one flag behind a fail-fast `Future.wait`, so a
    // single permission error reported "Could not load" under *both*
    // headings even though the runs had come back fine.
    testWidgets('a failed run load does not blank the routes', (tester) async {
      // The failure is delayed so it lands *after* the routes have already
      // succeeded. That ordering is the whole test: a shared failure flag
      // would look fine if the failure came first and were overwritten, and
      // only shows itself when the late failure blanks an already-loaded row.
      when(sessions.fetchUserSessions(userId: anyNamed('userId')))
          .thenAnswer((_) async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        throw Exception('denied');
      });
      when(routes.fetchRoutesForUser(any, publicOnly: anyNamed('publicOnly')))
          .thenAnswer((_) async => [route('x1')]);

      await pumpSections(tester);

      expect(find.text('Could not load'), findsOneWidget);
      expect(find.byType(DashRouteCard), findsWidgets);
    });

    testWidgets('a failed route load does not blank the runs', (tester) async {
      when(routes.fetchRoutesForUser(any, publicOnly: anyNamed('publicOnly')))
          .thenAnswer((_) async => throw Exception('denied'));
      when(sessions.fetchUserSessions(userId: anyNamed('userId')))
          .thenAnswer((_) async => [run('r1')]);

      await pumpSections(tester);

      expect(find.text('Could not load'), findsOneWidget);
      expect(find.byType(DashRunCard), findsWidgets);
    });

    testWidgets('both failing reports both, and does not throw',
        (tester) async {
      when(sessions.fetchUserSessions(userId: anyNamed('userId')))
          .thenAnswer((_) async => throw Exception('denied'));
      when(routes.fetchRoutesForUser(any, publicOnly: anyNamed('publicOnly')))
          .thenAnswer((_) async => throw Exception('denied'));

      await pumpSections(tester);

      expect(tester.takeException(), isNull);
      expect(find.text('Could not load'), findsNWidgets(2));
    });
  });

  group('reload', () {
    testWidgets('re-reads both rows', (tester) async {
      // Reached through a GlobalKey from the profile's pull-to-refresh: the
      // rows are one-time cached reads, so without this a route saved
      // elsewhere would not appear until relaunch.
      final key = GlobalKey<ProfileActivitySectionsState>();
      await mockNetworkImagesFor(() async {
        await pumpDashWidget(
          tester,
          ProfileActivitySections(
            key: key,
            userId: 'them',
            isCurrentUser: false,
            displayName: 'Ada',
            sessionRepository: sessions,
            routeRepository: routes,
          ),
          surfaceSize: const Size(900, 1600),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
      });

      await key.currentState!.reload();
      await tester.pump();

      verify(sessions.fetchUserSessions(userId: 'them')).called(2);
    });
  });
}
