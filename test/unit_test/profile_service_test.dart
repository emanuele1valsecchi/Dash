import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dash/services/profile_service.dart';

/// The gateway every profile write goes through.
///
/// Two things here are worth more than the rest. `createProfile` writes with
/// `SetOptions(merge: true)` over a document the `seedUserProfileAndBadges`
/// Cloud Function created — so a full overwrite would destroy `totalPoints`,
/// which is server-owned and which `firestore.rules` forbids the client from
/// ever setting back. And `isProfileComplete` is what decides whether a user
/// is sent to the app or back into onboarding, so a wrong answer either
/// strands a finished account on the setup screen or lets a half-built one
/// through.
void main() {
  late FakeFirebaseFirestore db;
  late MockFirebaseAuth auth;
  late ProfileService service;

  ProfileService serviceFor(MockFirebaseAuth a) =>
      ProfileService(firestore: db, auth: a);

  setUp(() {
    db = FakeFirebaseFirestore();
    auth = MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: 'me'));
    service = serviceFor(auth);
  });

  Future<void> seedProfile(String uid, Map<String, dynamic> data) =>
      db.collection('profiles').doc(uid).set(data);

  group('fetchUsername', () {
    test('returns the username of any user, not just the current one', () async {
      // Used by the claimed-area sheet to name whoever owns a territory.
      await seedProfile('someone-else', {'username': 'giulia'});

      expect(await service.fetchUsername('someone-else'), 'giulia');
    });

    test('trims surrounding whitespace', () async {
      await seedProfile('u', {'username': '  giulia  '});

      expect(await service.fetchUsername('u'), 'giulia');
    });

    test('a missing profile resolves to null, not an error', () async {
      // Normal after an account deletion; the caller renders nothing.
      expect(await service.fetchUsername('ghost'), isNull);
    });

    test('a profile with no username resolves to null', () async {
      await seedProfile('u', {'name': 'Giulia'});

      expect(await service.fetchUsername('u'), isNull);
    });

    test('a whitespace-only username resolves to null', () async {
      // Otherwise the UI renders a blank name where it expects a real one.
      await seedProfile('u', {'username': '   '});

      expect(await service.fetchUsername('u'), isNull);
    });
  });

  group('isProfileComplete', () {
    test('true only when the flag and all three names are present', () async {
      await seedProfile('me', {
        'username': 'giulia',
        'name': 'Giulia',
        'surname': 'Rossi',
        'profileCompleted': true,
      });

      expect(await service.isProfileComplete(), isTrue);
    });

    test('false when the profile does not exist yet', () async {
      expect(await service.isProfileComplete(), isFalse);
    });

    test('false when profileCompleted is missing, even with every name',
        () async {
      await seedProfile('me', {
        'username': 'giulia',
        'name': 'Giulia',
        'surname': 'Rossi',
      });

      expect(await service.isProfileComplete(), isFalse);
    });

    test('false when profileCompleted is truthy but not literally true',
        () async {
      // Guards against a string 'true' or a 1 sneaking a half-built profile
      // through the onboarding gate.
      for (final value in <dynamic>['true', 1, 'yes']) {
        await seedProfile('me', {
          'username': 'giulia',
          'name': 'Giulia',
          'surname': 'Rossi',
          'profileCompleted': value,
        });

        expect(await service.isProfileComplete(), isFalse,
            reason: '$value should not count as completed');
      }
    });

    test('false when any one name is blank', () async {
      for (final blank in ['username', 'name', 'surname']) {
        await seedProfile('me', {
          'username': 'giulia',
          'name': 'Giulia',
          'surname': 'Rossi',
          'profileCompleted': true,
          blank: '   ',
        });

        expect(await service.isProfileComplete(), isFalse,
            reason: 'a blank $blank should not count as complete');
      }
    });
  });

  group('createProfile', () {
    test('does not destroy server-owned fields on the bootstrap doc',
        () async {
      // The reason this writes with merge. `totalPoints` and
      // `areaColorIndex` are written by `seedUserProfileAndBadges`, and the
      // client is forbidden from setting `totalPoints` at all — so an
      // overwrite here would be unrecoverable from the app.
      await seedProfile('me', {
        'totalPoints': 4200,
        'areaColorIndex': 7,
        'profileCompleted': false,
      });

      await service.createProfile(
        username: 'giulia', name: 'Giulia', surname: 'Rossi', bio: 'ciao',
      );

      final data = (await db.collection('profiles').doc('me').get()).data()!;
      expect(data['totalPoints'], 4200);
      expect(data['areaColorIndex'], 7);
    });

    test('trims every field it writes', () async {
      await service.createProfile(
        username: '  giulia  ', name: '  Giulia ', surname: ' Rossi  ',
        bio: '  ciao  ',
      );

      final data = (await db.collection('profiles').doc('me').get()).data()!;
      expect(data['username'], 'giulia');
      expect(data['name'], 'Giulia');
      expect(data['surname'], 'Rossi');
      expect(data['bio'], 'ciao');
    });

    test('marks the profile completed', () async {
      await service.createProfile(
        username: 'giulia', name: 'Giulia', surname: 'Rossi', bio: '',
      );

      final data = (await db.collection('profiles').doc('me').get()).data()!;
      expect(data['profileCompleted'], isTrue);
    });

    test('keeps an existing profile image when none is supplied', () async {
      // Editing a profile without picking a new photo must not blank the
      // one already there.
      await seedProfile('me', {'profileImageUrl': 'https://example/a.jpg'});

      await service.createProfile(
        username: 'giulia', name: 'Giulia', surname: 'Rossi', bio: '',
      );

      final data = (await db.collection('profiles').doc('me').get()).data()!;
      expect(data['profileImageUrl'], 'https://example/a.jpg');
    });

    test('writes an empty image url when there was no prior profile',
        () async {
      await service.createProfile(
        username: 'giulia', name: 'Giulia', surname: 'Rossi', bio: '',
      );

      final data = (await db.collection('profiles').doc('me').get()).data()!;
      expect(data['profileImageUrl'], '');
    });

    test('preserves existing follower and following counts', () async {
      // These are maintained elsewhere; resetting them on a profile edit
      // would silently wipe a user's social graph counters.
      await seedProfile('me', {'followersCount': 12, 'followingCount': 30});

      await service.createProfile(
        username: 'giulia', name: 'Giulia', surname: 'Rossi', bio: '',
      );

      final data = (await db.collection('profiles').doc('me').get()).data()!;
      expect(data['followersCount'], 12);
      expect(data['followingCount'], 30);
    });

    test('defaults the counts to zero for a brand new profile', () async {
      await service.createProfile(
        username: 'giulia', name: 'Giulia', surname: 'Rossi', bio: '',
      );

      final data = (await db.collection('profiles').doc('me').get()).data()!;
      expect(data['followersCount'], 0);
      expect(data['followingCount'], 0);
    });
  });

  group('nicknames', () {
    test('saveNickname claims the trimmed name for the current user',
        () async {
      await service.saveNickname('  giulia  ');

      final doc = await db.collection('nicknames').doc('giulia').get();
      expect(doc.exists, isTrue);
      expect(doc.data()!['uid'], 'me');
    });

    test('isUsernameTaken sees a claimed nickname', () async {
      await db.collection('nicknames').doc('giulia').set({'uid': 'someone'});

      expect(await service.isUsernameTaken('giulia'), isTrue);
    });

    test('isUsernameTaken is false for a free nickname', () async {
      expect(await service.isUsernameTaken('giulia'), isFalse);
    });

    test('isUsernameTaken trims before checking', () async {
      // Otherwise '  giulia  ' reads as free and two users claim one name,
      // with the second write overwriting the first's ownership record.
      await db.collection('nicknames').doc('giulia').set({'uid': 'someone'});

      expect(await service.isUsernameTaken('  giulia  '), isTrue);
    });
  });

  group('with nobody signed in', () {
    test('the self-scoped reads throw rather than reading another document',
        () async {
      // `_uid` force-unwraps `currentUser`. Documented here rather than
      // called a bug: throwing is the safe direction — the alternative would
      // be resolving to some other document path. Every caller reaches these
      // from behind an auth gate.
      final signedOut = serviceFor(MockFirebaseAuth());

      expect(signedOut.isProfileComplete(), throwsA(isA<TypeError>()));
      expect(signedOut.getProfileDoc(), throwsA(isA<TypeError>()));
    });

    test('fetchUsername still works, since it takes an explicit uid',
        () async {
      // It is used to name other people, so it must not depend on a session.
      await seedProfile('someone', {'username': 'giulia'});
      final signedOut = serviceFor(MockFirebaseAuth());

      expect(await signedOut.fetchUsername('someone'), 'giulia');
    });
  });
}
