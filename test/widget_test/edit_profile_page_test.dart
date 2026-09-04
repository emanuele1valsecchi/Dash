import 'package:dash/config/app_theme.dart';
import 'package:dash/screens/edit_profile_page.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';

/// Editing your own profile: load the current values, edit, save.
///
/// **`profileImageUrl` is deliberately not written by the save.** The picture
/// is uploaded and persisted by `ImageUploadService` the moment the upload
/// succeeds — an earlier version showed a picked file locally and never
/// actually uploaded it. So a save that touched that field could overwrite a
/// freshly-uploaded picture with a stale URL, and one of the tests below pins
/// that it does not.
///
/// Picking an image itself is out of reach here: it goes through a static
/// method that needs a real photo picker.
void main() {
  late FakeFirebaseFirestore db;

  const me = 'runner-1';

  Future<void> seedProfile({
    String name = 'Andrea',
    String surname = 'Pinessi',
    String bio = 'Runner',
    String? imageUrl = 'https://example.invalid/me.png',
  }) =>
      db.collection('profiles').doc(me).set({
        'name': name,
        'surname': surname,
        'bio': bio,
        'profileImageUrl': imageUrl,
        'totalPoints': 0,
      });

  Future<Map<String, dynamic>> storedProfile() async =>
      (await db.collection('profiles').doc(me).get()).data()!;

  setUp(() {
    db = FakeFirebaseFirestore();
  });

  Future<void> pumpPage(WidgetTester tester, {bool signedIn = true}) async {
    tester.view.physicalSize = const Size(500, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    // Pushed as a second route rather than used as `home`, because a
    // successful save ends in `Navigator.pop` — which has nowhere to go from
    // the root route, and would swallow the confirmation with it. This is
    // also how the app actually opens the page.
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        // The route underneath needs its own Scaffold: a SnackBar is hosted by
        // the ScaffoldMessenger but re-parents to the nearest registered
        // Scaffold, and the success message is shown just before this page
        // pops. With a bare widget underneath there is nothing to re-parent
        // to and the confirmation vanishes. Every real caller is a Scaffold.
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => EditProfilePage(
                    firestore: db,
                    auth: signedIn
                        ? MockFirebaseAuth(
                            signedIn: true, mockUser: MockUser(uid: me))
                        : MockFirebaseAuth(),
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  /// The three text fields, in order: name, surname, bio.
  Finder fields() => find.byType(TextFormField);

  Future<void> save(WidgetTester tester) async {
    await tester.tap(find.byIcon(Symbols.check_rounded));
    await tester.pumpAndSettle();
  }

  group('loading the current profile', () {
    testWidgets('fills the fields from the stored document', (tester) async {
      await seedProfile();

      await pumpPage(tester);

      expect(find.text('Andrea'), findsOneWidget);
      expect(find.text('Pinessi'), findsOneWidget);
      expect(find.text('Runner'), findsOneWidget);
    });

    testWidgets('renders with no profile document rather than hanging',
        (tester) async {
      // A profile that has not been created yet must not leave the page stuck
      // on its loading spinner.
      await pumpPage(tester);

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(fields(), findsNWidgets(3));
    });

    testWidgets('handles missing fields on an older document',
        (tester) async {
      await db.collection('profiles').doc(me).set({'name': 'Andrea'});

      await pumpPage(tester);

      expect(tester.takeException(), isNull);
      expect(find.text('Andrea'), findsOneWidget);
    });

    testWidgets('does nothing when signed out', (tester) async {
      await seedProfile();

      await pumpPage(tester, signedIn: false);

      expect(find.text('Andrea'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('validation', () {
    testWidgets('name may not be emptied', (tester) async {
      await seedProfile();
      await pumpPage(tester);

      await tester.enterText(fields().at(0), '');
      await save(tester);

      expect(find.text('This field cannot be empty'), findsOneWidget);
    });

    testWidgets('surname may not be emptied', (tester) async {
      await seedProfile();
      await pumpPage(tester);

      await tester.enterText(fields().at(1), '');
      await save(tester);

      expect(find.text('This field cannot be empty'), findsOneWidget);
    });

    testWidgets('whitespace does not count as a value', (tester) async {
      await seedProfile();
      await pumpPage(tester);

      await tester.enterText(fields().at(0), '   ');
      await save(tester);

      expect(find.text('This field cannot be empty'), findsOneWidget);
    });

    testWidgets('the bio may be emptied', (tester) async {
      // Optional, unlike the other two.
      await seedProfile();
      await pumpPage(tester);

      await tester.enterText(fields().at(2), '');
      await save(tester);

      expect(find.text('This field cannot be empty'), findsNothing);
      expect((await storedProfile())['bio'], '');
    });

    testWidgets('an invalid form writes nothing', (tester) async {
      await seedProfile();
      await pumpPage(tester);

      await tester.enterText(fields().at(0), '');
      await tester.enterText(fields().at(1), 'Changed');
      await save(tester);

      // The whole save is gated on validation, so the valid field must not be
      // written either - a half-saved profile is worse than none.
      expect((await storedProfile())['surname'], 'Pinessi');
    });
  });

  group('saving', () {
    testWidgets('writes the edited values', (tester) async {
      await seedProfile();
      await pumpPage(tester);

      await tester.enterText(fields().at(0), 'Andi');
      await tester.enterText(fields().at(1), 'P');
      await tester.enterText(fields().at(2), 'Still running');
      await save(tester);

      final saved = await storedProfile();
      expect(saved['name'], 'Andi');
      expect(saved['surname'], 'P');
      expect(saved['bio'], 'Still running');
    });

    testWidgets('trims what it writes', (tester) async {
      await seedProfile();
      await pumpPage(tester);

      await tester.enterText(fields().at(0), '  Andi  ');
      await save(tester);

      expect((await storedProfile())['name'], 'Andi');
    });

    testWidgets('never touches profileImageUrl', (tester) async {
      // The picture is written by ImageUploadService as soon as the upload
      // succeeds. Writing it here too could overwrite a fresh URL with a
      // stale one held in this page's state.
      await seedProfile(imageUrl: 'https://example.invalid/fresh.png');
      await pumpPage(tester);

      await tester.enterText(fields().at(0), 'Andi');
      await save(tester);

      expect(
        (await storedProfile())['profileImageUrl'],
        'https://example.invalid/fresh.png',
      );
    });

    testWidgets('never touches totalPoints', (tester) async {
      // Server-only. `firestore.rules` would reject the write outright, so a
      // save that included it would fail entirely.
      await seedProfile();
      await pumpPage(tester);

      await tester.enterText(fields().at(0), 'Andi');
      await save(tester);

      expect((await storedProfile())['totalPoints'], 0);
    });

    testWidgets('confirms the save to the user', (tester) async {
      await seedProfile();
      await pumpPage(tester);

      await tester.enterText(fields().at(0), 'Andi');
      await save(tester);

      expect(find.text('Profile saved successfully!'), findsOneWidget);
      // And it leaves the page, so the caller can refresh behind it.
      expect(find.byType(EditProfilePage), findsNothing);
    });

    testWidgets('reports a failure rather than claiming success',
        (tester) async {
      // No profile document exists, so the batch `update` has nothing to
      // update and throws.
      await pumpPage(tester);

      await tester.enterText(fields().at(0), 'Andi');
      await tester.enterText(fields().at(1), 'P');
      await save(tester);

      expect(find.text('Profile saved successfully!'), findsNothing);
      expect(
        find.text('Error occurred while saving profile'),
        findsOneWidget,
      );
    });
  });
}
