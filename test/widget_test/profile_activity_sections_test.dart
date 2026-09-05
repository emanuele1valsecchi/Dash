import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:material_symbols_icons/symbols.dart';
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

  group('deleting a route', () {
    // This is the app's only delete-a-route affordance, and it is
    // irreversible — it lives on your own profile rather than in the route
    // library precisely so a delete button is not under your thumb while
    // choosing something to run.
    Future<void> pumpOwnRoutes(WidgetTester tester,
        {List<SavedRoute>? owned}) async {
      when(routes.fetchUserRoutes())
          .thenAnswer((_) async => owned ?? [route('x1', name: 'Park loop')]);
      await pumpSections(tester, userId: 'me', isCurrentUser: true);
    }

    Future<void> tapDelete(WidgetTester tester) async {
      await tester.tap(find.byIcon(Symbols.delete_rounded).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    testWidgets('asks before removing anything', (tester) async {
      await pumpOwnRoutes(tester);

      await tapDelete(tester);

      expect(find.text('Delete route?'), findsOneWidget);
      expect(find.textContaining('Park loop'), findsWidgets);
      verifyNever(routes.deleteRoute(any));
    });

    testWidgets('cancelling deletes nothing', (tester) async {
      await pumpOwnRoutes(tester);
      await tapDelete(tester);

      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      verifyNever(routes.deleteRoute(any));
      expect(find.byType(DashRouteCard), findsWidgets);
    });

    testWidgets('confirming deletes that route', (tester) async {
      when(routes.deleteRoute(any)).thenAnswer((_) async {});
      await pumpOwnRoutes(tester);
      await tapDelete(tester);

      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      verify(routes.deleteRoute('x1')).called(1);
    });

    testWidgets('the card disappears without a reload', (tester) async {
      // The list is a one-time cached read, so the row has to be dropped
      // locally or the deleted route stays on screen until relaunch.
      when(routes.deleteRoute(any)).thenAnswer((_) async {});
      await pumpOwnRoutes(tester);
      await tapDelete(tester);

      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(DashRouteCard), findsNothing);
    });

    testWidgets('a failed delete keeps the row and says so', (tester) async {
      // Removing it locally after a failed write would tell the user their
      // route was deleted when it still exists.
      when(routes.deleteRoute(any))
          .thenAnswer((_) async => throw Exception('denied'));
      await pumpOwnRoutes(tester);
      await tapDelete(tester);

      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(DashRouteCard), findsWidgets);
      expect(find.textContaining('Could not delete'), findsOneWidget);
    });

    testWidgets('is not offered on somebody else\'s profile', (tester) async {
      // Only an owner may delete; offering it to a visitor would advertise a
      // write the rules are guaranteed to deny.
      when(routes.fetchRoutesForUser(any, publicOnly: anyNamed('publicOnly')))
          .thenAnswer((_) async => [route('x1')]);

      await pumpSections(tester, userId: 'them', isCurrentUser: false);

      expect(find.byIcon(Symbols.delete_rounded), findsNothing);
    });
  });


  group('the owner-only affordances', () {
    // A card must never advertise an edit the viewer cannot perform: the
    // rules let only an owner rename or delete a route, so on somebody
    // else's profile neither glyph is drawn. The pencil *is* the affordance
    // — cards used to carry a leading glyph unconditionally, which promised
    // an edit they did not offer.
    testWidgets('your own route offers rename and delete', (tester) async {
      when(routes.fetchUserRoutes())
          .thenAnswer((_) async => [route('x1', name: 'Park loop')]);

      await pumpSections(tester, userId: 'me', isCurrentUser: true);

      expect(find.byIcon(Symbols.edit_rounded), findsWidgets);
      expect(find.byIcon(Symbols.delete_rounded), findsWidgets);
    });

    testWidgets("a stranger's route offers neither", (tester) async {
      when(routes.fetchRoutesForUser(any, publicOnly: anyNamed('publicOnly')))
          .thenAnswer((_) async => [route('x1', name: 'Park loop')]);

      await pumpSections(tester, userId: 'them', isCurrentUser: false);

      expect(find.byType(DashRouteCard), findsWidgets,
          reason: 'the route itself is still shown');
      expect(find.byIcon(Symbols.edit_rounded), findsNothing);
      expect(find.byIcon(Symbols.delete_rounded), findsNothing);
    });
  });

  group('renaming a route', () {
    // Renaming is offered on the card itself so a badly-named route can be
    // fixed without opening it. Only the owner may: `firestore.rules` allows
    // a field-scoped update by the owner alone.
    Future<void> pumpOwnRoute(WidgetTester tester) async {
      when(routes.fetchUserRoutes())
          .thenAnswer((_) async => [route('x1', name: 'Park loop')]);
      await pumpSections(tester, userId: 'me', isCurrentUser: true);
    }

    Future<void> tapRename(WidgetTester tester) async {
      await tester.tap(find.byIcon(Symbols.edit_rounded).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    Future<void> enterName(WidgetTester tester, String name) async {
      await tester.enterText(find.byType(TextField).first, name);
      await tester.pump();
    }

    testWidgets('opens a prompt showing the current name', (tester) async {
      await pumpOwnRoute(tester);

      await tapRename(tester);

      expect(find.byType(TextField), findsWidgets);
      expect(find.textContaining('Park loop'), findsWidgets);
    });

    testWidgets('saves the new name', (tester) async {
      when(routes.renameRoute(any, any)).thenAnswer((_) async {});
      await pumpOwnRoute(tester);
      await tapRename(tester);

      await enterName(tester, 'River loop');
      await tester.tap(find.widgetWithText(TextButton, 'Save'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      verify(routes.renameRoute('x1', 'River loop')).called(1);
    });

    testWidgets('dismissing it writes nothing', (tester) async {
      await pumpOwnRoute(tester);
      await tapRename(tester);

      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      verifyNever(routes.renameRoute(any, any));
    });

    testWidgets('re-entering the same name writes nothing', (tester) async {
      // A no-op update is still a write, and this one would also invalidate
      // the route cache and re-read both rows for nothing.
      await pumpOwnRoute(tester);
      await tapRename(tester);

      await enterName(tester, 'Park loop');
      await tester.tap(find.widgetWithText(TextButton, 'Save'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      verifyNever(routes.renameRoute(any, any));
    });

    testWidgets('a rejected rename says so and keeps the row', (tester) async {
      // The rules deny an update on somebody else's route, and a rename can
      // also simply fail. Either way the card must stay put — silently
      // reverting would look like the new name had been accepted.
      when(routes.renameRoute(any, any))
          .thenAnswer((_) async => throw Exception('permission-denied'));
      await pumpOwnRoute(tester);
      await tapRename(tester);

      await enterName(tester, 'River loop');
      await tester.tap(find.widgetWithText(TextButton, 'Save'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.textContaining('Could not rename'), findsOneWidget);
      expect(find.byType(DashRouteCard), findsWidgets);
    });

    testWidgets('a successful rename re-reads the row', (tester) async {
      // The repository caches routes, and a rename invalidates that cache —
      // without the re-read the card keeps showing the old name.
      when(routes.renameRoute(any, any)).thenAnswer((_) async {});
      await pumpOwnRoute(tester);
      clearInteractions(routes);
      await tapRename(tester);

      await enterName(tester, 'River loop');
      await tester.tap(find.widgetWithText(TextButton, 'Save'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      verify(routes.fetchUserRoutes()).called(1);
    });
  });
}
