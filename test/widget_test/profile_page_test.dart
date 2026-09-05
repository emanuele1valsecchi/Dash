import 'package:material_symbols_icons/symbols.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mockito/mockito.dart';
import 'package:network_image_mock/network_image_mock.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dash/models/badge_model.dart';
import 'package:dash/screens/profile_page.dart';
import 'package:dash/services/route_repository.dart';
import 'package:dash/widgets/dash_route_card.dart';

import '../helpers/pump_app.dart';
import '../mocks.mocks.dart' hide MockUser;

void main() {
  late FakeFirebaseFirestore db;
  late MockFirebaseAuth auth;
  late MockBadgeService badges;
  late MockRunSessionRepository sessions;
  late MockRouteRepository routes;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = FakeFirebaseFirestore();
    auth = MockFirebaseAuth(
      signedIn: true,
      mockUser: MockUser(uid: 'me', email: 'me@example.com'),
    );
    badges = MockBadgeService();
    sessions = MockRunSessionRepository();
    routes = MockRouteRepository();

    when(badges.getProfileBadges(any)).thenAnswer((_) async => <BadgeModel>[]);
    when(sessions.fetchUserSessions(userId: anyNamed('userId')))
        .thenAnswer((_) async => []);
    when(routes.fetchUserRoutes()).thenAnswer((_) async => []);
  });

  Future<void> addProfile({
    String uid = 'me',
    String? name = 'Ada',
    String? surname = 'Lovelace',
    String? email = 'ada@example.com',
    String? bio = 'I run.',
    int? followers,
    int? following,
  }) =>
      db.collection('profiles').doc(uid).set({
        'name': ?name,
        'surname': ?surname,
        'email': ?email,
        'bio': ?bio,
        'followersCount': ?followers,
        'followingCount': ?following,
        'profileImageUrl': '',
      });

  Future<void> pumpPage(WidgetTester tester, {MockFirebaseAuth? withAuth}) async {
    await mockNetworkImagesFor(() async {
      await pumpDashWidget(
        tester,
        ProfilePage(
          firestore: db,
          auth: withAuth ?? auth,
          badgeService: badges,
          sessionRepository: sessions,
          routeRepository: routes,
        ),
        wrapInScaffold: false,
        // Wider than a real phone on purpose. The action row holds two
        // labelled buttons ("Edit Profile", "Share Profile") plus an icon,
        // which fit a 390 px phone at real font metrics — but the test font
        // is roughly 1 em per character, about double the real width, so at
        // phone width the row overflows for reasons that have nothing to do
        // with the widget. See TEST_NOTES 1.2; two "overflow bugs" were
        // reported from exactly this before and neither was real.
        surfaceSize: const Size(900, 1400),
      );
      // Fixed pumps, not `pumpAndSettle`: the embedded activity cards keep
      // an animation running indefinitely, so settling never returns. The
      // twin `public_profile_page_test.dart` does the same for the same
      // reason.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 200));
    });
  }

  group('the profile', () {
    testWidgets('shows the signed-in user\'s details', (tester) async {
      await addProfile();

      await pumpPage(tester);

      expect(find.textContaining('Ada'), findsWidgets);
      expect(find.text('I run.'), findsOneWidget);
    });

    testWidgets('shows follower and following counts', (tester) async {
      await addProfile(followers: 12, following: 34);

      await pumpPage(tester);

      expect(find.text('12'), findsOneWidget);
      expect(find.text('34'), findsOneWidget);
    });

    testWidgets('missing counts read as zero, not as an error',
        (tester) async {
      await addProfile();

      await pumpPage(tester);

      expect(find.text('0'), findsWidgets);
    });

    testWidgets('a profile with no name falls back rather than blanking',
        (tester) async {
      await addProfile(name: null, surname: null, email: null);

      await pumpPage(tester);

      expect(find.textContaining('No Name'), findsWidgets);
    });

    testWidgets('updates live when the profile document changes',
        (tester) async {
      // This one is a real listener rather than a one-time read, so an edit
      // made on the Edit Profile screen should land without a reload.
      await addProfile(bio: 'Old bio');
      await pumpPage(tester);
      expect(find.text('Old bio'), findsOneWidget);

      await addProfile(bio: 'New bio');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('New bio'), findsOneWidget);
      expect(find.text('Old bio'), findsNothing);
    });

    testWidgets('stops loading even when there is no profile document',
        (tester) async {
      // A brand-new account between signup and profile creation.
      await pumpPage(tester);
      await tester.pump(const Duration(seconds: 1));

      expect(tester.takeException(), isNull);
    });
  });

  group('badges', () {
    testWidgets('are asked for, for the signed-in user', (tester) async {
      await addProfile();

      await pumpPage(tester);

      verify(badges.getProfileBadges('me')).called(1);
    });

    testWidgets('a failed badge read does not take the page down',
        (tester) async {
      // `_startBadgesStream` is `async void` — nothing awaits it, so a throw
      // escapes as an unhandled async error rather than reaching a caller.
      // This read was denied outright before the `badge_progress` rule was
      // widened, so the failure is realistic rather than hypothetical. The
      // same bug was found and fixed in `public_profile_page.dart` and
      // `badge_page.dart`; this is the third copy.
      when(badges.getProfileBadges(any))
          .thenAnswer((_) async => throw Exception('permission-denied'));
      await addProfile();

      await pumpPage(tester);

      expect(tester.takeException(), isNull,
          reason: 'badges are decoration; the profile must still render');
      expect(find.text('I run.'), findsOneWidget);
    });
  });

  group('the activity rows', () {
    testWidgets('ask for this user\'s runs and routes', (tester) async {
      await addProfile();

      await pumpPage(tester);

      verify(sessions.fetchUserSessions(userId: 'me')).called(1);
      verify(routes.fetchUserRoutes()).called(1);
    });

    testWidgets('a failed run load does not blank the routes', (tester) async {
      // The two rows come from different collections with different rules,
      // so they settle independently — a permission error on one must not
      // report "Could not load" under both headings.
      //
      // The failure is **delayed on purpose** so it lands after the routes
      // have already succeeded. That ordering is the test: a shared failure
      // flag looks fine when the failure resolves first and is overwritten,
      // and only shows itself when a late failure blanks a loaded row.
      // Asserting only that `fetchUserRoutes` was *called* is not enough —
      // it is called either way, so that version of this test passed against
      // a deliberately reintroduced shared flag.
      when(sessions.fetchUserSessions(userId: anyNamed('userId')))
          .thenAnswer((_) async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        throw Exception('denied');
      });
      when(routes.fetchUserRoutes()).thenAnswer((_) async => [
            SavedRoute(
              id: 'r1',
              userId: 'me',
              name: 'Park loop',
              routePolyline: const [LatLng(45.46, 9.19), LatLng(45.47, 9.20)],
              distanceMeters: 4000,
              estimatedTimeMin: 36,
              estimatedCalories: 280,
              isLoop: true,
              loopAreaM2: 9000,
              isPublic: false,
              createdAt: DateTime(2026, 3, 14),
            ),
          ]);
      await addProfile();

      await pumpPage(tester);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 200));

      expect(tester.takeException(), isNull);
      expect(find.text('Could not load'), findsOneWidget,
          reason: 'the runs row failed; the routes row did not');
      expect(find.byType(DashRouteCard), findsWidgets);
    });
  });

  group('signed out', () {
    testWidgets('does not reach for a null user', (tester) async {
      // Both streams start from `currentUser`, and the build indexes it with
      // `!` — a signed-out render would throw rather than degrade.
      await pumpPage(tester, withAuth: MockFirebaseAuth());
      await tester.pump(const Duration(seconds: 1));

      expect(find.byType(ProfilePage), findsOneWidget);
    });
  });

  group('badge progress', () {
    // `badge_progress` stores progress as a **percentage, 0-100**. Every
    // badge screen builds its own view model from a live snapshot and divides
    // by 100 there — this is one of those places, and getting it wrong shows
    // a full ring for a badge barely started.
    BadgeModel badgeModel({
      String id = 'duke',
      String title = 'Duke',
      String imagePath = 'badges/duke.png',
    }) =>
        BadgeModel(
          id: id,
          title: title,
          description: 'Hold a city.',
          imagePath: imagePath,
          defaultVisible: true,
          order: 1,
          requiredValue: 10,
          progress: 0,
          unlocked: false,
        );

    Future<void> setProgress(String id,
        {double progress = 0, bool unlocked = false}) =>
        db
            .collection('profiles')
            .doc('me')
            .collection('badge_progress')
            .doc(id)
            .set({'progress': progress, 'unlocked': unlocked});

    testWidgets('a stored percentage becomes a 0..1 fraction', (tester) async {
      when(badges.getProfileBadges(any))
          .thenAnswer((_) async => [badgeModel()]);
      await setProgress('duke', progress: 40);
      await addProfile();

      await pumpPage(tester);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble('progress_duke'), closeTo(0.4, 1e-9));
    });

    testWidgets('progress is clamped, never over full', (tester) async {
      // A miscounted server value must not produce a ring past 100%.
      when(badges.getProfileBadges(any))
          .thenAnswer((_) async => [badgeModel()]);
      await setProgress('duke', progress: 250);
      await addProfile();

      await pumpPage(tester);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble('progress_duke'), 1.0);
    });

    testWidgets('a full badge counts as unlocked even without the flag',
        (tester) async {
      when(badges.getProfileBadges(any))
          .thenAnswer((_) async => [badgeModel()]);
      await setProgress('duke', progress: 100, unlocked: false);
      await addProfile();

      await pumpPage(tester);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('unlocked_duke'), isTrue);
    });

    testWidgets('the unlocked flag alone is enough', (tester) async {
      when(badges.getProfileBadges(any))
          .thenAnswer((_) async => [badgeModel()]);
      await setProgress('duke', progress: 10, unlocked: true);
      await addProfile();

      await pumpPage(tester);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('unlocked_duke'), isTrue);
    });

    testWidgets('a badge with no progress row reads as zero, not missing',
        (tester) async {
      when(badges.getProfileBadges(any))
          .thenAnswer((_) async => [badgeModel()]);
      await addProfile();

      await pumpPage(tester);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble('progress_duke'), 0.0);
      expect(prefs.getBool('unlocked_duke'), isFalse);
    });

    testWidgets('a cached artwork url is reused rather than re-fetched',
        (tester) async {
      // Firebase Storage is unreachable in a widget test, so a badge whose
      // url is already on disk is the only one that can render its artwork —
      // which is exactly the path the cache exists for.
      SharedPreferences.setMockInitialValues({
        'badge_url_badges/duke.png': 'https://example.com/duke.png',
      });
      when(badges.getProfileBadges(any))
          .thenAnswer((_) async => [badgeModel()]);
      await setProgress('duke', progress: 40);
      await addProfile();

      await pumpPage(tester);

      expect(tester.takeException(), isNull);
      expect(find.text('Duke'), findsWidgets);
    });
  });


  group('where the profile leads', () {
    // Destinations are substituted (see `ProfilePage`'s builder seams) —
    // each real one stands up its own Firebase-backed world, so letting them
    // build would make the tap untestable rather than the page untestable.
    Future<void> pumpWithStubs(WidgetTester tester) async {
      await mockNetworkImagesFor(() async {
        await pumpDashWidget(
          tester,
          ProfilePage(
            firestore: db,
            auth: auth,
            badgeService: badges,
            sessionRepository: sessions,
            routeRepository: routes,
            settingsPageBuilder: () => const Text('SETTINGS'),
            editProfilePageBuilder: () => const Text('EDIT'),
            shareProfilePageBuilder: (uid, name, surname) =>
                Text('SHARE $uid $name $surname'),
            searchFriendPageBuilder: () => const Text('SEARCH'),
          ),
          wrapInScaffold: false,
          surfaceSize: const Size(900, 1400),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));
        await tester.pump(const Duration(milliseconds: 200));
      });
    }

    Future<void> tapAndSettle(WidgetTester tester, Finder target) async {
      await tester.tap(target);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    testWidgets('the gear opens settings', (tester) async {
      await addProfile();
      await pumpWithStubs(tester);

      await tapAndSettle(
          tester, find.widgetWithIcon(IconButton, Symbols.settings_rounded));

      expect(find.text('SETTINGS'), findsOneWidget);
    });

    testWidgets('Edit Profile opens the editor', (tester) async {
      await addProfile();
      await pumpWithStubs(tester);

      await tapAndSettle(tester, find.text('Edit Profile'));

      expect(find.text('EDIT'), findsOneWidget);
    });

    testWidgets('Share Profile carries the identity being shared',
        (tester) async {
      // A share sheet naming the wrong person, or nobody, is worse than no
      // share at all — so the uid and name travel with it rather than being
      // re-read at the far end.
      await addProfile(name: 'Ada', surname: 'Lovelace');
      await pumpWithStubs(tester);

      await tapAndSettle(tester, find.text('Share Profile'));

      expect(find.text('SHARE me Ada Lovelace'), findsOneWidget);
    });

    testWidgets('the add-friend action opens search', (tester) async {
      await addProfile();
      await pumpWithStubs(tester);

      await tapAndSettle(
          tester, find.widgetWithIcon(IconButton, Symbols.person_add_rounded));

      expect(find.text('SEARCH'), findsOneWidget);
    });

    testWidgets('a signed-out viewer shares nothing', (tester) async {
      // `_shareProfile` returns early with no current user; pushing a share
      // page for nobody would name an empty profile.
      await addProfile();
      await mockNetworkImagesFor(() async {
        await pumpDashWidget(
          tester,
          ProfilePage(
            firestore: db,
            auth: MockFirebaseAuth(),
            badgeService: badges,
            sessionRepository: sessions,
            routeRepository: routes,
            shareProfilePageBuilder: (uid, name, surname) =>
                const Text('SHARE'),
          ),
          wrapInScaffold: false,
          surfaceSize: const Size(900, 1400),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));
      });

      if (find.text('Share Profile').evaluate().isNotEmpty) {
        await tapAndSettle(tester, find.text('Share Profile'));
      }

      expect(find.text('SHARE'), findsNothing);
    });
  });

}
