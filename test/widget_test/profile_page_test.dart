import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:network_image_mock/network_image_mock.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dash/models/badge_model.dart';
import 'package:dash/screens/profile_page.dart';

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

    testWidgets('a failed run load does not stop the routes loading',
        (tester) async {
      // The two rows come from different collections with different rules,
      // so they settle independently — a permission error on one must not
      // report "Could not load" under both headings.
      when(sessions.fetchUserSessions(userId: anyNamed('userId')))
          .thenAnswer((_) async => throw Exception('denied'));
      await addProfile();

      await pumpPage(tester);

      expect(tester.takeException(), isNull);
      verify(routes.fetchUserRoutes()).called(1);
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
}
