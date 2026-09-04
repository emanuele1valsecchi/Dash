import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_image_mock/network_image_mock.dart';

import 'package:dash/screens/setup_profile_page.dart';

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

  Future<void> pumpPage(WidgetTester tester, {MockFirebaseAuth? withAuth}) async {
    await mockNetworkImagesFor(() async {
      await pumpDashWidget(
        tester,
        SetupProfileScreen(
          firestore: db,
          auth: withAuth ?? auth,
          // `RootScreen` is the whole app shell and reaches for
          // `FirebaseAuth.instance` in `initState`, so it cannot be built
          // here. A stand-in makes the success path assertable, including
          // the fact that it navigates at all.
          // A Scaffold, not a bare Text: the success SnackBar is shown just
          // before the replacement, and a ScaffoldMessenger needs a Scaffold
          // on screen to render it.
          destinationBuilder: (_) =>
              const Scaffold(body: Text('SAVED — went home')),
        ),
        wrapInScaffold: false,
        surfaceSize: kPhoneSurface,
      );
      await tester.pumpAndSettle();
    });
  }

  /// Fills the form. The username is the only field the screen requires.
  Future<void> fillIn(
    WidgetTester tester, {
    String username = 'ada',
    String name = 'Ada',
    String surname = 'Lovelace',
    String bio = 'I run.',
  }) async {
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), username);
    await tester.enterText(fields.at(1), name);
    await tester.enterText(fields.at(2), surname);
    await tester.enterText(fields.at(3), bio);
    await tester.pump();
  }

  /// Taps Save and lets the commit and any navigation settle.
  Future<void> save(WidgetTester tester) async {
    await tester.tap(find.text('Setup your profile'));
    await tester.pumpAndSettle();
  }

  group('the form', () {
    testWidgets('offers a field for each part of the profile', (tester) async {
      await pumpPage(tester);

      expect(find.text('Username'), findsOneWidget);
      expect(find.text('Name'), findsOneWidget);
      // The word is both the label and the placeholder, hence two.
      expect(find.text('Surname'), findsNWidgets(2));
      expect(find.text('Bio'), findsOneWidget);
      expect(find.text('Setup your profile'), findsOneWidget);
    });

    testWidgets('starts from the photo the account already has',
        (tester) async {
      // A Google sign-in arrives with a photoURL; making the user re-pick it
      // would be pointless.
      await pumpPage(
        tester,
        withAuth: MockFirebaseAuth(
          signedIn: true,
          mockUser: MockUser(uid: 'me', photoURL: 'https://example.com/a.png'),
        ),
      );

      expect(find.text('Select Profile Picture'), findsOneWidget);
    });
  });

  group('validation', () {
    testWidgets('a missing username is refused before any write',
        (tester) async {
      await pumpPage(tester);
      await fillIn(tester, username: '');

      await save(tester);
      await tester.pump();

      expect(find.textContaining('enter a username'), findsOneWidget);
      expect((await db.collection('profiles').get()).docs, isEmpty);
      expect((await db.collection('nicknames').get()).docs, isEmpty);
    });

    testWidgets('whitespace is not a username', (tester) async {
      await pumpPage(tester);
      await fillIn(tester, username: '   ');

      await save(tester);
      await tester.pump();

      expect(find.textContaining('enter a username'), findsOneWidget);
      expect((await db.collection('nicknames').get()).docs, isEmpty);
    });

    testWidgets('a username already claimed is refused', (tester) async {
      // `nicknames/{name}` is the uniqueness index; the check is what stops
      // two accounts racing for the same handle.
      await db.collection('nicknames').doc('ada').set({'uid': 'someone-else'});
      await pumpPage(tester);
      await fillIn(tester, username: 'ada');

      await save(tester);
      await tester.pump();

      expect(find.textContaining('already taken'), findsOneWidget);
    });

    testWidgets('a taken username leaves the existing claim alone',
        (tester) async {
      await db.collection('nicknames').doc('ada').set({'uid': 'someone-else'});
      await pumpPage(tester);
      await fillIn(tester, username: 'ada');

      await save(tester);
      await tester.pump();

      final claim = await db.collection('nicknames').doc('ada').get();
      expect(claim.data()!['uid'], 'someone-else');
      expect((await db.collection('profiles').get()).docs, isEmpty);
    });
  });

  group('saving', () {
    testWidgets('writes the profile under the signed-in uid', (tester) async {
      await pumpPage(tester);
      await fillIn(tester);

      await save(tester);

      final profile = await db.collection('profiles').doc('me').get();
      expect(profile.exists, isTrue);
      expect(profile.data()!['username'], 'ada');
      expect(profile.data()!['name'], 'Ada');
      expect(profile.data()!['surname'], 'Lovelace');
      expect(profile.data()!['bio'], 'I run.');
    });

    testWidgets('claims the nickname in the same commit', (tester) async {
      await pumpPage(tester);
      await fillIn(tester, username: 'ada');

      await save(tester);

      final claim = await db.collection('nicknames').doc('ada').get();
      expect(claim.exists, isTrue);
    });

    testWidgets('the claim names the field the rules require', (tester) async {
      // `firestore.rules` checks `uid`, not `userId`. Writing the wrong key
      // is denied in production and would pass any test that only checked
      // the document exists.
      await pumpPage(tester);
      await fillIn(tester, username: 'ada');

      await save(tester);

      final claim = await db.collection('nicknames').doc('ada').get();
      expect(claim.data(), {'uid': 'me'});
    });

    testWidgets('trims every field', (tester) async {
      await pumpPage(tester);
      await fillIn(
        tester,
        username: '  ada  ',
        name: '  Ada  ',
        surname: '  Lovelace  ',
        bio: '  I run.  ',
      );

      await save(tester);

      final profile = await db.collection('profiles').doc('me').get();
      expect(profile.data()!['username'], 'ada');
      expect(profile.data()!['name'], 'Ada');
      expect(profile.data()!['surname'], 'Lovelace');
      expect(profile.data()!['bio'], 'I run.');
      expect((await db.collection('nicknames').doc('ada').get()).exists, isTrue,
          reason: 'the claim uses the trimmed name too');
    });

    testWidgets('merges rather than replacing an existing profile',
        (tester) async {
      // The profile doc already exists — `seedUserProfileAndBadges` creates it
      // on signup — and carries server-only fields. A plain set would wipe
      // totalPoints and the FCM tokens.
      await db.collection('profiles').doc('me').set({
        'totalPoints': 4200,
        'fcmTokens': ['token-1'],
      });
      await pumpPage(tester);
      await fillIn(tester);

      await save(tester);

      final profile = await db.collection('profiles').doc('me').get();
      expect(profile.data()!['totalPoints'], 4200);
      expect(profile.data()!['fcmTokens'], ['token-1']);
      expect(profile.data()!['username'], 'ada');
    });

    testWidgets('omits the image url when there is none', (tester) async {
      // Writing an empty string would overwrite a picture uploaded moments
      // earlier by `ProfileAvatarWidget`, which writes it directly.
      //
      // The empty string is how "no photo" has to be expressed here:
      // `MockUser.photoURL` substitutes a stock placeholder URL when it is
      // null, so a null-photo account cannot be built with this library.
      await pumpPage(
        tester,
        withAuth: MockFirebaseAuth(
          signedIn: true,
          mockUser: MockUser(uid: 'me', photoURL: ''),
        ),
      );
      await fillIn(tester);

      await save(tester);

      final profile = await db.collection('profiles').doc('me').get();
      expect(profile.data()!.containsKey('profileImageUrl'), isFalse);
    });

    testWidgets('mirrors the account photo when there is one', (tester) async {
      await pumpPage(
        tester,
        withAuth: MockFirebaseAuth(
          signedIn: true,
          mockUser: MockUser(uid: 'me', photoURL: 'https://example.com/a.png'),
        ),
      );
      await fillIn(tester);

      await save(tester);

      final profile = await db.collection('profiles').doc('me').get();
      expect(profile.data()!['profileImageUrl'], 'https://example.com/a.png');
    });

    testWidgets('moves on into the app once saved', (tester) async {
      await pumpPage(tester);
      await fillIn(tester);

      await save(tester);

      expect(find.text('SAVED — went home'), findsOneWidget);
      expect(find.text('Setup your profile'), findsNothing,
          reason: 'replaced, not stacked — there is no going back to setup');
    });

    testWidgets('stays put when the username was taken', (tester) async {
      await db.collection('nicknames').doc('ada').set({'uid': 'someone-else'});
      await pumpPage(tester);
      await fillIn(tester, username: 'ada');

      await save(tester);

      expect(find.text('SAVED — went home'), findsNothing);
      expect(find.text('Setup your profile'), findsOneWidget);
    });

    testWidgets('confirms success to the user', (tester) async {
      await pumpPage(tester);
      await fillIn(tester);

      await save(tester);
      await tester.pump();

      expect(find.textContaining('Profile saved'), findsOneWidget);
    });
  });
}
