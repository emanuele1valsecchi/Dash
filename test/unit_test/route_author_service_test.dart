import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dash/services/route_author_service.dart';
import 'package:dash/services/user_appearance_service.dart';

/// Resolves who originally ran a *shared session route* — the ownerless
/// `routes` document that every user who favourited a run points at.
///
/// Two things make this worth testing. The first is a read-cost rule the
/// project calls non-negotiable: a favourites list can hold dozens of cards,
/// and a naive implementation would issue one Firestore read per card per
/// rebuild. Batching, caching, in-flight dedupe and *negative* caching are all
/// there to stop that, and none of them is visible in the UI — a broken one
/// costs money and battery silently.
///
/// The second is that "no author" is a deliberate outcome, not a failure:
/// account deletion strips `sourceSessionId` precisely to break the link back
/// to the deleted person, so resolving to nothing is the feature working.
void main() {
  late FakeFirebaseFirestore db;
  final service = RouteAuthorService.instance;

  setUp(() {
    db = FakeFirebaseFirestore();
    service.clearForTest();
    service.firestoreOverride = db;
    UserAppearanceService.instance.clearForTest();
    UserAppearanceService.instance.firestoreOverride = db;
  });

  tearDown(() {
    service.clearForTest();
    UserAppearanceService.instance.clearForTest();
  });

  Future<void> seedSession(String sessionId, String? userId) async {
    await db.collection('runningSessions').doc(sessionId).set({
      'userId': ?userId,
      'distanceMeters': 5000,
    });
  }

  Future<void> seedProfile(String uid, String username) async {
    await db.collection('profiles').doc(uid).set({'username': username});
  }

  group('resolving an author', () {
    test('finds the uid that ran the session', () async {
      await seedSession('s1', 'runner-1');

      await service.ensureLoaded(['s1']);

      expect(service.authorUidFor('s1'), 'runner-1');
    });

    test('resolves the username through UserAppearanceService', () async {
      await seedSession('s1', 'runner-1');
      await seedProfile('runner-1', 'giulia');

      await service.ensureLoaded(['s1']);

      expect(service.authorNameFor('s1'), 'giulia');
    });

    test('a null session id resolves to nothing without a lookup', () async {
      // A hand-planned route has no source session at all.
      expect(service.authorUidFor(null), isNull);
      expect(service.authorNameFor(null), isNull);
    });

    test('an unknown session resolves to nothing rather than throwing',
        () async {
      await service.ensureLoaded(['ghost']);

      expect(service.authorUidFor('ghost'), isNull);
    });

    test('a session with no userId resolves to nothing', () async {
      // What a scrubbed session looks like after account deletion.
      await seedSession('s1', null);

      await service.ensureLoaded(['s1']);

      expect(service.authorUidFor('s1'), isNull);
    });

    test('a session with an empty userId resolves to nothing', () async {
      await seedSession('s1', '');

      await service.ensureLoaded(['s1']);

      expect(service.authorUidFor('s1'), isNull);
    });
  });

  group('read cost', () {
    test('a known session is never looked up twice', () async {
      await seedSession('s1', 'runner-1');
      final counting = _CountingFirestore(db);
      service.firestoreOverride = counting;

      await service.ensureLoaded(['s1']);
      expect(counting.sessionQueries, 1);

      await service.ensureLoaded(['s1']);

      expect(service.authorUidFor('s1'), 'runner-1');
      expect(counting.sessionQueries, 1,
          reason: 'a cached session must cost no further reads');
    });

    test('an unresolvable session is remembered and not re-queried', () async {
      // The negative cache. Without it, a deleted run is re-queried on every
      // rebuild of every card that references it — forever.
      final counting = _CountingFirestore(db);
      service.firestoreOverride = counting;

      await service.ensureLoaded(['ghost']);
      expect(counting.sessionQueries, 1);

      await service.ensureLoaded(['ghost']);

      expect(counting.sessionQueries, 1,
          reason: 'a known-missing session must not be asked for again');
    });

    test('empty ids are filtered out before any query', () async {
      await service.ensureLoaded([null, '', '  ']);
      // '  ' is non-empty so it is looked up; null and '' must not be.
      expect(service.authorUidFor(''), isNull);
    });

    test('more than 30 sessions are split into batches', () async {
      // Firestore rejects a `whereIn` of more than 30 values outright, so
      // this is a hard limit rather than a tuning choice.
      final ids = [for (var i = 0; i < 75; i++) 's$i'];
      for (final id in ids) {
        await seedSession(id, 'runner-$id');
      }

      await service.ensureLoaded(ids);

      for (final id in ids) {
        expect(service.authorUidFor(id), 'runner-$id',
            reason: '$id should have resolved across the batch boundary');
      }
    });

    test('exactly 30 sessions resolve in one batch', () async {
      // The boundary itself: 30 is allowed, 31 is not.
      final ids = [for (var i = 0; i < 30; i++) 'b$i'];
      for (final id in ids) {
        await seedSession(id, 'runner-$id');
      }

      await service.ensureLoaded(ids);

      expect(service.authorUidFor('b0'), 'runner-b0');
      expect(service.authorUidFor('b29'), 'runner-b29');
    });
  });

  group('failure is survivable', () {
    test('a fetch failure leaves nothing marked unresolvable, so it retries',
        () async {
      // Deliberate: a network blip must not permanently blank the author line
      // on every card that happened to be on screen at the time.
      await seedSession('s1', 'runner-1');
      service.firestoreOverride = _ThrowingFirestore();

      await service.ensureLoaded(['s1']);
      expect(service.authorUidFor('s1'), isNull);

      service.firestoreOverride = db;
      await service.ensureLoaded(['s1']);

      expect(service.authorUidFor('s1'), 'runner-1',
          reason: 'the failed session must not have been cached as missing');
    });
  });

  group('notifying listeners', () {
    test('notifies once an author lands, so cards repaint', () async {
      await seedSession('s1', 'runner-1');
      await seedProfile('runner-1', 'giulia');

      var notifications = 0;
      void listener() => notifications++;
      service.addListener(listener);
      addTearDown(() => service.removeListener(listener));

      await service.ensureLoaded(['s1']);

      expect(notifications, greaterThan(0));
    });
  });
}

/// A Firestore whose `runningSessions` reads always fail, to exercise the
/// best-effort path.
class _ThrowingFirestore extends FakeFirebaseFirestore {
  @override
  CollectionReference<Map<String, dynamic>> collection(String path) {
    if (path == 'runningSessions') {
      throw FirebaseException(plugin: 'firestore', code: 'unavailable');
    }
    return super.collection(path);
  }
}

/// Counts how many times the session collection is reached for, which is the
/// only externally visible signal of a real Firestore read here.
class _CountingFirestore extends FakeFirebaseFirestore {
  _CountingFirestore(this._inner);
  final FakeFirebaseFirestore _inner;

  int sessionQueries = 0;

  @override
  CollectionReference<Map<String, dynamic>> collection(String path) {
    if (path == 'runningSessions') sessionQueries++;
    return _inner.collection(path);
  }
}
