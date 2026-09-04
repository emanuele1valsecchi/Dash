import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dash/services/user_appearance_service.dart';

/// The service exists to keep Firestore reads off the map. A viewport can
/// hold dozens of areas, several of them the same owner, so most of what
/// matters here is what it *avoids* fetching.
void main() {
  final service = UserAppearanceService.instance;
  late FakeFirebaseFirestore db;

  setUp(() {
    service.clearForTest();
    db = FakeFirebaseFirestore();
    service.firestoreOverride = db;
  });

  tearDown(service.clearForTest);

  Future<void> addProfile(
    String uid, {
    String? username,
    String? profileImageUrl,
    Object? areaColorIndex,
  }) =>
      db.collection('profiles').doc(uid).set({
        'username': ?username,
        'profileImageUrl': ?profileImageUrl,
        'areaColorIndex': ?areaColorIndex,
      });

  group('UserAppearance', () {
    test('the initial is the first letter of the username', () {
      const a = UserAppearance(
          uid: 'u', username: 'ada', photoUrl: null, colorIndex: null);

      expect(a.initial, 'A');
    });

    test('a missing username falls back to a question mark', () {
      // Signup is two steps: the auth account exists before the profile is
      // created, so a uid with no username is a normal transient state.
      const a = UserAppearance(
          uid: 'u', username: null, photoUrl: null, colorIndex: null);

      expect(a.initial, '?');
    });

    test('a blank username falls back too', () {
      const a = UserAppearance(
          uid: 'u', username: '   ', photoUrl: null, colorIndex: null);

      expect(a.initial, '?');
    });

    test('an empty photo url counts as no photo', () {
      const a = UserAppearance(
          uid: 'u', username: 'ada', photoUrl: '  ', colorIndex: null);

      expect(a.hasPhoto, isFalse);
    });

    test('a real photo url counts as one', () {
      const a = UserAppearance(
          uid: 'u',
          username: 'ada',
          photoUrl: 'https://example.com/a.png',
          colorIndex: 3);

      expect(a.hasPhoto, isTrue);
    });
  });

  group('loading', () {
    test('an unknown uid reads as null rather than blocking', () {
      // Callers render immediately and repaint when the data lands.
      expect(service.get('nobody'), isNull);
    });

    test('fetches and caches a profile', () async {
      await addProfile('ada', username: 'ada', areaColorIndex: 3);

      await service.ensureLoaded(['ada']);

      final a = service.get('ada')!;
      expect(a.username, 'ada');
      expect(a.colorIndex, 3);
    });

    test('fetches several uids in one go', () async {
      await addProfile('ada', username: 'ada');
      await addProfile('bob', username: 'bob');

      await service.ensureLoaded(['ada', 'bob']);

      expect(service.get('ada')!.username, 'ada');
      expect(service.get('bob')!.username, 'bob');
    });

    test('notifies listeners so the map repaints', () async {
      await addProfile('ada', username: 'ada');
      var notifications = 0;
      void listener() => notifications++;
      service.addListener(listener);
      addTearDown(() => service.removeListener(listener));

      await service.ensureLoaded(['ada']);

      expect(notifications, greaterThanOrEqualTo(1));
    });

    test('splits a request larger than the whereIn cap', () async {
      // Firestore rejects a `whereIn` of more than 30 values, so a bigger
      // request has to be split — otherwise the query throws and every
      // bubble in a busy viewport stays blank.
      final uids = [for (var i = 0; i < 75; i++) 'u$i'];
      for (final uid in uids) {
        await addProfile(uid, username: uid);
      }

      await service.ensureLoaded(uids);

      expect(service.get('u0')!.username, 'u0');
      expect(service.get('u74')!.username, 'u74');
    });

    test('an empty uid is skipped', () async {
      await service.ensureLoaded(['']);

      expect(service.get(''), isNull);
    });

    test('a failure leaves the map working rather than throwing', () async {
      // Callers already render correctly with no appearance, so this
      // degrades to hash colours and initial-less bubbles.
      service.firestoreOverride = null;

      await service.ensureLoaded(['ada']);

      expect(service.get('ada'), isNull);
    });
  });

  group('not fetching', () {
    test('a cached uid is not fetched again', () async {
      await addProfile('ada', username: 'ada');
      await service.ensureLoaded(['ada']);

      // Change the stored document; a second call must not pick it up,
      // which proves no second read happened.
      await addProfile('ada', username: 'changed');
      await service.ensureLoaded(['ada']);

      expect(service.get('ada')!.username, 'ada');
    });

    test('a uid with no profile is remembered as missing', () async {
      // A deleted account would otherwise be re-queried on every pan.
      await service.ensureLoaded(['ghost']);
      await addProfile('ghost', username: 'back from the dead');

      await service.ensureLoaded(['ghost']);

      expect(service.get('ghost'), isNull);
    });

    test('two concurrent requests for the same uid fetch once', () async {
      // Asserting the resulting username would be vacuous — it is correct
      // whether the second request was skipped or ran redundantly. The
      // observable difference is the notification: a deduplicated second
      // call finds nothing to want and returns without touching the cache,
      // so exactly one repaint should follow.
      await addProfile('ada', username: 'ada');
      var notifications = 0;
      void listener() => notifications++;
      service.addListener(listener);
      addTearDown(() => service.removeListener(listener));

      await Future.wait([
        service.ensureLoaded(['ada']),
        service.ensureLoaded(['ada']),
      ]);

      expect(service.get('ada')!.username, 'ada');
      expect(notifications, 1,
          reason: 'the in-flight request should have absorbed the second call');
    });

    test('a request for only known uids does no work at all', () async {
      await addProfile('ada', username: 'ada');
      await service.ensureLoaded(['ada']);
      var notifications = 0;
      void listener() => notifications++;
      service.addListener(listener);
      addTearDown(() => service.removeListener(listener));

      await service.ensureLoaded(['ada']);

      expect(notifications, 0);
    });
  });

  group('parsing', () {
    test('trims the username and photo url', () async {
      await addProfile('ada',
          username: '  ada  ', profileImageUrl: '  https://x/a.png  ');

      await service.ensureLoaded(['ada']);

      expect(service.get('ada')!.username, 'ada');
      expect(service.get('ada')!.photoUrl, 'https://x/a.png');
    });

    test('a missing colour index is null, which is a supported state',
        () async {
      // Profiles predating the field fall back to a uid hash in
      // `PlayerPalette`, so this is normal rather than an error.
      await addProfile('ada', username: 'ada');

      await service.ensureLoaded(['ada']);

      expect(service.get('ada')!.colorIndex, isNull);
    });

    test('a non-numeric colour index is ignored, not crashed on', () async {
      await addProfile('ada', username: 'ada', areaColorIndex: 'purple');

      await service.ensureLoaded(['ada']);

      expect(service.get('ada')!.colorIndex, isNull);
    });
  });

  group('invalidate', () {
    test('drops a uid so the next load re-reads it', () async {
      // For when the signed-in user changes their own picture or colour.
      await addProfile('ada', username: 'ada');
      await service.ensureLoaded(['ada']);
      await addProfile('ada', username: 'ada-renamed');

      service.invalidate('ada');
      await service.ensureLoaded(['ada']);

      expect(service.get('ada')!.username, 'ada-renamed');
    });

    test('clears a negative result too', () async {
      await service.ensureLoaded(['ghost']);
      await addProfile('ghost', username: 'now exists');

      service.invalidate('ghost');
      await service.ensureLoaded(['ghost']);

      expect(service.get('ghost')!.username, 'now exists');
    });

    test('invalidating an unknown uid notifies nobody', () async {
      var notifications = 0;
      void listener() => notifications++;
      service.addListener(listener);
      addTearDown(() => service.removeListener(listener));

      service.invalidate('never-seen');

      expect(notifications, 0);
    });
  });
}
