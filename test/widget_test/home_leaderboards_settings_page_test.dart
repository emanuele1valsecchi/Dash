import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dash/screens/home_leaderboards_settings_page.dart';
import 'package:dash/utils/leaderboard_order.dart';

import '../helpers/pump_app.dart';

void main() {
  late FakeFirebaseFirestore db;
  late MockFirebaseAuth auth;

  const configKey = 'home_leaderboard_config';

  setUp(() {
    db = FakeFirebaseFirestore();
    auth = MockFirebaseAuth(
      signedIn: true,
      mockUser: MockUser(uid: 'me', email: 'me@example.com'),
    );
    SharedPreferences.setMockInitialValues({});
  });

  Future<void> addSession({
    String userId = 'me',
    String? startLocality,
    String? territoryCity,
    String? territoryBroad,
    required DateTime on,
  }) {
    return db.collection('runningSessions').add({
      'userId': userId,
      'startLocality': ?startLocality,
      'territoryCity': ?territoryCity,
      'territoryBroad': ?territoryBroad,
      'createdAt': Timestamp.fromDate(on),
    });
  }

  Future<void> pumpPage(WidgetTester tester, {MockFirebaseAuth? withAuth}) async {
    await pumpDashWidget(
      tester,
      HomeLeaderboardsSettingsPage(firestore: db, auth: withAuth ?? auth),
      wrapInScaffold: false,
      surfaceSize: kPhoneSurface,
    );
    await tester.pumpAndSettle();
  }

  Future<List<dynamic>> savedConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(configKey);
    return raw == null ? [] : jsonDecode(raw) as List;
  }

  /// The order the cards are actually drawn in, top to bottom.
  List<String> renderedOrder(WidgetTester tester) {
    final cards = tester.widgetList<Card>(find.byType(Card)).toList();
    return cards.map((c) => (c.key as ValueKey).value as String).toList();
  }

  group('which boards are offered', () {
    testWidgets('the global board is always there, even with no runs',
        (tester) async {
      await pumpPage(tester);

      expect(find.text(LeaderboardOrder.globalTitle), findsOneWidget);
    });

    testWidgets('a territory the runner has scored in is offered',
        (tester) async {
      await addSession(startLocality: 'Seregno', on: DateTime(2026, 3, 1));

      await pumpPage(tester);

      expect(find.text('Seregno'), findsOneWidget);
    });

    testWidgets('both the locality and the metro area are offered',
        (tester) async {
      // The same rule the home screen uses: a run counts toward both, so
      // settings must offer both or it would hide a board Home shows.
      await addSession(
        startLocality: 'Seregno',
        territoryCity: 'Milano',
        on: DateTime(2026, 3, 1),
      );

      await pumpPage(tester);

      expect(find.text('Seregno'), findsOneWidget);
      expect(find.text('Milano'), findsOneWidget);
    });

    testWidgets('another runner\'s territories are not offered',
        (tester) async {
      await addSession(
        userId: 'someone-else',
        startLocality: 'Reykjavik',
        on: DateTime(2026, 3, 1),
      );

      await pumpPage(tester);

      expect(find.text('Reykjavik'), findsNothing);
    });

    testWidgets('a session with no timestamp is skipped', (tester) async {
      await db.collection('runningSessions').add({
        'userId': 'me',
        'startLocality': 'Pending',
      });

      await pumpPage(tester);

      expect(find.text('Pending'), findsNothing);
    });

    testWidgets('signed out, only the saved config is shown', (tester) async {
      await addSession(startLocality: 'Seregno', on: DateTime(2026, 3, 1));

      await pumpPage(tester, withAuth: MockFirebaseAuth());

      expect(find.text('Seregno'), findsNothing);
    });
  });

  group('default order', () {
    testWidgets('global comes first, then the metro area', (tester) async {
      await addSession(
        startLocality: 'Seregno',
        territoryCity: 'Milano',
        on: DateTime(2026, 3, 1),
      );

      await pumpPage(tester);

      final order = renderedOrder(tester);
      expect(order.first, LeaderboardOrder.globalTitle);
      expect(order[1], 'Milano');
    });

    testWidgets('a broad region does not earn the promoted slot',
        (tester) async {
      // Only a curated metro polygon sets `territoryCity`; the broad-region
      // fallback is an ordinary entry.
      await addSession(
        startLocality: 'Bergamo',
        territoryBroad: 'Northern Lombardy',
        on: DateTime(2026, 3, 1),
      );

      await pumpPage(tester);

      final order = renderedOrder(tester);
      expect(order.first, LeaderboardOrder.globalTitle);
      expect(order, contains('Northern Lombardy'));
    });

    testWidgets('the most recently run territory comes before older ones',
        (tester) async {
      await addSession(startLocality: 'Older', on: DateTime(2026, 1, 1));
      await addSession(startLocality: 'Newer', on: DateTime(2026, 6, 1));

      await pumpPage(tester);

      final order = renderedOrder(tester);
      expect(order.indexOf('Newer'), lessThan(order.indexOf('Older')));
    });

    testWidgets('a territory run twice is listed once, at its latest run',
        (tester) async {
      await addSession(startLocality: 'Twice', on: DateTime(2026, 1, 1));
      await addSession(startLocality: 'Once', on: DateTime(2026, 3, 1));
      await addSession(startLocality: 'Twice', on: DateTime(2026, 6, 1));

      await pumpPage(tester);

      expect(find.text('Twice'), findsOneWidget);
      final order = renderedOrder(tester);
      expect(order.indexOf('Twice'), lessThan(order.indexOf('Once')));
    });
  });

  group('the saved config wins', () {
    testWidgets('a stored order is used instead of the default',
        (tester) async {
      SharedPreferences.setMockInitialValues({
        configKey: jsonEncode([
          {'title': 'Seregno', 'isVisible': true},
          {'title': LeaderboardOrder.globalTitle, 'isVisible': true},
        ]),
      });
      await addSession(startLocality: 'Seregno', on: DateTime(2026, 3, 1));

      await pumpPage(tester);

      expect(renderedOrder(tester).first, 'Seregno');
    });

    testWidgets('a newly discovered territory is appended, not lost',
        (tester) async {
      SharedPreferences.setMockInitialValues({
        configKey: jsonEncode([
          {'title': LeaderboardOrder.globalTitle, 'isVisible': true},
        ]),
      });
      await addSession(startLocality: 'Brand New', on: DateTime(2026, 3, 1));

      await pumpPage(tester);

      expect(find.text('Brand New'), findsOneWidget);
      expect(renderedOrder(tester).first, LeaderboardOrder.globalTitle);
    });

    testWidgets('a hidden board stays hidden across a reopen', (tester) async {
      SharedPreferences.setMockInitialValues({
        configKey: jsonEncode([
          {'title': LeaderboardOrder.globalTitle, 'isVisible': true},
          {'title': 'Seregno', 'isVisible': false},
        ]),
      });
      await addSession(startLocality: 'Seregno', on: DateTime(2026, 3, 1));

      await pumpPage(tester);

      expect(find.text('Hidden'), findsOneWidget);
    });
  });

  group('toggling visibility', () {
    testWidgets('hiding a board persists immediately', (tester) async {
      await addSession(startLocality: 'Seregno', on: DateTime(2026, 3, 1));
      await pumpPage(tester);

      // The first switch belongs to Global and is disabled; Seregno's is next.
      await tester.tap(find.byType(Switch).at(1));
      await tester.pumpAndSettle();

      final saved = await savedConfig();
      final seregno = saved.firstWhere((e) => e['title'] == 'Seregno');
      expect(seregno['isVisible'], isFalse);
    });

    testWidgets('the row says Hidden once it is off', (tester) async {
      await addSession(startLocality: 'Seregno', on: DateTime(2026, 3, 1));
      await pumpPage(tester);
      expect(find.text('Visible on Home'), findsOneWidget);

      await tester.tap(find.byType(Switch).at(1));
      await tester.pumpAndSettle();

      expect(find.text('Hidden'), findsOneWidget);
    });

    testWidgets('the global board cannot be hidden', (tester) async {
      // It is the one board every user shares; hiding it would leave someone
      // with no leaderboard at all on a fresh account.
      await pumpPage(tester);

      final globalSwitch = tester.widget<Switch>(find.byType(Switch).first);
      expect(globalSwitch.onChanged, isNull);
      expect(globalSwitch.value, isTrue);
      expect(find.text('Always visible'), findsOneWidget);
    });
  });

  group('reordering', () {
    testWidgets('is persisted', (tester) async {
      await addSession(startLocality: 'Seregno', on: DateTime(2026, 3, 1));
      await addSession(startLocality: 'Bergamo', on: DateTime(2026, 1, 1));
      await pumpPage(tester);
      expect(renderedOrder(tester), [
        LeaderboardOrder.globalTitle,
        'Seregno',
        'Bergamo',
      ]);

      // A plain `tester.drag` does nothing here: on mobile
      // `ReorderableListView` starts a reorder from a *long press*, so the
      // gesture has to be held before it moves. The distance is measured
      // rather than guessed, so a card's height can change without silently
      // turning this into a no-op that still passes.
      final from = tester.getCenter(find.text('Bergamo'));
      final to = tester.getCenter(find.text('Seregno'));
      final gesture = await tester.startGesture(from);
      await tester.pump(kLongPressTimeout + kPressTimeout);
      await gesture.moveBy(const Offset(0, -20));
      await tester.pump();
      await gesture.moveBy(Offset(0, to.dy - from.dy + 20));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(renderedOrder(tester), [
        LeaderboardOrder.globalTitle,
        'Bergamo',
        'Seregno',
      ]);
      final saved = await savedConfig();
      expect(saved.map((e) => e['title']).toList(), [
        LeaderboardOrder.globalTitle,
        'Bergamo',
        'Seregno',
      ], reason: 'the new order is written through, not just drawn');
    });
    testWidgets('moving a board down works too', (tester) async {
      // Worth its own case: `onReorderItem` (the replacement for the
      // deprecated `onReorder`) already adjusts `newIndex` for the removed
      // item, and this screen *also* does `if (newIndex > oldIndex)
      // newIndex -= 1`. A double adjustment would only show up on a
      // downward move — an upward one takes the untouched branch.
      await addSession(startLocality: 'Seregno', on: DateTime(2026, 3, 1));
      await addSession(startLocality: 'Bergamo', on: DateTime(2026, 1, 1));
      await pumpPage(tester);
      expect(renderedOrder(tester), [
        LeaderboardOrder.globalTitle,
        'Seregno',
        'Bergamo',
      ]);

      final from = tester.getCenter(find.text('Seregno'));
      final to = tester.getCenter(find.text('Bergamo'));
      final gesture = await tester.startGesture(from);
      await tester.pump(kLongPressTimeout + kPressTimeout);
      final total = to.dy - from.dy + 10;
      for (var i = 0; i < 10; i++) {
        await gesture.moveBy(Offset(0, total / 10));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await gesture.up();
      await tester.pumpAndSettle();

      expect(renderedOrder(tester), [
        LeaderboardOrder.globalTitle,
        'Bergamo',
        'Seregno',
      ]);
    });

  });

  group('chrome', () {
    testWidgets('is titled and explains what to do', (tester) async {
      await pumpPage(tester);

      expect(find.text('Customize Home'), findsOneWidget);
      expect(find.textContaining('Drag to reorder'), findsOneWidget);
    });
  });
}
