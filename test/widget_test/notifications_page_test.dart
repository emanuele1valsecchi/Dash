import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_image_mock/network_image_mock.dart';

import 'package:dash/screens/notifications_page.dart';

import '../helpers/pump_app.dart';

/// Counts pushes so a test can assert that a tap navigated — or, more often
/// here, that a guard correctly refused to.
class _PushCounter extends NavigatorObserver {
  int pushes = 0;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    // The screen itself is the first route; only count what it pushes.
    if (previousRoute != null) pushes++;
    super.didPush(route, previousRoute);
  }
}

/// The message is drawn as a standalone `RichText` (bold actor name + plain
/// remainder), and the default text finders only look inside `Text` widgets.
Finder message(String text) => find.textContaining(text, findRichText: true);

void main() {
  late FakeFirebaseFirestore db;
  late MockFirebaseAuth auth;
  late _PushCounter pushes;

  setUp(() {
    db = FakeFirebaseFirestore();
    auth = MockFirebaseAuth(
      signedIn: true,
      mockUser: MockUser(uid: 'me', email: 'me@example.com'),
    );
    pushes = _PushCounter();
  });

  Future<DocumentReference<Map<String, dynamic>>> addNotification({
    String userId = 'me',
    String type = 'areaStolen',
    String message = ' took your territory',
    String? actorName,
    bool isRead = false,
    DateTime? createdAt,
    Map<String, dynamic> extra = const {},
  }) {
    return db.collection('notifications').add({
      'userId': userId,
      'type': type,
      'message': message,
      'actorName': ?actorName,
      'isRead': isRead,
      'createdAt': Timestamp.fromDate(createdAt ?? DateTime(2026, 3, 14, 9, 30)),
      ...extra,
    });
  }

  Future<void> pumpScreen(WidgetTester tester, {MockFirebaseAuth? withAuth}) async {
    await mockNetworkImagesFor(() async {
      await pumpDashWidget(
        tester,
        NotificationsScreen(firestore: db, auth: withAuth ?? auth),
        wrapInScaffold: false,
        navigatorObserver: pushes,
      );
      await tester.pumpAndSettle();
    });
  }

  group('the list', () {
    testWidgets('shows a notification\'s message', (tester) async {
      await addNotification(actorName: 'Ada', message: ' took your territory');

      await pumpScreen(tester);

      expect(message('took your territory'), findsOneWidget);
    });

    testWidgets('says so plainly when there is nothing', (tester) async {
      await pumpScreen(tester);

      expect(find.text('There\'s nothing new'), findsOneWidget);
    });

    testWidgets('shows only this user\'s notifications', (tester) async {
      await addNotification(message: ' is mine');
      await addNotification(userId: 'someone-else', message: ' is theirs');

      await pumpScreen(tester);

      expect(message('is mine'), findsOneWidget);
      expect(message('is theirs'), findsNothing);
    });

    testWidgets('puts the newest first', (tester) async {
      await addNotification(
        message: ' is older',
        createdAt: DateTime(2026, 1, 1),
      );
      await addNotification(
        message: ' is newer',
        createdAt: DateTime(2026, 6, 1),
      );

      await pumpScreen(tester);

      final newer = tester.getTopLeft(message('is newer'));
      final older = tester.getTopLeft(message('is older'));
      expect(newer.dy, lessThan(older.dy));
    });

    testWidgets('refuses to show anything when signed out', (tester) async {
      await addNotification(message: ' should stay hidden');

      await pumpScreen(tester, withAuth: MockFirebaseAuth());

      expect(find.text('You are not logged in.'), findsOneWidget);
      expect(message('should stay hidden'), findsNothing);
    });
  });

  group('read state', () {
    testWidgets('an unread row states itself in the date\'s weight and colour',
        (tester) async {
      await addNotification(message: ' unread one', isRead: false);

      await pumpScreen(tester);

      final date = tester.widget<Text>(find.textContaining('14 March 2026'));
      expect(date.style!.fontWeight, FontWeight.w600);
      expect(date.style!.color, const Color(0xFF4A8C52));
    });

    testWidgets('a read row is drawn back down', (tester) async {
      // Same row, same text — the only thing separating read from unread is
      // this treatment, so it is worth pinning both halves.
      await addNotification(message: ' read one', isRead: true);

      await pumpScreen(tester);

      final date = tester.widget<Text>(find.textContaining('14 March 2026'));
      expect(date.style!.fontWeight, FontWeight.normal);
      expect(date.style!.color, const Color(0xFF8A9389));
    });

    testWidgets('tapping an unread notification marks it read', (tester) async {
      // The rules let the recipient toggle `isRead`/`readAt` and nothing else,
      // so this write is the one thing the screen is allowed to do.
      final ref = await addNotification(
        type: 'badgeUnlocked',
        message: ' you earned a badge',
        isRead: false,
      );

      await pumpScreen(tester);
      await tester.tap(message('you earned a badge'));
      await tester.pump();

      final after = await ref.get();
      expect(after.data()!['isRead'], isTrue);
      expect(after.data()!['readAt'], isNotNull);
    });

    testWidgets('a read notification is not written again', (tester) async {
      final ref = await addNotification(
        type: 'badgeUnlocked',
        message: ' you earned a badge',
        isRead: true,
      );

      await pumpScreen(tester);
      await tester.tap(message('you earned a badge'));
      await tester.pump();

      expect((await ref.get()).data()!.containsKey('readAt'), isFalse);
    });
  });

  group('tap targets that must not navigate', () {
    // Each of these is a guard: the notification names a destination it
    // cannot actually open, and the tap has to be inert rather than pushing
    // a page with no id to load.
    testWidgets('a follow from "system" opens no profile', (tester) async {
      await addNotification(
        type: 'newFollower',
        message: ' started following you',
        extra: const {'actorId': 'system'},
      );

      await pumpScreen(tester);
      await tester.tap(message('started following you'));
      await tester.pumpAndSettle();

      expect(pushes.pushes, 0);
    });

    testWidgets('a follow with no actor opens no profile', (tester) async {
      await addNotification(
        type: 'newFollower',
        message: ' started following you',
      );

      await pumpScreen(tester);
      await tester.tap(message('started following you'));
      await tester.pumpAndSettle();

      expect(pushes.pushes, 0);
    });

    testWidgets('a stolen area with no session opens nothing', (tester) async {
      await addNotification(type: 'areaStolen', message: ' took your area');

      await pumpScreen(tester);
      await tester.tap(message('took your area'));
      await tester.pumpAndSettle();

      expect(pushes.pushes, 0);
    });

    testWidgets('a city leaderboard entry with no city opens nothing',
        (tester) async {
      await addNotification(
        type: 'leaderboardCityEntry',
        message: ' you entered the top ten',
      );

      await pumpScreen(tester);
      await tester.tap(message('you entered the top ten'));
      await tester.pumpAndSettle();

      expect(pushes.pushes, 0);
    });

    testWidgets('a route notification naming neither a run nor a route is inert',
        (tester) async {
      await addNotification(
        type: 'routeSaved',
        message: ' saved your route',
      );

      await pumpScreen(tester);
      await tester.tap(message('saved your route'));
      await tester.pumpAndSettle();

      expect(pushes.pushes, 0);
    });

    testWidgets('a route notification whose route was deleted is inert',
        (tester) async {
      // The route id is real but the document is gone — deleting a route is
      // allowed, and the notification outlives it.
      await addNotification(
        type: 'routeSaved',
        message: ' saved your route',
        extra: const {'routeId': 'no-such-route'},
      );

      await pumpScreen(tester);
      await tester.tap(message('saved your route'));
      await tester.pumpAndSettle();

      expect(pushes.pushes, 0);
    });

    testWidgets('but the tap still marks it read', (tester) async {
      // Failing to navigate must not also swallow the read receipt, or the
      // badge count never goes down.
      final ref = await addNotification(
        type: 'areaStolen',
        message: ' took your area',
      );

      await pumpScreen(tester);
      await tester.tap(message('took your area'));
      await tester.pumpAndSettle();

      expect((await ref.get()).data()!['isRead'], isTrue);
    });
  });

  group('the follow-back button', () {
    testWidgets('offers Follow back when you do not follow them',
        (tester) async {
      await addNotification(
        type: 'newFollower',
        message: ' started following you',
        extra: const {'actorId': 'ada'},
      );

      await pumpScreen(tester);

      expect(find.text('Follow back'), findsOneWidget);
    });

    testWidgets('reads Stop following once the link exists', (tester) async {
      await db.collection('follows').doc('me_ada').set({
        'followerId': 'me',
        'followingId': 'ada',
      });
      await addNotification(
        type: 'newFollower',
        message: ' started following you',
        extra: const {'actorId': 'ada'},
      );

      await pumpScreen(tester);

      expect(find.text('Stop following'), findsOneWidget);
    });

    testWidgets('following writes the link', (tester) async {
      await addNotification(
        type: 'newFollower',
        message: ' started following you',
        extra: const {'actorId': 'ada'},
      );

      await pumpScreen(tester);
      await tester.tap(find.text('Follow back'));
      await tester.pumpAndSettle();

      final link = await db.collection('follows').doc('me_ada').get();
      expect(link.exists, isTrue);
      expect(link.data()!['followerId'], 'me');
      expect(link.data()!['followingId'], 'ada');
    });

    testWidgets('tapping again unfollows', (tester) async {
      await db.collection('follows').doc('me_ada').set({
        'followerId': 'me',
        'followingId': 'ada',
      });
      await addNotification(
        type: 'newFollower',
        message: ' started following you',
        extra: const {'actorId': 'ada'},
      );

      await pumpScreen(tester);
      await tester.tap(find.text('Stop following'));
      await tester.pumpAndSettle();

      expect((await db.collection('follows').doc('me_ada').get()).exists,
          isFalse);
    });

    testWidgets('only a follow notification gets one', (tester) async {
      await addNotification(type: 'areaStolen', message: ' took your area');

      await pumpScreen(tester);

      expect(find.text('Follow back'), findsNothing);
      expect(find.byIcon(Icons.chevron_right_rounded), findsOneWidget);
    });
  });

  group('chrome', () {
    testWidgets('is titled Notifications', (tester) async {
      await pumpScreen(tester);

      expect(find.text('Notifications'), findsOneWidget);
    });

    testWidgets('shows the date a notification arrived', (tester) async {
      await addNotification(createdAt: DateTime(2026, 3, 14, 9, 30));

      await pumpScreen(tester);

      expect(find.textContaining('14 March 2026'), findsOneWidget);
    });
  });

  /// The assembled notification line. The actor's name and the rest of the
  /// message are two spans of one `RichText`, so a plain text finder sees
  /// neither half — only the whole thing, read back from the span tree.
  String richMessage(WidgetTester tester) {
    // Identified by structure, not position or length: the message is the
    // only `RichText` built from several spans (the bold name and the rest).
    // Icon fonts and the date line are single-span `RichText`s too, and both
    // would otherwise win a "first" or "longest" heuristic.
    final rich = tester.widgetList<RichText>(find.byType(RichText)).firstWhere(
        (w) => w.text is TextSpan && (w.text as TextSpan).children != null);
    return rich.text.toPlainText();
  }

  group('the actor avatar', () {
    // A notification carries the actor's picture when there is one. Falling
    // back to a glyph matters: `imageUrl` is absent for a system message and
    // empty for a user who never uploaded one, and both must render.
    testWidgets('a follow with a picture shows it', (tester) async {
      await addNotification(
        type: 'newFollower',
        actorName: 'Ada',
        extra: {'actorImageUrl': 'https://example.com/ada.png'},
      );

      await pumpScreen(tester);

      expect(find.byType(CircleAvatar), findsWidgets);
      expect(find.byIcon(Icons.person_add_alt_1_rounded), findsNothing);
    });

    testWidgets('a follow without one falls back to a glyph', (tester) async {
      await addNotification(type: 'newFollower', actorName: 'Ada');

      await pumpScreen(tester);

      expect(find.byIcon(Icons.person_add_alt_1_rounded), findsOneWidget);
    });

    testWidgets('an empty picture url is treated as none', (tester) async {
      // Stored as '' rather than omitted by several writers; a NetworkImage
      // on an empty string renders nothing at all.
      await addNotification(
        type: 'newFollower',
        actorName: 'Ada',
        extra: {'actorImageUrl': ''},
      );

      await pumpScreen(tester);

      expect(find.byIcon(Icons.person_add_alt_1_rounded), findsOneWidget);
    });

    testWidgets('a route notification with a picture shows it', (tester) async {
      await addNotification(
        type: 'routeSaved',
        actorName: 'Ada',
        extra: {'actorImageUrl': 'https://example.com/ada.png'},
      );

      await pumpScreen(tester);

      expect(find.byType(CircleAvatar), findsWidgets);
      expect(find.byIcon(Icons.map_rounded), findsNothing);
    });

    testWidgets('a route notification without one falls back to a map glyph',
        (tester) async {
      await addNotification(type: 'routeSaved', actorName: 'Ada');

      await pumpScreen(tester);

      expect(find.byIcon(Icons.map_rounded), findsOneWidget);
    });
  });

  group('the message', () {
    // The actor's name is drawn in bold and the rest follows it, so the
    // spacing between the two is assembled here rather than stored.
    testWidgets('a named actor is separated from the text', (tester) async {
      await addNotification(actorName: 'Ada', message: 'took your territory');

      await pumpScreen(tester);

      expect(richMessage(tester), 'Ada took your territory',
          reason: 'a space is added when the message does not carry one');
    });

    testWidgets('a message already spaced is not spaced twice', (tester) async {
      await addNotification(actorName: 'Ada', message: ' took your territory');

      await pumpScreen(tester);

      expect(richMessage(tester), 'Ada took your territory',
          reason: 'not spaced twice');
    });

    testWidgets('a system message with no actor starts at the left edge',
        (tester) async {
      // Nothing is bold, so the leading space that would follow a name would
      // read as a stray indent.
      await addNotification(message: '  Your badge is ready');

      await pumpScreen(tester);

      expect(richMessage(tester), 'Your badge is ready',
          reason: 'no bold name, so no leading space either');
    });
  });


  group('where a notification leads', () {
    // The switch on `NotificationType` is this screen's actual logic, and
    // getting it wrong sends someone to a stranger's profile instead of
    // their own leaderboard. Destinations are substituted (see the page's
    // builder seams) so the decision can be asserted without standing up a
    // live map or leaderboard query.
    Future<void> pumpWithStubs(WidgetTester tester) async {
      await mockNetworkImagesFor(() async {
        await pumpDashWidget(
          tester,
          NotificationsScreen(
            firestore: db,
            auth: auth,
            profilePageBuilder: (uid) => Text('PROFILE $uid'),
            runDetailPageBuilder: (s, u) => Text('RUN $s by $u'),
            routeDetailPageBuilder: (r, a) => Text('ROUTE $r by $a'),
            explorePageBuilder: (s) => Text('EXPLORE $s'),
            leaderboardPageBuilder: (c) => Text('BOARD $c'),
            badgePageBuilder: (uid) => Text('BADGES $uid'),
          ),
          wrapInScaffold: false,
        );
        await tester.pumpAndSettle();
      });
    }

    Future<void> tapFirst(WidgetTester tester) async {
      await tester.tap(find.byType(InkWell).first);
      await tester.pumpAndSettle();
    }

    testWidgets('a new follower opens that person, not the viewer',
        (tester) async {
      await addNotification(
          type: 'newFollower', actorName: 'Ada', extra: {'actorId': 'ada'});
      await pumpWithStubs(tester);

      await tapFirst(tester);

      expect(find.text('PROFILE ada'), findsOneWidget);
    });

    testWidgets('a stolen area opens the map at that run', (tester) async {
      // Explore takes the session so it can fly to the ground that changed
      // hands — without it the user lands on their own position and has to
      // hunt for what happened.
      await addNotification(
          type: 'areaStolen', extra: {'sessionId': 'sess-9'});
      await pumpWithStubs(tester);

      await tapFirst(tester);

      expect(find.text('EXPLORE sess-9'), findsOneWidget);
    });

    testWidgets('a route notification naming a run opens the run',
        (tester) async {
      await addNotification(
        type: 'routeSaved',
        actorName: 'Ada',
        extra: {'sessionId': 'sess-1', 'actorId': 'ada'},
      );
      await pumpWithStubs(tester);

      await tapFirst(tester);

      expect(find.text('RUN sess-1 by ada'), findsOneWidget);
    });

    testWidgets('a run wins over a route when both are named', (tester) async {
      // The run is the richer destination and the one the notification is
      // really about; the route id is denormalised alongside it.
      await addNotification(
        type: 'routeSaved',
        actorName: 'Ada',
        extra: {'sessionId': 'sess-1', 'routeId': 'r-1', 'actorId': 'ada'},
      );
      await pumpWithStubs(tester);

      await tapFirst(tester);

      expect(find.text('RUN sess-1 by ada'), findsOneWidget);
      expect(find.textContaining('ROUTE'), findsNothing);
    });

    testWidgets('a route notification naming only a route opens the route',
        (tester) async {
      await db.collection('routes').doc('r-1').set({
        'name': 'Park loop',
        'routePolyline': const <Object>[],
        'distanceMeters': 4000,
      });
      await addNotification(
          type: 'newRoutePublished',
          actorName: 'Ada',
          extra: {'routeId': 'r-1'});
      await pumpWithStubs(tester);

      await tapFirst(tester);

      expect(find.text('ROUTE r-1 by Ada'), findsOneWidget);
    });

    testWidgets('a city leaderboard entry opens that city', (tester) async {
      await addNotification(
          type: 'leaderboardCityEntry', extra: {'cityName': 'Milano'});
      await pumpWithStubs(tester);

      await tapFirst(tester);

      expect(find.text('BOARD Milano'), findsOneWidget);
    });

    testWidgets('a global entry opens the global board', (tester) async {
      await addNotification(type: 'leaderboardGlobalEntry');
      await pumpWithStubs(tester);

      await tapFirst(tester);

      expect(find.text('BOARD Global Leaderboard'), findsOneWidget);
    });

    testWidgets('being overtaken opens the global board too', (tester) async {
      await addNotification(type: 'leaderboardOvertake');
      await pumpWithStubs(tester);

      await tapFirst(tester);

      expect(find.text('BOARD Global Leaderboard'), findsOneWidget);
    });

    testWidgets('an unlocked badge opens your own badges, not the actor\'s',
        (tester) async {
      // The badge is yours; the notification names no one else.
      await addNotification(
          type: 'badgeUnlocked', extra: {'actorId': 'someone'});
      await pumpWithStubs(tester);

      await tapFirst(tester);

      expect(find.text('BADGES me'), findsOneWidget);
    });
  });

}
