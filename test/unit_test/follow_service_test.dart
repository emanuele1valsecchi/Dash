import 'package:dash/services/follow_service.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late FakeFirebaseFirestore db;
  late FollowService service;

  setUp(() async {
    db = FakeFirebaseFirestore();
    service = FollowService(db: db);

    // Both profiles must exist: the counter updates are `batch.update`, which
    // fails on a missing document rather than creating one.
    await db.collection('profiles').doc('me').set({
      'followingCount': 0,
      'followersCount': 0,
    });
    await db.collection('profiles').doc('them').set({
      'followingCount': 0,
      'followersCount': 0,
    });
  });

  Future<Map<String, dynamic>> profile(String uid) async =>
      (await db.collection('profiles').doc(uid).get()).data()!;

  Future<bool> linkExists() async =>
      (await db.collection('follows').doc('me_them').get()).exists;

  Future<void> follow() => service.toggleFollow(
        currentUserId: 'me',
        targetUserId: 'them',
        isCurrentlyFollowing: false,
      );

  Future<void> unfollow() => service.toggleFollow(
        currentUserId: 'me',
        targetUserId: 'them',
        isCurrentlyFollowing: true,
      );

  group('following someone', () {
    test('creates the follow link', () async {
      await follow();

      expect(await linkExists(), isTrue);
    });

    test('the link id is deterministic from the pair', () async {
      // follower_following. Deterministic so "am I following them" is a direct
      // document read rather than a query needing its own index.
      await follow();

      final doc = await db.collection('follows').doc('me_them').get();
      expect(doc.data()!['followerId'], 'me');
      expect(doc.data()!['followingId'], 'them');
    });

    test('increments my following count and their follower count', () async {
      await follow();

      expect((await profile('me'))['followingCount'], 1);
      expect((await profile('them'))['followersCount'], 1);
    });

    test('does not touch the counters that should not move', () async {
      await follow();

      expect((await profile('me'))['followersCount'], 0);
      expect((await profile('them'))['followingCount'], 0);
    });
  });

  group('unfollowing', () {
    test('removes the follow link', () async {
      await follow();
      await unfollow();

      expect(await linkExists(), isFalse);
    });

    test('decrements both counters', () async {
      await follow();
      await unfollow();

      expect((await profile('me'))['followingCount'], 0);
      expect((await profile('them'))['followersCount'], 0);
    });
  });

  test('a follow/unfollow round trip leaves no trace', () async {
    // The counters are FieldValue.increment deltas, so an asymmetry between
    // the two branches would slowly corrupt every profile in the app.
    await follow();
    await unfollow();
    await follow();
    await unfollow();

    expect(await linkExists(), isFalse);
    expect((await profile('me'))['followingCount'], 0);
    expect((await profile('them'))['followersCount'], 0);
  });

  test('following several people accumulates on one profile', () async {
    await db.collection('profiles').doc('third').set({
      'followingCount': 0,
      'followersCount': 0,
    });

    await follow();
    await service.toggleFollow(
      currentUserId: 'me',
      targetUserId: 'third',
      isCurrentlyFollowing: false,
    );

    expect((await profile('me'))['followingCount'], 2);
  });
}
