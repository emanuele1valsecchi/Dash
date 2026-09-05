import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:network_image_mock/network_image_mock.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dash/models/badge_model.dart';
import 'package:dash/screens/home_page.dart';
import 'package:dash/services/wear_bridge.dart';
import 'package:dash/utils/leaderboard_order.dart';

import '../helpers/pump_app.dart';
import '../mocks.mocks.dart' hide MockUser;

void main() {
  late FakeFirebaseFirestore db;
  late MockFirebaseAuth auth;
  late MockBadgeService badges;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = FakeFirebaseFirestore();
    auth = MockFirebaseAuth(
      signedIn: true,
      mockUser: MockUser(uid: 'me', email: 'me@example.com'),
    );
    badges = MockBadgeService();
    when(badges.getHomeBadges(any)).thenAnswer((_) async => <BadgeModel>[]);
  });

  Future<void> addProfile({String uid = 'me', String? username = 'Ada'}) =>
      db.collection('profiles').doc(uid).set({
        'username': ?username,
        'profileImageUrl': '',
      });

  Future<void> addSession({
    String userId = 'me',
    int points = 0,
    double distanceMeters = 5000,
    int durationMs = 1800000,
    String? startLocality,
    String? territoryCity,
    String? territoryBroad,
    DateTime? on,
  }) =>
      db.collection('runningSessions').add({
        'userId': userId,
        'pointsEarned': points,
        'distanceMeters': distanceMeters,
        'durationMs': durationMs,
        'maxPaceMinPerKm': 5.0,
        'startLocality': ?startLocality,
        'territoryCity': ?territoryCity,
        'territoryBroad': ?territoryBroad,
        'createdAt': Timestamp.fromDate(on ?? DateTime.now()),
      });

  Future<void> addStats({String uid = 'me'}) =>
      db.collection('userStats').doc(uid).set({
        'bestOverall': {
          'maxDistanceMeters': 12000,
          'maxDurationMs': 3600000,
          'maxSpeedKmh': 18.0,
          'maxAvgSpeedKmh': 11.0,
        },
      });

  Future<void> pumpHome(WidgetTester tester, {MockFirebaseAuth? withAuth}) async {
    await mockNetworkImagesFor(() async {
      await pumpDashWidget(
        tester,
        HomePage(firestore: db, auth: withAuth ?? auth, badgeService: badges),
        wrapInScaffold: false,
        // Generously wide: the home screen packs several labelled stat cards
        // into rows that fit a phone at real font metrics but not at the
        // test font's ~1 em per character. See TEST_NOTES 1.2.
        surfaceSize: const Size(1000, 2000),
      );
      // Fixed pumps rather than `pumpAndSettle` — the carousel and the
      // embedded cards keep animations running, so settling never returns.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
    });

    // `WearBridge` is an app-lifetime singleton that `HomePage.initState`
    // starts, opening a 1-second periodic timer nothing cancels — by design,
    // since it outlives any one screen. `flutter_test` fails a test that
    // ends with a pending timer, so it is stopped here, *inside the test
    // body*: `addTearDown` runs after the framework's invariant check, which
    // is too late. Same pattern as `register_page_test.dart`.
    WearBridge.instance.dispose();
  }

  group('the greeting', () {
    testWidgets('uses the username from the profile', (tester) async {
      await addProfile(username: 'Ada');

      await pumpHome(tester);

      expect(find.textContaining('Ada'), findsWidgets);
    });

    testWidgets('updates when the profile changes', (tester) async {
      await addProfile(username: 'Ada');
      await pumpHome(tester);

      await addProfile(username: 'Adalovelace');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.textContaining('Adalovelace'), findsWidgets);
    });

    testWidgets('a profile with no username does not blank the greeting',
        (tester) async {
      await addProfile(username: null);

      await pumpHome(tester);

      expect(tester.takeException(), isNull);
    });
  });

  group('leaderboard previews', () {
    testWidgets('the global board is always shown', (tester) async {
      await addProfile();
      await addStats();
      await addSession(points: 100, startLocality: 'Seregno');

      await pumpHome(tester);

      expect(find.text(LeaderboardOrder.globalTitle), findsWidgets);
    });

    testWidgets('a territory the runner scored in gets a card', (tester) async {
      await addProfile();
      await addStats();
      await addSession(points: 100, startLocality: 'Seregno');

      await pumpHome(tester);

      expect(find.textContaining('Seregno'), findsWidgets);
    });

    testWidgets('a run counts toward its metro area as well', (tester) async {
      // The same rule as the leaderboard page and the settings page — all
      // three read `leaderboardsForSession`, and they used to disagree.
      await addProfile();
      await addStats();
      await addSession(
        points: 100,
        startLocality: 'Seregno',
        territoryCity: 'Milano',
      );

      await pumpHome(tester);

      expect(find.textContaining('Seregno'), findsWidgets);
      expect(find.textContaining('Milano'), findsWidgets);
    });

    testWidgets('another runner\'s territory does not appear', (tester) async {
      await addProfile();
      await addStats();
      await addSession(userId: 'someone-else', startLocality: 'Reykjavik');

      await pumpHome(tester);

      expect(find.textContaining('Reykjavik'), findsNothing);
    });

    testWidgets('a session with no timestamp is ignored', (tester) async {
      await addProfile();
      await addStats();
      await db.collection('runningSessions').add({
        'userId': 'me',
        'pointsEarned': 50,
        'startLocality': 'Pending',
      });

      await pumpHome(tester);

      expect(find.textContaining('Pending'), findsNothing);
    });
  });

  group('monthly stats', () {
    testWidgets('average the last thirty days of running', (tester) async {
      // The cards show averages, not totals — 5 km and 3 km read as 4.0 km.
      await addProfile();
      await addStats();
      await addSession(distanceMeters: 5000, on: DateTime.now());
      await addSession(
        distanceMeters: 3000,
        on: DateTime.now().subtract(const Duration(days: 5)),
      );

      await pumpHome(tester);

      expect(find.text('4.0 km'), findsWidgets);
      expect(find.text('Previous 30 days: 0'), findsWidgets);
    });

    testWidgets('an older run is not counted in this month', (tester) async {
      // Asserting only that nothing threw passed against a deliberately
      // broken window that counted every run ever — see TEST_NOTES 1.18.
      // The recent run alone must set the average; the 45-day-old one
      // belongs to the previous period and would drag it to 7.0 km.
      await addProfile();
      await addStats();
      await addSession(distanceMeters: 5000, on: DateTime.now());
      await addSession(
        distanceMeters: 9000,
        on: DateTime.now().subtract(const Duration(days: 45)),
      );

      await pumpHome(tester);

      expect(find.text('5.0 km'), findsWidgets);
      expect(find.text('7.0 km'), findsNothing);
      expect(find.text('Previous 30 days: 1'), findsWidgets);
    });

    testWidgets('render with no runs at all', (tester) async {
      // A brand-new account: every average divides by zero unless guarded.
      await addProfile();
      await addStats();

      await pumpHome(tester);

      expect(tester.takeException(), isNull);
    });

    testWidgets('render with no userStats document', (tester) async {
      await addProfile();
      await addSession();

      await pumpHome(tester);

      expect(tester.takeException(), isNull);
    });
  });

  group('badges', () {
    testWidgets('are asked for, for the signed-in user', (tester) async {
      await addProfile();

      await pumpHome(tester);

      verify(badges.getHomeBadges('me')).called(1);
    });

    testWidgets('a failed badge read does not take the home screen down',
        (tester) async {
      // `_startBadgesStream` is `async void` here too — the same shape that
      // was an unhandled error in three other screens.
      when(badges.getHomeBadges(any))
          .thenAnswer((_) async => throw Exception('permission-denied'));
      await addProfile();

      await pumpHome(tester);

      expect(tester.takeException(), isNull);
      expect(find.byType(HomePage), findsOneWidget);
    });
  });

  group('signed out', () {
    testWidgets('opens no listeners and still renders', (tester) async {
      await addProfile();
      await addSession(points: 100, startLocality: 'Seregno');

      await pumpHome(tester, withAuth: MockFirebaseAuth());

      expect(tester.takeException(), isNull);
      expect(find.byType(HomePage), findsOneWidget);
    });
  });
}
