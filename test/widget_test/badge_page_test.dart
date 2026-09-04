import 'package:dash/models/badge_model.dart';
import 'package:dash/screens/badge_page.dart';
import 'package:dash/widgets/badge/dash_badge.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:network_image_mock/network_image_mock.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../mocks.mocks.dart';
import '../helpers/pump_app.dart';

/// The full badge grid, reached from a profile.
///
/// It combines two sources: the **shared badge definitions** (title, artwork,
/// order) from `BadgeService`, and the viewer-or-owner's **live progress** from
/// a `badge_progress` `snapshots()` query. The interesting behaviour is that
/// the definitions load once while progress keeps updating — so a badge
/// unlocked while the page is open should light up without a reload.
void main() {
  late MockBadgeService badges;
  late FakeFirebaseFirestore db;

  const owner = 'runner-1';

  BadgeModel definition({
    String id = 'duke',
    String title = 'Duke',
    int order = 1,
  }) =>
      BadgeModel(
        id: id,
        title: title,
        description: 'About $title',
        imagePath: 'badges/$id.png',
        defaultVisible: true,
        order: order,
        requiredValue: 10,
      );

  /// Progress as the Cloud Function stores it: a **percentage, 0-100**
  /// (`functions/index.js` caps it at 100 and writes `progress: 100` on
  /// unlock). The page divides by 100 for `DashBadge`, which wants 0..1.
  Future<void> setProgress(
    String badgeId, {
    double progress = 50,
    bool unlocked = false,
  }) =>
      db
          .collection('profiles')
          .doc(owner)
          .collection('badge_progress')
          .doc(badgeId)
          .set({'progress': progress, 'unlocked': unlocked});

  setUp(() {
    // The page caches resolved artwork URLs on disk; without a mock store the
    // plugin channel is missing and the load throws.
    SharedPreferences.setMockInitialValues({});
    badges = MockBadgeService();
    db = FakeFirebaseFirestore();
    when(badges.getAllBadges(any)).thenAnswer((_) async => [definition()]);
  });

  Future<void> pumpPage(WidgetTester tester) =>
      mockNetworkImagesFor(() async {
        await pumpDashWidget(
          tester,
          BadgePage(userId: owner, badgeService: badges, firestore: db),
          wrapInScaffold: false,
          surfaceSize: const Size(500, 1000),
        );
        // Fixed pumps rather than `pumpAndSettle`: the badge artwork is a
        // CachedNetworkImage and the progress query is a live stream, so the
        // tree does not reliably go idle.
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));
        await tester.pump(const Duration(milliseconds: 200));
      });

  group('loading', () {
    testWidgets('asks for the badges of the profile being viewed',
        (tester) async {
      await pumpPage(tester);

      verify(badges.getAllBadges(owner)).called(1);
    });

    testWidgets('renders a badge per definition', (tester) async {
      when(badges.getAllBadges(any)).thenAnswer(
        (_) async => [
          definition(id: 'duke', title: 'Duke', order: 1),
          definition(id: 'traveller', title: 'Traveller', order: 2),
          definition(id: 'cheetah', title: 'Cheetah', order: 3),
        ],
      );

      await pumpPage(tester);

      expect(find.byType(DashBadge), findsNWidgets(3));
    });

    testWidgets('no definitions renders an empty grid, not a crash',
        (tester) async {
      // Every badge could legitimately have been retired — see the
      // `_wipe_discarded_badges` script.
      when(badges.getAllBadges(any)).thenAnswer((_) async => []);

      await pumpPage(tester);

      expect(tester.takeException(), isNull);
      expect(find.byType(DashBadge), findsNothing);
    });

    testWidgets('a failed definitions load does not leave it spinning',
        (tester) async {
      // `badges` is shared reference data; a denied read would otherwise
      // strand the page on its loading indicator forever.
      when(badges.getAllBadges(any))
          .thenAnswer((_) async => throw Exception('denied'));

      await pumpPage(tester);

      expect(find.byType(CircularProgressIndicator), findsNothing);
    });
  });

  group('progress', () {
    testWidgets('is read from the profile badge_progress subcollection',
        (tester) async {
      // Readable by any signed-in user on purpose, so achievements show on
      // someone else's profile too.
      await setProgress('duke', progress: 60);

      await pumpPage(tester);

      expect(find.byType(DashBadge), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a badge with no progress row reads as locked at zero',
        (tester) async {
      // The normal state for a badge nobody has touched.
      await pumpPage(tester);

      final badge = tester.widget<DashBadge>(find.byType(DashBadge));
      expect(badge.progress, 0.0);
    });

    testWidgets('an unlocked badge reports full progress', (tester) async {
      await setProgress('duke', progress: 100, unlocked: true);

      await pumpPage(tester);

      final badge = tester.widget<DashBadge>(find.byType(DashBadge));
      expect(badge.progress, 1.0);
    });

    testWidgets('unlocking while the page is open updates it live',
        (tester) async {
      // A `snapshots()` subscription — the whole point of streaming progress
      // rather than reading it once.
      await pumpPage(tester);
      expect(
        tester.widget<DashBadge>(find.byType(DashBadge)).progress,
        0.0,
      );

      await setProgress('duke', progress: 100, unlocked: true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(
        tester.widget<DashBadge>(find.byType(DashBadge)).progress,
        1.0,
      );
    });

    testWidgets('progress for an unrelated badge is ignored', (tester) async {
      // Rows are matched by badge id; a stale row for a retired badge must
      // not bleed onto a live one.
      await setProgress('some-retired-badge', progress: 100, unlocked: true);

      await pumpPage(tester);

      expect(
        tester.widget<DashBadge>(find.byType(DashBadge)).progress,
        0.0,
      );
    });
  });

  testWidgets('cancels its progress subscription on close', (tester) async {
    // A leaked stream would fail the next test with a pending-timer or
    // setState-after-dispose error.
    await pumpPage(tester);

    await pumpDashWidget(tester, const SizedBox());

    expect(tester.takeException(), isNull);
  });
}
