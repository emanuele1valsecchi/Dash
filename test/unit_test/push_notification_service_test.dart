import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dash/services/push_notification_service.dart';

/// Where an FCM device token gets written.
///
/// This is the only part of the service that is not platform plumbing, and
/// it is the part where a mistake is expensive: a token filed under the wrong
/// profile sends one user's push notifications to another user's phone, and
/// clobbering the array instead of appending to it silently unsubscribes
/// every other device that person owns. Neither shows up as an error.
///
/// `initialize()` is deliberately out of scope — it asks the OS for
/// permission, fetches a token from FCM and registers two platform-channel
/// listeners, none of which a unit test can drive. See the note in
/// TEST_NOTES.
void main() {
  late FakeFirebaseFirestore db;

  PushNotificationService serviceFor(MockFirebaseAuth auth) =>
      PushNotificationService(firestore: db, auth: auth);

  MockFirebaseAuth signedInAs(String uid) =>
      MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: uid));

  setUp(() {
    db = FakeFirebaseFirestore();
  });

  Future<List<dynamic>> tokensOf(String uid) async {
    final doc = await db.collection('profiles').doc(uid).get();
    return (doc.data()?['fcmTokens'] as List<dynamic>?) ?? const [];
  }

  group('saving a token', () {
    test('writes it onto the signed-in user\'s profile', () async {
      await serviceFor(signedInAs('me')).saveTokenToDatabase('token-a');

      expect(await tokensOf('me'), ['token-a']);
    });

    test('appends rather than replacing, so other devices keep working',
        () async {
      // arrayUnion, not a plain set. A user with a phone and a watch — or who
      // simply reinstalled — must not have the older device silently
      // unsubscribed by the newer one.
      final service = serviceFor(signedInAs('me'));

      await service.saveTokenToDatabase('phone-token');
      await service.saveTokenToDatabase('tablet-token');

      expect(await tokensOf('me'), ['phone-token', 'tablet-token']);
    });

    test('the same token twice does not accumulate duplicates', () async {
      // Every launch re-registers the same token; arrayUnion is what keeps
      // the array from growing without bound.
      final service = serviceFor(signedInAs('me'));

      await service.saveTokenToDatabase('token-a');
      await service.saveTokenToDatabase('token-a');

      expect(await tokensOf('me'), ['token-a']);
    });

    test('merges, so the rest of the profile survives', () async {
      // The profile document already holds server-owned fields the client is
      // forbidden from rewriting; a non-merging set here would destroy them.
      await db.collection('profiles').doc('me').set({
        'username': 'giulia',
        'totalPoints': 4200,
      });

      await serviceFor(signedInAs('me')).saveTokenToDatabase('token-a');

      final data = (await db.collection('profiles').doc('me').get()).data()!;
      expect(data['username'], 'giulia');
      expect(data['totalPoints'], 4200);
      expect(data['fcmTokens'], ['token-a']);
    });

    test('each user gets their own tokens, never another user\'s', () async {
      await serviceFor(signedInAs('alice')).saveTokenToDatabase('alice-phone');
      await serviceFor(signedInAs('bob')).saveTokenToDatabase('bob-phone');

      expect(await tokensOf('alice'), ['alice-phone']);
      expect(await tokensOf('bob'), ['bob-phone']);
    });
  });

  group('with nobody signed in', () {
    test('nothing is written at all', () async {
      // The guard that matters. Without it the write would either throw or,
      // worse, land somewhere unintended — and this runs during app startup,
      // before sign-in has necessarily completed.
      await serviceFor(MockFirebaseAuth()).saveTokenToDatabase('token-a');

      final profiles = await db.collection('profiles').get();
      expect(profiles.docs, isEmpty);
    });

    test('it returns quietly rather than throwing', () async {
      // `initialize()` awaits this on the startup path; throwing here would
      // surface as an unhandled async error during launch.
      await expectLater(
        serviceFor(MockFirebaseAuth()).saveTokenToDatabase('token-a'),
        completes,
      );
    });
  });

  group('when the write fails', () {
    test('the failure is swallowed rather than taking startup down',
        () async {
      // Deliberate: push notifications are an enhancement. Losing them must
      // not cost the user their session.
      final service = PushNotificationService(
        firestore: _ThrowingFirestore(),
        auth: signedInAs('me'),
      );

      await expectLater(service.saveTokenToDatabase('token-a'), completes);
    });
  });
}

/// A Firestore whose profile writes always fail.
class _ThrowingFirestore extends FakeFirebaseFirestore {
  @override
  CollectionReference<Map<String, dynamic>> collection(String path) {
    if (path == 'profiles') {
      throw FirebaseException(plugin: 'firestore', code: 'unavailable');
    }
    return super.collection(path);
  }
}
