import 'package:dash/config/app_theme.dart';
import 'package:dash/screens/route_library_page.dart';
import 'package:dash/services/route_repository.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mockito/mockito.dart';

import '../mocks.mocks.dart';

/// The two-section library the home screen's "Search for a route" opens.
///
/// Section 2 is a full-screen map that claims horizontal drags for panning,
/// so a swipe can never get *out* of it — which is why the tab header is
/// load-bearing rather than decoration, and why most of these tests drive the
/// tabs rather than swiping.
void main() {
  late MockRouteRepository routes;
  late MockFavoriteRouteRepository favorites;

  SavedRoute route(String id, String name) => SavedRoute(
        id: id,
        userId: 'runner-1',
        name: name,
        distanceMeters: 4200,
        estimatedTimeMin: 38,
        estimatedCalories: 294,
        isLoop: true,
        loopAreaM2: 120000,
        isPublic: false,
        routePolyline: const [LatLng(45.65, 9.20), LatLng(45.66, 9.21)],
        createdAt: DateTime(2026, 3, 14),
      );

  setUpAll(() async {
    // Section 2 (`RouteSearchPage`) is a full app screen that reaches Firebase
    // in its own initState, and the PageView builds it eagerly alongside
    // section 1. A mock Firebase app lets it construct so the *library page*
    // — the thing under test — can be driven at all.
    TestWidgetsFlutterBinding.ensureInitialized();
    setupFirebaseCoreMocks();
    await Firebase.initializeApp();
  });

  setUp(() {
    routes = MockRouteRepository();
    favorites = MockFavoriteRouteRepository();
    when(routes.fetchUserRoutes()).thenAnswer((_) async => []);
    when(favorites.fetchFavorites()).thenAnswer((_) async => []);
  });

  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(500, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    addTearDown(() => tester.pumpWidget(const SizedBox()));

    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: RouteLibraryPage(
          routeRepository: routes,
          favoriteRepository: favorites,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  /// The tab in the header, as opposed to the same words appearing as a
  /// heading inside the section itself. The tab bar is the last child of the
  /// page's Stack, so it is last in the widget tree too.
  Finder tab(String label) => find.text(label).last;

  /// Switches section via the tab header and lets the 260ms page animation
  /// finish. Not `pumpAndSettle`: section 2 builds a live map whose tile
  /// requests never go idle, so settling would time out.
  Future<void> tapTab(WidgetTester tester, String label) async {
    await tester.tap(tab(label));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  group('layout', () {
    testWidgets('shows both section tabs', (tester) async {
      await pumpPage(tester);

      // 'My Routes' is both a tab and the section's own heading.
      expect(find.text('My Routes'), findsWidgets);
      expect(find.text('Find a Route'), findsWidgets);
    });

    testWidgets('opens on My Routes', (tester) async {
      // The landing section deliberately: most people reach for a route they
      // already have rather than generating a new one.
      await pumpPage(tester);

      expect(
        RouteLibraryPage.savedRoutesSection,
        lessThan(RouteLibraryPage.searchSection),
      );
      verify(routes.fetchUserRoutes()).called(1);
    });
  });

  group('loading My Routes', () {
    testWidgets('reads both the owned routes and the favourites',
        (tester) async {
      await pumpPage(tester);

      verify(routes.fetchUserRoutes()).called(1);
      verify(favorites.fetchFavorites()).called(1);
    });

    testWidgets('renders the routes it gets back', (tester) async {
      when(routes.fetchUserRoutes())
          .thenAnswer((_) async => [route('r1', 'Morning loop')]);

      await pumpPage(tester);
      await tester.pump();

      expect(find.text('Morning loop'), findsOneWidget);
    });

    testWidgets('renders favourites alongside owned routes', (tester) async {
      when(routes.fetchUserRoutes())
          .thenAnswer((_) async => [route('r1', 'Mine')]);
      when(favorites.fetchFavorites())
          .thenAnswer((_) async => [route('s1', 'Theirs')]);

      await pumpPage(tester);
      await tester.pump();

      expect(find.text('Mine'), findsOneWidget);
      expect(find.text('Theirs'), findsOneWidget);
    });

    testWidgets('an empty library still renders', (tester) async {
      await pumpPage(tester);
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.text('My Routes'), findsWidgets);
    });

    testWidgets('a failure is reported, not left as a blank list',
        (tester) async {
      // The two lists come from different collections with different rules,
      // so one can fail while the other succeeds.
      when(routes.fetchUserRoutes()).thenThrow(Exception('permission denied'));

      await pumpPage(tester);
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.textContaining('Could not load'), findsWidgets);
    });
  });

  group('switching sections', () {
    testWidgets('the tab header moves to Find a Route', (tester) async {
      // The header is the only way out of section 2, since its map claims
      // horizontal drags. Don't remove it assuming swiping covers it.
      await pumpPage(tester);

      await tapTab(tester, 'Find a Route');

      expect(
        RouteLibraryScope.maybeOf(tester.element(tab('Find a Route')))
            ?.activeSection,
        RouteLibraryPage.searchSection,
      );
    });

    testWidgets('and back to My Routes', (tester) async {
      await pumpPage(tester);
      await tapTab(tester, 'Find a Route');

      await tapTab(tester, 'My Routes');

      expect(
        RouteLibraryScope.maybeOf(tester.element(tab('My Routes')))
            ?.activeSection,
        RouteLibraryPage.savedRoutesSection,
      );
    });

    testWidgets('returning to My Routes re-reads the list', (tester) async {
      // The section is kept alive off screen, so a route saved from the
      // search section would otherwise not appear until a pull-to-refresh.
      await pumpPage(tester);
      await tapTab(tester, 'Find a Route');

      await tapTab(tester, 'My Routes');

      verify(routes.fetchUserRoutes()).called(greaterThanOrEqualTo(2));
    });

    testWidgets('tapping the already-active tab does nothing', (tester) async {
      await pumpPage(tester);

      await tapTab(tester, 'My Routes');

      // `_goToSection` returns early, so no extra reload is triggered.
      verify(routes.fetchUserRoutes()).called(1);
    });
  });

  group('RouteLibraryScope', () {
    // It has to be an InheritedWidget rather than a constructor flag: a
    // kept-alive but off-screen child does not receive rebuilt widget
    // configurations, so a plain flag would go stale exactly when it matters.
    testWidgets('publishes the active section to its subtree', (tester) async {
      await pumpPage(tester);

      final scope =
          RouteLibraryScope.maybeOf(tester.element(tab('My Routes')));
      expect(scope, isNotNull);
      expect(scope!.activeSection, RouteLibraryPage.savedRoutesSection);
    });

    testWidgets('reads as absent outside the library', (tester) async {
      // RouteSearchPage is usable standalone, and treats "no scope" as full
      // standalone behaviour.
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              expect(RouteLibraryScope.maybeOf(context), isNull);
              return const SizedBox();
            },
          ),
        ),
      );
    });
  });
}
