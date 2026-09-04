import 'package:dash/config/app_theme.dart';
import 'package:dash/screens/public_profile_page.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';

import '../mocks.mocks.dart' hide MockUser;

/// Somebody else's profile. The heaviest screen tested so far: three
/// concurrent `snapshots()` subscriptions (profile, badge progress, follow
/// state) plus an embedded `ProfileActivitySections` with two repositories of
/// its own.
///
/// All three streams run against `FakeFirebaseFirestore`, so they are real
/// queries over real in-memory documents — which is what lets the follow
/// tests assert that writing a `follows` document flips the button with no
/// reload.
void main() {
  late FakeFirebaseFirestore db;
  late MockBadgeService badges;
  late MockRunSessionRepository sessions;
  late MockRouteRepository routes;

  const me = 'runner-1';
  const them = 'someone-else';

  Future<void> seedProfile(
    String uid, {
    String name = 'Alice',
    String surname = 'Example',
    String bio = 'Runs a lot',
    int followers = 3,
    int following = 5,
  }) =>
      db.collection('profiles').doc(uid).set({
        'name': name,
        'surname': surname,
        'username': uid,
        'bio': bio,
        'followersCount': followers,
        'followingCount': following,
        'profileImageUrl': '',
        'totalPoints': 0,
      });

  Future<void> follow(String follower, String following) =>
      db.collection('follows').doc('${follower}_$following').set({
        'followerId': follower,
        'followingId': following,
      });

  setUp(() {
    db = FakeFirebaseFirestore();
    badges = MockBadgeService();
    sessions = MockRunSessionRepository();
    routes = MockRouteRepository();

    when(badges.getProfileBadges(any)).thenAnswer((_) async => []);
    when(sessions.fetchUserSessions(userId: anyNamed('userId')))
        .thenAnswer((_) async => []);
    when(routes.fetchRoutesForUser(any, publicOnly: anyNamed('publicOnly')))
        .thenAnswer((_) async => []);
    when(routes.fetchUserRoutes()).thenAnswer((_) async => []);
  });

  Future<void> pumpPage(
    WidgetTester tester, {
    String profileUid = them,
    String viewerUid = me,
  }) async {
    tester.view.physicalSize = const Size(500, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: PublicProfilePage(
          userId: profileUid,
          firestore: db,
          auth: MockFirebaseAuth(
            signedIn: true,
            mockUser: MockUser(uid: viewerUid),
          ),
          badgeService: badges,
          sessionRepository: sessions,
          routeRepository: routes,
        ),
      ),
    );
    // Fixed pumps, not `pumpAndSettle`: an embedded card or an unresolved
    // image can leave something animating forever, and settling then times
    // out rather than telling you what is on screen.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 200));
  }

  group('the profile itself', () {
    testWidgets('shows the persons name and bio', (tester) async {
      await seedProfile(them, name: 'Alice', bio: 'Runs a lot');

      await pumpPage(tester);

      expect(find.textContaining('Alice'), findsWidgets);
      expect(find.text('Runs a lot'), findsOneWidget);
    });

    testWidgets('shows their follower counts', (tester) async {
      await seedProfile(them, followers: 12, following: 7);

      await pumpPage(tester);

      expect(find.text('12'), findsOneWidget);
      expect(find.text('7'), findsOneWidget);
    });

    testWidgets('updates live when the profile changes', (tester) async {
      // A `snapshots()` subscription, so an edit elsewhere lands here without
      // reopening the page.
      await seedProfile(them, bio: 'Runs a lot');
      await pumpPage(tester);
      expect(find.text('Runs a lot'), findsOneWidget);

      await db.collection('profiles').doc(them).update({'bio': 'Runs more'});
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('Runs more'), findsOneWidget);
    });

    testWidgets('renders for a profile that does not exist', (tester) async {
      // A deleted account is still linkable from an old area or run.
      await pumpPage(tester);

      expect(tester.takeException(), isNull);
    });
  });

  group('the follow button', () {
    testWidgets('offers to follow someone you do not', (tester) async {
      await seedProfile(them);

      await pumpPage(tester);

      expect(find.text('Add as friend'), findsOneWidget);
      expect(find.text('Remove from Friend'), findsNothing);
    });

    testWidgets('offers to unfollow someone you do', (tester) async {
      await seedProfile(them);
      await follow(me, them);

      await pumpPage(tester);

      expect(find.text('Remove from Friend'), findsOneWidget);
    });

    testWidgets('reads the follow state in the right direction',
        (tester) async {
      // *They* following *me* is not me following them. Getting this backwards
      // would show "Remove from Friend" for someone you have never followed.
      await seedProfile(them);
      await follow(them, me);

      await pumpPage(tester);

      expect(find.text('Add as friend'), findsOneWidget);
    });

    testWidgets('following writes the link and flips the button live',
        (tester) async {
      await seedProfile(them);
      await seedProfile(me, name: 'Me');
      await pumpPage(tester);

      await tester.tap(find.text('Add as friend'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(
        (await db.collection('follows').doc('${me}_$them').get()).exists,
        isTrue,
      );
      expect(find.text('Remove from Friend'), findsOneWidget);
    });

    testWidgets('unfollowing removes the link again', (tester) async {
      await seedProfile(them);
      await seedProfile(me, name: 'Me');
      await follow(me, them);
      await pumpPage(tester);

      await tester.tap(find.text('Remove from Friend'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(
        (await db.collection('follows').doc('${me}_$them').get()).exists,
        isFalse,
      );
      expect(find.text('Add as friend'), findsOneWidget);
    });

    testWidgets('an external follow flips the button with no interaction',
        (tester) async {
      await seedProfile(them);
      await pumpPage(tester);
      expect(find.text('Add as friend'), findsOneWidget);

      await follow(me, them);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('Remove from Friend'), findsOneWidget);
    });
  });

  group('activity sections', () {
    testWidgets('asks for the profile owners runs, not the viewers',
        (tester) async {
      await seedProfile(them);

      await pumpPage(tester);

      verify(sessions.fetchUserSessions(userId: them)).called(1);
    });

    testWidgets('asks only for their PUBLIC routes', (tester) async {
      // The extra `where` is not a filter, it is what makes the query
      // permissible: Firestore denies a query it cannot prove is safe, so
      // without it the whole read fails rather than returning a subset.
      await seedProfile(them);

      await pumpPage(tester);

      verify(routes.fetchRoutesForUser(them, publicOnly: true)).called(1);
      verifyNever(routes.fetchUserRoutes());
    });
  });

  group('badges', () {
    testWidgets('are loaded for the profile being viewed', (tester) async {
      await seedProfile(them);

      await pumpPage(tester);

      verify(badges.getProfileBadges(them)).called(1);
    });

    testWidgets('a badge failure does not take the page down',
        (tester) async {
      when(badges.getProfileBadges(any)).thenThrow(Exception('denied'));
      await seedProfile(them);

      await pumpPage(tester);

      expect(find.textContaining('Alice'), findsWidgets);
    });
  });
}
