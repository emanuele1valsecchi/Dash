import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dash/screens/notifications_page.dart';

/// `NotificationItem.fromFirestore` is the only place a notification document
/// is interpreted, and every field it reads is optional in the rules. Parsing
/// is tested apart from the screen because none of it needs one.
void main() {
  late FakeFirebaseFirestore db;

  setUp(() => db = FakeFirebaseFirestore());

  Future<NotificationItem> parse(Map<String, dynamic> data) async {
    final ref = await db.collection('notifications').add(data);
    return NotificationItem.fromFirestore(await ref.get());
  }

  group('type', () {
    test('is read from the stored name', () async {
      final item = await parse({'type': 'badgeUnlocked'});

      expect(item.type, NotificationType.badgeUnlocked);
    });

    test('falls back to newFollower for an unknown type', () async {
      // A type this build does not know about must still render as a row
      // rather than taking the whole list down.
      final item = await parse({'type': 'somethingFromTheFuture'});

      expect(item.type, NotificationType.newFollower);
    });

    test('falls back for a missing type too', () async {
      expect((await parse({})).type, NotificationType.newFollower);
    });
  });

  group('actor name', () {
    test('becomes the bold half of the message', () async {
      final item = await parse({
        'type': 'newFollower',
        'actorName': 'Ada',
        'message': ' started following you',
      });

      expect(item.boldText, 'Ada');
      expect(item.regularText, ' started following you');
    });

    test('is trimmed', () async {
      expect((await parse({'actorName': '  Ada  '})).boldText, 'Ada');
    });

    test('"system" is not a name and is dropped', () async {
      // Server-generated notifications set actorName to "system"; bolding it
      // would read as a person called System having done something.
      final item = await parse({'actorName': 'system'});

      expect(item.boldText, isEmpty);
    });

    test('the check ignores case', () async {
      expect((await parse({'actorName': 'System'})).boldText, isEmpty);
    });

    test('a missing actor leaves nothing bold', () async {
      expect((await parse({})).boldText, isEmpty);
    });
  });

  group('timestamps', () {
    test('are read from the stored value', () async {
      final when = DateTime(2026, 3, 14, 9, 30);

      final item = await parse({'createdAt': Timestamp.fromDate(when)});

      expect(item.createdAt, when);
    });

    test('a not-yet-resolved server timestamp falls back to now', () async {
      // Unlike the calendar, which skips these, a notification with no
      // timestamp still has to render — it is the newest one there is.
      final before = DateTime.now();

      final item = await parse({'type': 'newFollower'});

      expect(item.createdAt.difference(before).abs(),
          lessThan(const Duration(seconds: 5)));
    });
  });

  group('read state', () {
    test('defaults to unread', () async {
      expect((await parse({})).isRead, isFalse);
    });

    test('is read when the flag is set', () async {
      expect((await parse({'isRead': true})).isRead, isTrue);
    });
  });

  group('optional targets', () {
    test('are null when absent', () async {
      final item = await parse({'type': 'newFollower'});

      expect(item.routeId, isNull);
      expect(item.actorId, isNull);
      expect(item.cityName, isNull);
      expect(item.sessionId, isNull);
      expect(item.imageUrl, isNull);
    });

    test('are carried through when present', () async {
      final item = await parse({
        'type': 'areaStolen',
        'routeId': 'r1',
        'actorId': 'u1',
        'cityName': 'Milano',
        'sessionId': 's1',
        'actorImageUrl': 'https://example.com/a.png',
      });

      expect(item.routeId, 'r1');
      expect(item.actorId, 'u1');
      expect(item.cityName, 'Milano');
      expect(item.sessionId, 's1');
      expect(item.imageUrl, 'https://example.com/a.png');
    });

    test('the id comes from the document, not the data', () async {
      // Marking as read addresses the document by id, so this is the field
      // that has to be right for the write to land on the right row.
      final ref = await db.collection('notifications').add({'type': 'areaStolen'});

      final item = NotificationItem.fromFirestore(await ref.get());

      expect(item.id, ref.id);
    });
  });
}
