import 'package:dash/config/app_theme.dart';
import 'package:dash/screens/saved_route_detail_page.dart';
import 'package:dash/services/route_repository.dart';
import 'package:dash/widgets/profile/route_source.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:mockito/mockito.dart';

// `MockUser` is declared by both firebase_auth_mocks and our generated
// mocks (from the `User` entry). The firebase_auth_mocks one is what
// `MockFirebaseAuth` expects, so the generated one is hidden here.
import '../mocks.mocks.dart' hide MockUser;

/// One saved route in full. Two things carry real weight here:
///
///  * **who is offered the rename pencil** — any signed-in user can now read
///    any route, but only its owner may update one, so showing the pencil to
///    a visitor would advertise a write the rules are guaranteed to deny;
///  * **where a rename is written** — an owned route's name lives on the
///    `routes` document, a favourite's on that user's own link. The two are
///    not interchangeable, and picking the wrong one is a silent failure.
void main() {
  late MockRouteRepository routes;
  late MockFavoriteRouteRepository favorites;

  SavedRoute route({
    String id = 'r1',
    String? userId = 'runner-1',
    String name = 'Morning loop',
    bool isPublic = false,
    List<LatLng>? polyline,
  }) =>
      SavedRoute(
        id: id,
        userId: userId,
        name: name,
        distanceMeters: 4200,
        estimatedTimeMin: 38,
        estimatedCalories: 294,
        isLoop: true,
        loopAreaM2: 120000,
        isPublic: isPublic,
        routePolyline:
            polyline ?? const [LatLng(45.65, 9.20), LatLng(45.66, 9.21)],
        createdAt: DateTime(2026, 3, 14),
      );

  setUp(() {
    routes = MockRouteRepository();
    favorites = MockFavoriteRouteRepository();
    when(routes.renameRoute(any, any)).thenAnswer((_) async {});
    when(favorites.renameFavorite(any, any)).thenAnswer((_) async {});
  });

  /// Pumps the page as [viewerUid], or signed out when null.
  Future<void> pumpPage(
    WidgetTester tester, {
    required RouteSource source,
    SavedRoute? subject,
    String? viewerUid = 'runner-1',
    String? authorName,
  }) async {
    tester.view.physicalSize = const Size(500, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              await Navigator.of(context).push<List<LatLng>>(
                MaterialPageRoute(
                  builder: (_) => SavedRouteDetailPage(
                    route: subject ?? route(),
                    source: source,
                    authorName: authorName,
                    auth: viewerUid == null
                        ? MockFirebaseAuth()
                        : MockFirebaseAuth(
                            signedIn: true,
                            mockUser: MockUser(uid: viewerUid),
                          ),
                    routeRepository: routes,
                    favoriteRepository: favorites,
                  ),
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  Finder pencil() => find.byIcon(Symbols.edit_rounded);

  group('the rename pencil', () {
    testWidgets('is offered to the owner of an owned route', (tester) async {
      await pumpPage(tester, source: RouteSource.owned);

      expect(pencil(), findsOneWidget);
    });

    testWidgets('is hidden from a visitor looking at someone elses route',
        (tester) async {
      // The rules would deny the write, so offering it would be a lie.
      await pumpPage(tester,
          source: RouteSource.owned, viewerUid: 'someone-else');

      expect(pencil(), findsNothing);
    });

    testWidgets('is hidden when signed out', (tester) async {
      await pumpPage(tester, source: RouteSource.owned, viewerUid: null);

      expect(pencil(), findsNothing);
    });

    testWidgets('is always offered on a favourite', (tester) async {
      // The name lives on the viewer's own link, so it is theirs to change
      // whoever originally ran it.
      await pumpPage(
        tester,
        source: RouteSource.favorite,
        subject: route(userId: null),
        viewerUid: 'someone-else',
      );

      expect(pencil(), findsOneWidget);
    });

    testWidgets('is never offered for a created route', (tester) async {
      await pumpPage(tester, source: RouteSource.created);

      expect(pencil(), findsNothing);
    });
  });

  group('where a rename is written', () {
    Future<void> renameTo(WidgetTester tester, String name) async {
      await tester.tap(pencil());
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), name);
      await tester.pump();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
    }

    testWidgets('an owned route is renamed on the routes document',
        (tester) async {
      await pumpPage(tester, source: RouteSource.owned);

      await renameTo(tester, 'Evening loop');

      verify(routes.renameRoute('r1', 'Evening loop')).called(1);
      verifyNever(favorites.renameFavorite(any, any));
    });

    testWidgets('a favourite is renamed on the viewers own link',
        (tester) async {
      // Writing to the shared route instead would be denied by the rules, and
      // would rename it for everyone who favourited the same run.
      await pumpPage(
        tester,
        source: RouteSource.favorite,
        subject: route(id: 'session-1', userId: null),
      );

      await renameTo(tester, 'My favourite loop');

      verify(favorites.renameFavorite('session-1', 'My favourite loop'))
          .called(1);
      verifyNever(routes.renameRoute(any, any));
    });

    testWidgets('the new name is shown immediately', (tester) async {
      // Held in state so it does not wait for the list behind to re-read.
      await pumpPage(tester, source: RouteSource.owned);

      await renameTo(tester, 'Evening loop');

      expect(find.text('Evening loop'), findsWidgets);
    });

    testWidgets('cancelling writes nothing', (tester) async {
      await pumpPage(tester, source: RouteSource.owned);

      await tester.tap(pencil());
      await tester.pumpAndSettle();
      // Scoped to the dialog: the page has its own Cancel button too.
      await tester.tap(find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Cancel'),
      ));
      await tester.pumpAndSettle();

      verifyNever(routes.renameRoute(any, any));
    });

    testWidgets('re-entering the same name writes nothing', (tester) async {
      // A no-op rename is a wasted write and a wasted cache invalidation.
      await pumpPage(tester, source: RouteSource.owned);

      await renameTo(tester, 'Morning loop');

      verifyNever(routes.renameRoute(any, any));
    });
  });

  group('the Run contract', () {
    // The page pops with the polyline; the library forwards it to HomeScreen,
    // which starts tracking. Popping the wrong thing silently starts nothing.
    testWidgets('Run returns the route geometry to the caller',
        (tester) async {
      late List<LatLng>? result;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                result = await Navigator.of(context).push<List<LatLng>>(
                  MaterialPageRoute(
                    builder: (_) => SavedRouteDetailPage(
                      route: route(),
                      source: RouteSource.owned,
                      auth: MockFirebaseAuth(
                        signedIn: true,
                        mockUser: MockUser(uid: 'runner-1'),
                      ),
                      routeRepository: routes,
                      favoriteRepository: favorites,
                    ),
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Run'));
      await tester.pumpAndSettle();

      expect(result, hasLength(2));
      expect(result!.first.latitude, closeTo(45.65, 1e-9));
    });

    testWidgets('Cancel pops with nothing', (tester) async {
      await pumpPage(tester, source: RouteSource.owned);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(find.byType(SavedRouteDetailPage), findsNothing);
    });

    testWidgets('Run is disabled for a route with no usable path',
        (tester) async {
      await pumpPage(
        tester,
        source: RouteSource.owned,
        subject: route(polyline: const [LatLng(45.65, 9.20)]),
      );

      // It is a FilledButton.icon, not an ElevatedButton.
      final run = tester.widget<FilledButton>(
        find.ancestor(
          of: find.text('Run'),
          matching: find.byType(FilledButton),
        ),
      );
      expect(run.onPressed, isNull);
    });
  });

  group('visibility line', () {
    testWidgets('is shown to the owner of an owned route', (tester) async {
      await pumpPage(tester, source: RouteSource.owned);

      expect(find.text('Only you can see this route.'), findsOneWidget);
    });

    testWidgets('says so for a published route', (tester) async {
      await pumpPage(
        tester,
        source: RouteSource.owned,
        subject: route(isPublic: true),
      );

      expect(
        find.text('Anyone can see this route on your profile.'),
        findsOneWidget,
      );
    });

    testWidgets('is hidden from a visitor', (tester) async {
      // A visitor only ever sees public routes, so the line would say nothing.
      await pumpPage(tester,
          source: RouteSource.owned, viewerUid: 'someone-else');

      expect(find.textContaining('can see this route'), findsNothing);
    });

    testWidgets('is hidden on a favourite', (tester) async {
      // It points at a shared document whose readability is not this user's.
      await pumpPage(
        tester,
        source: RouteSource.favorite,
        subject: route(userId: null),
      );

      expect(find.textContaining('can see this route'), findsNothing);
    });
  });

  group('author line', () {
    testWidgets('credits the original runner when known', (tester) async {
      await pumpPage(
        tester,
        source: RouteSource.favorite,
        subject: route(userId: null),
        authorName: 'Andrea',
      );

      expect(find.text('Originally run by Andrea'), findsOneWidget);
    });

    testWidgets('is omitted when the author is not knowable', (tester) async {
      // Account deletion strips the link back to the runner deliberately.
      await pumpPage(
        tester,
        source: RouteSource.favorite,
        subject: route(userId: null),
      );

      expect(find.textContaining('Originally run by'), findsNothing);
    });
  });
}
