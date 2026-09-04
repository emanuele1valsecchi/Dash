import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dash/root_screen.dart';
import 'package:dash/screens/notification_settings_page.dart';
import 'package:dash/screens/settings_page.dart';

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

  group('SettingsPage', () {
    Future<void> pumpSettings(WidgetTester tester,
        {MockFirebaseAuth? withAuth}) async {
      await pumpDashWidget(
        tester,
        SettingsPage(auth: withAuth ?? auth),
        wrapInScaffold: false,
        // Wide enough for the login screen this navigates to on logout,
        // which overflows a phone width at the test font. See TEST_NOTES 1.2.
        surfaceSize: const Size(900, 1600),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('lists every settings destination', (tester) async {
      await pumpSettings(tester);

      expect(find.text('Personal Information'), findsOneWidget);
      expect(find.text('Privacy Policy'), findsOneWidget);
      expect(find.text('Notifications'), findsOneWidget);
      expect(find.text('Map & Units'), findsOneWidget);
      expect(find.text('Home Leaderboards'), findsOneWidget);
      expect(find.text('Log out'), findsOneWidget);
    });

    testWidgets('logging out asks for confirmation first', (tester) async {
      await pumpSettings(tester);

      await tester.tap(find.text('Log out'));
      await tester.pumpAndSettle();

      expect(find.text('Are you sure you want to log out?'), findsOneWidget);
      expect(auth.currentUser, isNotNull, reason: 'not signed out yet');
    });

    testWidgets('cancelling leaves the user signed in', (tester) async {
      await pumpSettings(tester);
      await tester.tap(find.text('Log out'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(auth.currentUser, isNotNull);
    });

    testWidgets('confirming signs the user out', (tester) async {
      await pumpSettings(tester);
      await tester.tap(find.text('Log out'));
      await tester.pumpAndSettle();

      // The dialog's own "Log out" button, not the list tile behind it.
      await tester.tap(find.widgetWithText(TextButton, 'Log out'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(auth.currentUser, isNull);
    });

    testWidgets('a deliberate logout is flagged as such', (tester) async {
      // `RootScreen` watches the auth token and treats a *sudden* drop as a
      // session expiry. Without this flag a normal logout would look like
      // one.
      RootScreen.isIntentionalLogout = false;
      await pumpSettings(tester);
      await tester.tap(find.text('Log out'));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(TextButton, 'Log out'));
      await tester.pump();

      expect(RootScreen.isIntentionalLogout, isTrue);
      RootScreen.isIntentionalLogout = false;
    });
  });

  group('NotificationSettingsPage', () {
    Future<void> pumpNotifications(WidgetTester tester,
        {MockFirebaseAuth? withAuth}) async {
      await pumpDashWidget(
        tester,
        NotificationSettingsPage(firestore: db, auth: withAuth ?? auth),
        wrapInScaffold: false,
        // The switch rows carry a title and a sentence of subtitle; at the
        // test font's ~1 em per character they need more width than a phone
        // has. See TEST_NOTES 1.2.
        surfaceSize: const Size(900, 1600),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('every notification type can be toggled', (tester) async {
      await pumpNotifications(tester);

      expect(find.byType(SwitchListTile), findsNWidgets(8));
    });

    testWidgets('defaults to everything on', (tester) async {
      // A user who has never opened this page should still be notified.
      await pumpNotifications(tester);

      final switches = tester.widgetList<SwitchListTile>(
        find.byType(SwitchListTile),
      );
      expect(switches.every((s) => s.value), isTrue);
    });

    testWidgets('restores what was saved', (tester) async {
      await db.collection('profiles').doc('me').set({
        'pushPreferences': {'newFollower': false},
      });

      await pumpNotifications(tester);

      final tile = tester.widget<SwitchListTile>(
        find.ancestor(
          of: find.text('New Followers'),
          matching: find.byType(SwitchListTile),
        ),
      );
      expect(tile.value, isFalse);
    });

    testWidgets('an unknown saved key is ignored', (tester) async {
      // A preference from a newer or older build must not break the page.
      await db.collection('profiles').doc('me').set({
        'pushPreferences': {'somethingRemoved': false},
      });

      await pumpNotifications(tester);

      expect(find.byType(SwitchListTile), findsNWidgets(8));
    });

    testWidgets('turning one off saves it immediately', (tester) async {
      await pumpNotifications(tester);

      await tester.tap(find.ancestor(
        of: find.text('New Followers'),
        matching: find.byType(SwitchListTile),
      ));
      await tester.pumpAndSettle();

      final doc = await db.collection('profiles').doc('me').get();
      expect(doc.data()!['pushPreferences']['newFollower'], isFalse);
    });

    testWidgets('saving merges, so the rest of the profile survives',
        (tester) async {
      await db.collection('profiles').doc('me').set({'totalPoints': 4200});
      await pumpNotifications(tester);

      await tester.tap(find.ancestor(
        of: find.text('New Badges'),
        matching: find.byType(SwitchListTile),
      ));
      await tester.pumpAndSettle();

      final doc = await db.collection('profiles').doc('me').get();
      expect(doc.data()!['totalPoints'], 4200);
      expect(doc.data()!['pushPreferences']['badgeUnlocked'], isFalse);
    });

    testWidgets('one preference does not overwrite another', (tester) async {
      await pumpNotifications(tester);

      await tester.tap(find.ancestor(
        of: find.text('New Followers'),
        matching: find.byType(SwitchListTile),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.ancestor(
        of: find.text('New Badges'),
        matching: find.byType(SwitchListTile),
      ));
      await tester.pumpAndSettle();

      final saved =
          (await db.collection('profiles').doc('me').get())
              .data()!['pushPreferences'] as Map;
      expect(saved['newFollower'], isFalse);
      expect(saved['badgeUnlocked'], isFalse);
    });

    testWidgets('a signed-out user is not left on a spinner forever',
        (tester) async {
      await pumpNotifications(tester, withAuth: MockFirebaseAuth());

      expect(find.byType(CircularProgressIndicator), findsNothing);
    });
  });
}
