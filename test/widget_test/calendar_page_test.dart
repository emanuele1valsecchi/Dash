import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_image_mock/network_image_mock.dart';

import 'package:dash/screens/calendar_page.dart';
import 'package:dash/widgets/dash_run_card.dart';

import '../helpers/pump_app.dart';

void main() {
  late FakeFirebaseFirestore db;
  late MockFirebaseAuth auth;

  /// A fixed "today" the calendar's own default selection lands on, so a test
  /// never depends on the day it happens to be run.
  final today = DateTime.now();

  setUp(() {
    db = FakeFirebaseFirestore();
    auth = MockFirebaseAuth(
      signedIn: true,
      mockUser: MockUser(uid: 'me', email: 'me@example.com'),
    );
  });

  Future<void> addRun({
    String userId = 'me',
    required DateTime on,
    String name = 'Morning run',
    double distanceMeters = 5000,
    int durationMs = 1800000,
    bool withCreatedAt = true,
  }) {
    return db.collection('runningSessions').add({
      'userId': userId,
      'name': name,
      'distanceMeters': distanceMeters,
      'durationMs': durationMs,
      'avgPaceMinPerKm': 6.0,
      'loopsCompleted': 1,
      'totalAreaM2': 12000.0,
      'path': <GeoPoint>[],
      if (withCreatedAt) 'createdAt': Timestamp.fromDate(on),
    });
  }

  Future<void> pumpCalendar(WidgetTester tester) async {
    await mockNetworkImagesFor(() async {
      await pumpDashWidget(
        tester,
        CalendarScreen(firestore: db, auth: auth),
        wrapInScaffold: false,
        surfaceSize: kPhoneSurface,
      );
      await tester.pumpAndSettle();
    });
  }

  group('the selected day', () {
    testWidgets('opens on today and lists that day\'s runs', (tester) async {
      await addRun(on: today, name: 'Morning run');

      await pumpCalendar(tester);

      expect(find.text('Morning run'), findsOneWidget);
    });

    testWidgets('says so plainly when the day is empty', (tester) async {
      await addRun(on: today.subtract(const Duration(days: 3)));

      await pumpCalendar(tester);

      expect(find.text('No activities on this day'), findsOneWidget);
      expect(find.byType(DashRunCard), findsNothing);
    });

    testWidgets('lists every run from the same day', (tester) async {
      // Explicit hours on today's date: `today.add(hours)` rolls over into
      // tomorrow depending on what time the suite happens to run.
      final date = DateTime(today.year, today.month, today.day);
      await addRun(on: date.add(const Duration(hours: 7)), name: 'Morning run');
      await addRun(on: date.add(const Duration(hours: 19)), name: 'Evening run');

      await pumpCalendar(tester);

      expect(find.byType(DashRunCard), findsNWidgets(2));
    });

    testWidgets('groups by calendar day, not by timestamp', (tester) async {
      // Two runs hours apart on the same date belong to one day; the same
      // clock time on the next date does not.
      await addRun(
        on: DateTime(today.year, today.month, today.day, 6),
        name: 'Dawn run',
      );
      await addRun(
        on: DateTime(today.year, today.month, today.day, 22),
        name: 'Night run',
      );
      await addRun(
        on: DateTime(today.year, today.month, today.day, 6)
            .add(const Duration(days: 1)),
        name: 'Tomorrow run',
      );

      await pumpCalendar(tester);

      expect(find.byType(DashRunCard), findsNWidgets(2));
      expect(find.text('Tomorrow run'), findsNothing);
    });
  });

  group('whose runs are shown', () {
    testWidgets('only the signed-in user\'s', (tester) async {
      // The collection is readable by every signed-in user, so the filter is
      // what makes this "my history" rather than everyone's.
      await addRun(on: today, name: 'My run');
      await addRun(userId: 'someone-else', on: today, name: 'Their run');

      await pumpCalendar(tester);

      expect(find.text('My run'), findsOneWidget);
      expect(find.text('Their run'), findsNothing);
    });

    testWidgets('nothing at all when signed out', (tester) async {
      await addRun(on: today, name: 'Morning run');

      await mockNetworkImagesFor(() async {
        await pumpDashWidget(
          tester,
          CalendarScreen(firestore: db, auth: MockFirebaseAuth()),
          wrapInScaffold: false,
          surfaceSize: kPhoneSurface,
        );
        await tester.pumpAndSettle();
      });

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('No activities on this day'), findsOneWidget);
    });
  });

  group('incomplete data', () {
    testWidgets('a run with no server timestamp is skipped, not filed today',
        (tester) async {
      // `createdAt` is a server timestamp; between the write and its
      // resolution it reads back null, and a run with no day cannot be
      // placed on a calendar.
      await addRun(on: today, name: 'Pending run', withCreatedAt: false);

      await pumpCalendar(tester);

      expect(find.text('Pending run'), findsNothing);
      expect(find.text('No activities on this day'), findsOneWidget);
    });

    testWidgets('an unnamed run still appears', (tester) async {
      await db.collection('runningSessions').add({
        'userId': 'me',
        'createdAt': Timestamp.fromDate(today),
        'path': <GeoPoint>[],
      });

      await pumpCalendar(tester);

      expect(find.byType(DashRunCard), findsOneWidget);
      expect(find.text('Untitled run'), findsOneWidget);
    });

    testWidgets('an empty history is not an error state', (tester) async {
      await pumpCalendar(tester);

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('Your activities'), findsOneWidget);
      expect(find.text('No activities on this day'), findsOneWidget);
    });
  });

  group('chrome', () {
    testWidgets('is titled Calendar', (tester) async {
      await pumpCalendar(tester);

      expect(find.text('Calendar'), findsOneWidget);
    });

    testWidgets('heads the list with "Your activities"', (tester) async {
      await addRun(on: today);

      await pumpCalendar(tester);

      expect(find.text('Your activities'), findsOneWidget);
    });
  });
}
