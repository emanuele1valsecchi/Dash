import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:mockito/mockito.dart';
import 'package:network_image_mock/network_image_mock.dart';

import 'package:dash/services/route_repository.dart';
import 'package:dash/widgets/dash_route_card.dart';
import 'package:dash/widgets/routes/saved_routes_section.dart';

import '../helpers/pump_app.dart';
import '../mocks.mocks.dart';

/// The route library's landing section: your own saved routes above the runs
/// you have favourited.
///
/// The distinction between the two lists is load-bearing rather than
/// cosmetic. An owned route's name lives on its own `routes` document; a
/// favourite's lives on the viewer's `favoriteRoutes` link, because the
/// shared route it points at has no owner and is denied every client write.
/// Only favourites therefore carry an action here — the heart, to un-favourite
/// — and deleting an owned route deliberately lives on the profile instead:
/// this list exists to pick something to run, and a delete button on every
/// card in a "choose a route" list is the wrong thing under your thumb.
void main() {
  late MockRouteRepository routes;
  late MockFavoriteRouteRepository favorites;

  setUp(() {
    routes = MockRouteRepository();
    favorites = MockFavoriteRouteRepository();
    when(routes.fetchUserRoutes()).thenAnswer((_) async => []);
    when(favorites.fetchFavorites()).thenAnswer((_) async => []);
  });

  SavedRoute route(String id, {String name = 'Park loop'}) => SavedRoute(
        id: id,
        userId: 'me',
        name: name,
        routePolyline: const [LatLng(45.46, 9.19), LatLng(45.47, 9.20)],
        distanceMeters: 4000,
        estimatedTimeMin: 36,
        estimatedCalories: 280,
        isLoop: true,
        loopAreaM2: 9000,
        isPublic: false,
        createdAt: DateTime(2026, 3, 14),
      );

  Future<void> pumpSection(WidgetTester tester) async {
    await mockNetworkImagesFor(() async {
      await pumpDashWidget(
        tester,
        SavedRoutesSection(
          onRunRoute: (_) {},
          routeRepository: routes,
          favoriteRepository: favorites,
        ),
        surfaceSize: const Size(900, 1800),
      );
      // Fixed pumps: the cards embed maps that keep animating.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    });
  }

  /// The un-favourite action on a card. Scoped to the card because the
  /// **Favourites section heading** carries the same heart as its leading
  /// icon — an unscoped finder counts that too.
  Finder heart() => find.descendant(
        of: find.byType(DashRouteCard),
        matching: find.byIcon(Symbols.favorite_rounded),
      );

  group('the two lists', () {
    testWidgets('both headings are always present', (tester) async {
      await pumpSection(tester);

      expect(find.text('My Routes'), findsOneWidget);
      expect(find.text('Favourites'), findsOneWidget);
    });

    testWidgets('an empty library says so under each', (tester) async {
      await pumpSection(tester);

      expect(find.text('No routes yet'), findsOneWidget);
      expect(find.text('No favourites yet'), findsOneWidget);
    });

    testWidgets('owned routes and favourites are read separately',
        (tester) async {
      await pumpSection(tester);

      verify(routes.fetchUserRoutes()).called(1);
      verify(favorites.fetchFavorites()).called(1);
    });

    testWidgets('a route appears under My Routes', (tester) async {
      when(routes.fetchUserRoutes())
          .thenAnswer((_) async => [route('r1', name: 'Park loop')]);

      await pumpSection(tester);

      expect(find.byType(DashRouteCard), findsWidgets);
      expect(find.text('No routes yet'), findsNothing);
    });

    testWidgets('a favourite appears under Favourites', (tester) async {
      when(favorites.fetchFavorites())
          .thenAnswer((_) async => [route('f1', name: 'Someone\'s run')]);

      await pumpSection(tester);

      expect(find.text('No favourites yet'), findsNothing);
    });
  });

  group('only favourites carry an action', () {
    testWidgets('a favourite has the heart', (tester) async {
      when(favorites.fetchFavorites())
          .thenAnswer((_) async => [route('f1')]);

      await pumpSection(tester);

      expect(heart(), findsWidgets);
    });

    testWidgets('an owned route has none', (tester) async {
      // Deleting an owned route lives on the profile, not here.
      when(routes.fetchUserRoutes()).thenAnswer((_) async => [route('r1')]);

      await pumpSection(tester);

      expect(find.byType(DashRouteCard), findsWidgets);
      expect(heart(), findsNothing);
    });
  });

  group('un-favouriting', () {
    Future<void> pumpWithFavourite(WidgetTester tester) async {
      when(favorites.fetchFavorites())
          .thenAnswer((_) async => [route('f1', name: 'Park loop')]);
      await pumpSection(tester);
    }

    Future<void> tapHeart(WidgetTester tester) async {
      await tester.tap(heart().last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    testWidgets('asks first, and says the run is unaffected', (tester) async {
      // Un-favouriting deletes only the viewer's link; the shared route and
      // the original run are untouched, and the wording has to say so or it
      // reads like deleting somebody's run.
      await pumpWithFavourite(tester);

      await tapHeart(tester);

      expect(find.text('Remove from favourites?'), findsOneWidget);
      expect(find.textContaining('original run is not affected'),
          findsOneWidget);
      verifyNever(favorites.unfavoriteRoute(any));
    });

    testWidgets('cancelling removes nothing', (tester) async {
      await pumpWithFavourite(tester);
      await tapHeart(tester);

      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      verifyNever(favorites.unfavoriteRoute(any));
    });

    testWidgets('confirming removes the link', (tester) async {
      when(favorites.unfavoriteRoute(any)).thenAnswer((_) async {});
      await pumpWithFavourite(tester);
      await tapHeart(tester);

      await tester.tap(find.widgetWithText(TextButton, 'Remove'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      verify(favorites.unfavoriteRoute('f1')).called(1);
    });

    testWidgets('the card goes without a reload', (tester) async {
      when(favorites.unfavoriteRoute(any)).thenAnswer((_) async {});
      await pumpWithFavourite(tester);
      await tapHeart(tester);

      await tester.tap(find.widgetWithText(TextButton, 'Remove'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('No favourites yet'), findsOneWidget);
    });

    testWidgets('a failure keeps the card and says so', (tester) async {
      when(favorites.unfavoriteRoute(any))
          .thenAnswer((_) async => throw Exception('denied'));
      await pumpWithFavourite(tester);
      await tapHeart(tester);

      await tester.tap(find.widgetWithText(TextButton, 'Remove'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('No favourites yet'), findsNothing);
      expect(find.textContaining('Could not remove'), findsOneWidget);
    });
  });

  group('failures', () {
    testWidgets('a failed route load does not blank the favourites',
        (tester) async {
      when(routes.fetchUserRoutes())
          .thenAnswer((_) async => throw Exception('denied'));
      when(favorites.fetchFavorites())
          .thenAnswer((_) async => [route('f1')]);

      await pumpSection(tester);

      expect(tester.takeException(), isNull);
      expect(find.text('No favourites yet'), findsNothing);
    });

    testWidgets('a failed favourites load does not blank the routes',
        (tester) async {
      when(favorites.fetchFavorites())
          .thenAnswer((_) async => throw Exception('denied'));
      when(routes.fetchUserRoutes()).thenAnswer((_) async => [route('r1')]);

      await pumpSection(tester);

      expect(tester.takeException(), isNull);
      expect(find.text('No routes yet'), findsNothing);
    });
  });

  group('reload', () {
    testWidgets('re-reads both lists and bypasses the cache', (tester) async {
      // Reached through a GlobalKey when the library's other section saves a
      // route: without invalidating, the cached read would not show it.
      final key = GlobalKey<SavedRoutesSectionState>();
      await mockNetworkImagesFor(() async {
        await pumpDashWidget(
          tester,
          SavedRoutesSection(
            key: key,
            onRunRoute: (_) {},
            routeRepository: routes,
            favoriteRepository: favorites,
          ),
          surfaceSize: const Size(900, 1800),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
      });

      await key.currentState!.reload();
      await tester.pump();

      verify(routes.fetchUserRoutes()).called(2);
      verify(favorites.fetchFavorites()).called(2);
    });
  });
}
