import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dash/screens/leaderboard_page.dart';

import '../helpers/pump_app.dart';

void main() {
  late FakeFirebaseFirestore db;
  late MockFirebaseAuth auth;

  setUp(() {
    db = FakeFirebaseFirestore();
    auth = MockFirebaseAuth(
      signedIn: true,
      mockUser: MockUser(uid: 'me', email: 'me@example.com'),
    );
  });

  Future<void> addSession({
    required String userId,
    required int points,
    String? startLocality,
    String? territoryCity,
    String? territoryBroad,
  }) {
    return db.collection('runningSessions').add({
      'userId': userId,
      'pointsEarned': points,
      'startLocality': ?startLocality,
      'territoryCity': ?territoryCity,
      'territoryBroad': ?territoryBroad,
    });
  }

  Future<void> addProfile(String uid, String name, String surname) =>
      db.collection('profiles').doc(uid).set({
        'name': name,
        'surname': surname,
        'profileImageUrl': '',
      });

  Future<void> pumpBoard(WidgetTester tester, String cityFilter) async {
    await pumpDashWidget(
      tester,
      LeaderboardScreen(cityFilter: cityFilter, firestore: db, auth: auth),
      wrapInScaffold: false,
    );
    await tester.pumpAndSettle();
  }

  group('global board', () {
    testWidgets('ranks runners by their total points', (tester) async {
      await addProfile('a', 'ada', 'lovelace');
      await addProfile('b', 'bob', 'ross');
      await addSession(userId: 'a', points: 100, startLocality: 'Seregno');
      await addSession(userId: 'b', points: 300, startLocality: 'Bergamo');

      await pumpBoard(tester, 'Global Leaderboard');

      expect(find.text('Bob Ross'), findsOneWidget);
      expect(find.text('300 pt'), findsWidgets);
      expect(find.text('Ada Lovelace'), findsOneWidget);
    });

    testWidgets('sums every session a runner logged', (tester) async {
      await addProfile('a', 'ada', 'lovelace');
      await addSession(userId: 'a', points: 100, startLocality: 'Seregno');
      await addSession(userId: 'a', points: 250, startLocality: 'Milano');

      await pumpBoard(tester, 'Global Leaderboard');

      expect(find.text('350 pt'), findsWidgets);
    });

    testWidgets('counts every locality, filtering nothing out',
        (tester) async {
      await addProfile('a', 'ada', 'lovelace');
      await addProfile('b', 'bob', 'ross');
      await addSession(userId: 'a', points: 10, startLocality: 'Seregno');
      await addSession(userId: 'b', points: 20, startLocality: 'Reykjavik');

      await pumpBoard(tester, 'Global Leaderboard');

      expect(find.text('Ada Lovelace'), findsOneWidget);
      expect(find.text('Bob Ross'), findsOneWidget);
    });

    testWidgets('offers no button back to itself', (tester) async {
      await pumpBoard(tester, 'Global Leaderboard');

      expect(find.byTooltip('Global Leaderboard'), findsNothing);
    });
  });

  group('city board', () {
    testWidgets('keeps only runners who ran there', (tester) async {
      await addProfile('a', 'ada', 'lovelace');
      await addProfile('b', 'bob', 'ross');
      await addSession(userId: 'a', points: 100, startLocality: 'Seregno');
      await addSession(userId: 'b', points: 300, startLocality: 'Bergamo');

      await pumpBoard(tester, 'Seregno');

      expect(find.text('Ada Lovelace'), findsOneWidget);
      expect(find.text('Bob Ross'), findsNothing);
    });

    testWidgets('counts only that board\'s sessions toward the total',
        (tester) async {
      await addProfile('a', 'ada', 'lovelace');
      await addSession(userId: 'a', points: 100, startLocality: 'Seregno');
      await addSession(userId: 'a', points: 900, startLocality: 'Bergamo');

      await pumpBoard(tester, 'Seregno');

      expect(find.text('100 pt'), findsWidgets);
      expect(find.text('1000 pt'), findsNothing);
    });

    testWidgets('ranks descending, so the lowest scorer is last',
        (tester) async {
      // With only two or three runners everyone lands on the podium and
      // nothing on screen states an order. Four is the smallest board where
      // the ranking is actually asserted rather than assumed.
      await addProfile('a', 'ada', 'lovelace');
      await addProfile('b', 'bob', 'ross');
      await addProfile('c', 'cleo', 'nile');
      await addProfile('d', 'dan', 'last');
      await addSession(userId: 'a', points: 400, startLocality: 'Seregno');
      await addSession(userId: 'b', points: 300, startLocality: 'Seregno');
      await addSession(userId: 'c', points: 200, startLocality: 'Seregno');
      await addSession(userId: 'd', points: 100, startLocality: 'Seregno');

      await pumpBoard(tester, 'Seregno');

      // Ranks 1-3 are the podium; the fourth is the only row in the list.
      final fourthRow = find.ancestor(
        of: find.text('#4'),
        matching: find.byType(InkWell),
      );
      expect(fourthRow, findsOneWidget);
      expect(
        find.descendant(of: fourthRow, matching: find.text('Dan Last')),
        findsOneWidget,
        reason: 'the fewest points must rank last, not first',
      );
    });

    testWidgets('titles itself after the city', (tester) async {
      await pumpBoard(tester, 'Seregno');

      expect(find.text('Seregno Leaderboard'), findsOneWidget);
    });
  });

  group('a run counts toward its metro area as well as its locality', () {
    // The bug this page had the worst copy of: the home screen derives the
    // `cityFilter` correctly, so a session inside a curated polygon computed
    // its village name, never matched the metro filter, and the board came up
    // empty. A session must match when *either* board does.
    testWidgets('a Seregno run appears on the Milano board', (tester) async {
      await addProfile('a', 'ada', 'lovelace');
      await addSession(
        userId: 'a',
        points: 100,
        startLocality: 'Seregno',
        territoryCity: 'Milano',
      );

      await pumpBoard(tester, 'Milano');

      expect(find.text('Ada Lovelace'), findsOneWidget);
    });

    testWidgets('and on the Seregno board too', (tester) async {
      await addProfile('a', 'ada', 'lovelace');
      await addSession(
        userId: 'a',
        points: 100,
        startLocality: 'Seregno',
        territoryCity: 'Milano',
      );

      await pumpBoard(tester, 'Seregno');

      expect(find.text('Ada Lovelace'), findsOneWidget);
    });

    testWidgets('the broad region is used when no city polygon matched',
        (tester) async {
      // Outside every curated polygon the runner still has to appear
      // somewhere — that fallback was once unused, so they appeared nowhere.
      await addProfile('a', 'ada', 'lovelace');
      await addSession(
        userId: 'a',
        points: 100,
        startLocality: 'Bergamo',
        territoryBroad: 'Northern Lombardy',
      );

      await pumpBoard(tester, 'Northern Lombardy');

      expect(find.text('Ada Lovelace'), findsOneWidget);
    });

    testWidgets('a curated city wins over the broad region', (tester) async {
      await addProfile('a', 'ada', 'lovelace');
      await addSession(
        userId: 'a',
        points: 100,
        startLocality: 'Seregno',
        territoryCity: 'Milano',
        territoryBroad: 'Lombardia',
      );

      await pumpBoard(tester, 'Lombardia');

      expect(find.text('Ada Lovelace'), findsNothing);
    });
  });

  group('the signed-in runner', () {
    testWidgets('gets a sticky bar of their own', (tester) async {
      await addProfile('me', 'ada', 'lovelace');
      await addProfile('b', 'bob', 'ross');
      await addSession(userId: 'me', points: 10, startLocality: 'Seregno');
      await addSession(userId: 'b', points: 900, startLocality: 'Seregno');

      await pumpBoard(tester, 'Seregno');

      // Once in the list, once in the sticky bar pinned to the bottom.
      expect(find.text('Ada Lovelace'), findsNWidgets(2));
    });

    testWidgets('has no bar when they are not on this board', (tester) async {
      await addProfile('b', 'bob', 'ross');
      await addSession(userId: 'b', points: 900, startLocality: 'Seregno');

      await pumpBoard(tester, 'Seregno');

      expect(find.text('Bob Ross'), findsOneWidget);
    });
  });

  group('missing data', () {
    testWidgets('a runner with no profile still ranks, as Unknown',
        (tester) async {
      // The profile read is a separate document; a deleted account must not
      // take the whole board down with it.
      await addSession(userId: 'ghost', points: 50, startLocality: 'Seregno');

      await pumpBoard(tester, 'Seregno');

      expect(find.text('Unknown'), findsWidgets);
      expect(find.text('50 pt'), findsWidgets);
    });

    testWidgets('a session with no user is skipped', (tester) async {
      await db.collection('runningSessions').add({
        'pointsEarned': 100,
        'startLocality': 'Seregno',
      });

      await pumpBoard(tester, 'Seregno');

      expect(find.text('100 pt'), findsNothing);
    });

    testWidgets('a session not yet scored counts as zero, not as an error',
        (tester) async {
      // `pointsEarned` is written by the Cloud Function; between the client
      // create and that write it is genuinely absent.
      await addProfile('a', 'ada', 'lovelace');
      await db.collection('runningSessions').add({
        'userId': 'a',
        'startLocality': 'Seregno',
      });

      await pumpBoard(tester, 'Seregno');

      expect(find.text('Ada Lovelace'), findsOneWidget);
      expect(find.text('0 pt'), findsWidgets);
    });

    testWidgets('an empty board renders without a podium', (tester) async {
      await pumpBoard(tester, 'Nowhere');

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.textContaining(' pt'), findsNothing);
    });
  });

  group('navigation', () {
    testWidgets('a city board offers a jump to the global one', (tester) async {
      await addProfile('a', 'ada', 'lovelace');
      await addSession(userId: 'a', points: 10, startLocality: 'Bergamo');

      await pumpBoard(tester, 'Seregno');
      expect(find.text('Ada Lovelace'), findsNothing);

      await tester.tap(find.byTooltip('Global Leaderboard'));
      await tester.pumpAndSettle();

      // The replacement screen keeps the injected seams — without forwarding
      // them it would reach for the real Firebase and show nothing.
      expect(find.text('Global Leaderboard'), findsOneWidget);
      expect(find.text('Ada Lovelace'), findsOneWidget);
    });
  });
}
