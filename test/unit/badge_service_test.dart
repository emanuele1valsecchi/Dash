import 'package:dash/services/badge_service.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late FakeFirebaseFirestore db;
  late BadgeService service;

  setUp(() {
    db = FakeFirebaseFirestore();
    service = BadgeService(firestore: db);
  });

  Future<void> defineBadge(String id, {required int order, String? title}) =>
      db.collection('badges').doc(id).set({
        'title': title ?? id,
        'description': 'about $id',
        'imagePath': '$id.png',
        'defaultVisible': true,
        'order': order,
        'requiredValue': 10,
      });

  Future<void> setProgress(
    String badgeId, {
    double progress = 0,
    bool unlocked = false,
  }) =>
      db
          .collection('profiles')
          .doc('runner-1')
          .collection('badge_progress')
          .doc(badgeId)
          .set({'progress': progress, 'unlocked': unlocked});

  group('getAllBadges', () {
    test('returns the shared badge definitions', () async {
      await defineBadge('duke', order: 1, title: 'Duke');

      final badges = await service.getAllBadges('runner-1');

      expect(badges.map((b) => b.title), ['Duke']);
      expect(badges.single.description, 'about duke');
    });

    test('merges the user\'s progress onto the definition', () async {
      await defineBadge('duke', order: 1);
      await setProgress('duke', progress: 0.4);

      final badge = (await service.getAllBadges('runner-1')).single;

      expect(badge.progress, 0.4);
      expect(badge.unlocked, isFalse);
    });

    test('marks an unlocked badge as unlocked', () async {
      await defineBadge('duke', order: 1);
      await setProgress('duke', progress: 1.0, unlocked: true);

      expect((await service.getAllBadges('runner-1')).single.unlocked, isTrue);
    });

    test('a badge with no progress row reads as locked at zero', () async {
      // The normal state for a badge the user has never touched - it must not
      // come back null or throw.
      await defineBadge('duke', order: 1);

      final badge = (await service.getAllBadges('runner-1')).single;
      expect(badge.progress, 0.0);
      expect(badge.unlocked, isFalse);
    });

    test('reads another user\'s progress, not only your own', () async {
      // PublicProfilePage shows someone else's badges; badge_progress is
      // signed-in-readable precisely so this works.
      await defineBadge('duke', order: 1);
      await db
          .collection('profiles')
          .doc('someone-else')
          .collection('badge_progress')
          .doc('duke')
          .set({'progress': 0.9, 'unlocked': false});

      final badge = (await service.getAllBadges('someone-else')).single;
      expect(badge.progress, 0.9);
    });

    test('returns empty when no badges are defined', () async {
      expect(await service.getAllBadges('runner-1'), isEmpty);
    });
  });

  group('ordering', () {
    // The sort is three-tier: in-progress first, then locked, then unlocked.
    // Earned badges sink to the bottom because the list is there to show you
    // what to chase next.
    test('in-progress badges come before untouched ones', () async {
      await defineBadge('started', order: 5);
      await defineBadge('untouched', order: 1);
      await setProgress('started', progress: 0.3);

      final badges = await service.getAllBadges('runner-1');

      expect(badges.map((b) => b.id), ['started', 'untouched']);
    });

    test('unlocked badges sink below everything else', () async {
      await defineBadge('done', order: 1);
      await defineBadge('untouched', order: 9);
      await setProgress('done', progress: 1.0, unlocked: true);

      final badges = await service.getAllBadges('runner-1');

      expect(badges.map((b) => b.id), ['untouched', 'done']);
    });

    test('among in-progress badges the closest to done comes first',
        () async {
      await defineBadge('nearly', order: 9);
      await defineBadge('barely', order: 1);
      await setProgress('nearly', progress: 0.9);
      await setProgress('barely', progress: 0.1);

      final badges = await service.getAllBadges('runner-1');

      expect(badges.map((b) => b.id), ['nearly', 'barely']);
    });

    test('untouched badges keep their defined order', () async {
      await defineBadge('third', order: 3);
      await defineBadge('first', order: 1);
      await defineBadge('second', order: 2);

      final badges = await service.getAllBadges('runner-1');

      expect(badges.map((b) => b.id), ['first', 'second', 'third']);
    });

    test('all three tiers sort together correctly', () async {
      await defineBadge('done', order: 1);
      await defineBadge('untouched', order: 2);
      await defineBadge('started', order: 3);
      await setProgress('done', progress: 1.0, unlocked: true);
      await setProgress('started', progress: 0.5);

      final badges = await service.getAllBadges('runner-1');

      expect(badges.map((b) => b.id), ['started', 'untouched', 'done']);
    });
  });

  group('getHomeBadges', () {
    test('takes the first five in the same order', () async {
      for (var i = 1; i <= 8; i++) {
        await defineBadge('badge$i', order: i);
      }

      final home = await service.getHomeBadges('runner-1');

      expect(home, hasLength(5));
      expect(home.first.id, 'badge1');
      expect(home.last.id, 'badge5');
    });

    test('returns everything when there are fewer than five', () async {
      await defineBadge('only', order: 1);

      expect(await service.getHomeBadges('runner-1'), hasLength(1));
    });
  });
}
