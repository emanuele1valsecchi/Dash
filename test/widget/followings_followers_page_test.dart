import 'package:dash/config/app_theme.dart';
import 'package:dash/screens/followings_followers_page.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Followers and Following, as two swipeable sections behind a tab header.
///
/// The interesting part is that **the two lists query the same collection in
/// opposite directions** — followers are documents where *you* are the
/// `followingId`, following are documents where you are the `followerId`.
/// Getting that backwards shows each user their own mirror image, which looks
/// entirely plausible until somebody checks.
///
/// Driven against `FakeFirebaseFirestore`, which supports `snapshots()`, so
/// these are real queries against real (in-memory) documents rather than
/// stubbed return values.
void main() {
  late FakeFirebaseFirestore db;

  const me = 'runner-1';

  /// A profile document, so the row for a user actually renders — the tile
  /// hides itself entirely when the profile is missing.
  Future<void> profile(String uid, {String name = 'Alice'}) =>
      db.collection('profiles').doc(uid).set({
        'name': name,
        'surname': 'Example',
        'email': '$uid@example.com',
        'profileImageUrl': '',
      });

  /// `follower` follows `following`.
  Future<void> follow(String follower, String following) =>
      db.collection('follows').doc('${follower}_$following').set({
        'followerId': follower,
        'followingId': following,
      });

  setUp(() {
    db = FakeFirebaseFirestore();
  });

  Future<void> pumpPage(
    WidgetTester tester, {
    int section = FollowingsFollowersPage.followersSection,
  }) async {
    tester.view.physicalSize = const Size(500, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: FollowingsFollowersPage(
          userId: me,
          initialSection: section,
          firestore: db,
          auth: MockFirebaseAuth(
            signedIn: true,
            mockUser: MockUser(uid: me),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('empty states', () {
    testWidgets('says so when nobody follows you', (tester) async {
      await pumpPage(tester);

      expect(find.text('No followers yet'), findsOneWidget);
    });

    testWidgets('says so when you follow nobody', (tester) async {
      await pumpPage(
        tester,
        section: FollowingsFollowersPage.followingSection,
      );

      expect(find.text('Not following anyone yet'), findsOneWidget);
    });

    testWidgets('the two empty messages are different', (tester) async {
      // They mean different things, and a shared "nothing here" would leave
      // the user unsure which list they are looking at.
      await pumpPage(tester);
      expect(find.text('Not following anyone yet'), findsNothing);
    });
  });

  group('the two lists query in opposite directions', () {
    testWidgets('followers are people who follow you', (tester) async {
      await profile('alice');
      await profile('bob', name: 'Bob');
      await follow('alice', me);
      await follow('bob', me);

      await pumpPage(tester);

      expect(find.text('No followers yet'), findsNothing);
      expect(find.text('Alice Example'), findsOneWidget);
      expect(find.text('Bob Example'), findsOneWidget);
    });

    testWidgets('people you follow do NOT appear under followers',
        (tester) async {
      // The mirror-image bug: if the query used the wrong field, this would
      // show up as a follower.
      await follow(me, 'alice');

      await pumpPage(tester);

      expect(find.text('No followers yet'), findsOneWidget);
    });

    testWidgets('following are the people you follow', (tester) async {
      await profile('alice');
      await follow(me, 'alice');

      await pumpPage(
        tester,
        section: FollowingsFollowersPage.followingSection,
      );

      expect(find.text('Not following anyone yet'), findsNothing);
    });

    testWidgets('your followers do NOT appear under following',
        (tester) async {
      await follow('alice', me);

      await pumpPage(
        tester,
        section: FollowingsFollowersPage.followingSection,
      );

      expect(find.text('Not following anyone yet'), findsOneWidget);
    });

    testWidgets('someone elses follows are not shown at all', (tester) async {
      // The query is filtered by user, so an unrelated pair must not leak in.
      await follow('alice', 'bob');

      await pumpPage(tester);

      expect(find.text('No followers yet'), findsOneWidget);
    });

    testWidgets('a mutual follow appears in both lists', (tester) async {
      await profile('alice');
      await follow('alice', me);
      await follow(me, 'alice');

      await pumpPage(tester);
      expect(find.text('No followers yet'), findsNothing);

      await pumpPage(
        tester,
        section: FollowingsFollowersPage.followingSection,
      );
      expect(find.text('Not following anyone yet'), findsNothing);
    });
  });

  group('the lists are live', () {
    testWidgets('a new follower appears without reopening the page',
        (tester) async {
      // These are `snapshots()` streams, so the list reacts on its own.
      await pumpPage(tester);
      expect(find.text('No followers yet'), findsOneWidget);

      await profile('alice');
      await follow('alice', me);
      await tester.pumpAndSettle();

      expect(find.text('No followers yet'), findsNothing);
    });

    testWidgets('an unfollow removes them again', (tester) async {
      await profile('alice');
      await follow('alice', me);
      await pumpPage(tester);
      expect(find.text('No followers yet'), findsNothing);

      await db.collection('follows').doc('alice_$me').delete();
      await tester.pumpAndSettle();

      expect(find.text('No followers yet'), findsOneWidget);
    });
  });

  group('sections', () {
    testWidgets('opens on followers by default', (tester) async {
      await pumpPage(tester);

      expect(FollowingsFollowersPage.followersSection, 0);
      expect(find.text('No followers yet'), findsOneWidget);
    });

    testWidgets('can be opened straight onto following', (tester) async {
      // Callers deep-link into either half, so the initial page matters.
      await pumpPage(
        tester,
        section: FollowingsFollowersPage.followingSection,
      );

      expect(find.text('Not following anyone yet'), findsOneWidget);
    });

    testWidgets('the tab header switches between them', (tester) async {
      await pumpPage(tester);

      await tester.tap(find.text('Following'));
      await tester.pumpAndSettle();

      expect(find.text('Not following anyone yet'), findsOneWidget);
      expect(find.text('No followers yet'), findsNothing);
    });

    testWidgets('and back again', (tester) async {
      await pumpPage(tester);
      await tester.tap(find.text('Following'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Followers'));
      await tester.pumpAndSettle();

      expect(find.text('No followers yet'), findsOneWidget);
    });
  });
}
