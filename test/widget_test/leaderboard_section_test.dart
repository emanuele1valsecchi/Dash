import 'package:dash/models/home_models.dart';
import 'package:dash/widgets/home/leaderboard_preview_card.dart';
import 'package:dash/widgets/home/leaderboard_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_image_mock/network_image_mock.dart';

import '../helpers/pump_app.dart';

/// The swipeable row of leaderboard cards on the home screen.
///
/// The thing worth pinning is that **the tapped card's own territory reaches
/// the callback**. The home screen turns that name into the `cityFilter` it
/// opens the full leaderboard with, so reporting the wrong one — or the
/// currently-centred one rather than the tapped one — opens an empty board,
/// which is exactly the class of bug CLAUDE.md records for the
/// locality-vs-territory rule.
void main() {
  LeaderboardPreviewData board(String city, {int position = 3}) =>
      LeaderboardPreviewData(
        position: position,
        points: 1280,
        variation: '+2',
        city: city,
        pins: [
          PreviewPin(
            userId: 'me',
            profileImageUrl: 'https://example.invalid/me.png',
            normalizedPosition: 0.6,
            isCurrentUser: true,
          ),
        ],
      );

  late List<String> tapped;

  Future<void> pumpSection(
    WidgetTester tester,
    List<LeaderboardPreviewData> boards,
  ) {
    tapped = [];
    return mockNetworkImagesFor(() => pumpDashWidget(
          tester,
          LeaderboardSection(
            leaderboards: boards,
            onLeaderboardTap: tapped.add,
          ),
          // Wide surface for the same test-font reason as the card itself:
          // the Position/Points/Variation labels measure ~2x their real width
          // (TEST_NOTES §1.2), and the card sizes from `MediaQuery`.
          surfaceSize: const Size(900, 900),
        ));
  }

  group('layout', () {
    testWidgets('is headed Leaderboards', (tester) async {
      await pumpSection(tester, [board('Global')]);

      expect(find.text('Leaderboards'), findsOneWidget);
    });

    testWidgets('renders a card for the first board', (tester) async {
      await pumpSection(tester, [board('Milano')]);

      expect(find.byType(LeaderboardPreviewCard), findsWidgets);
      expect(find.text('Milano'), findsWidgets);
    });

    testWidgets('an empty list reads as still loading, not as empty',
        (tester) async {
      // Deliberate: the home screen streams these in, and
      // `LeaderboardOrder.defaultOrder` always includes Global, so an empty
      // list only ever means "not arrived yet". A spinner is therefore the
      // honest state — an "no leaderboards" message would be wrong.
      await pumpSection(tester, []);

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Leaderboards'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('tapping a card', () {
    testWidgets('reports that card territory', (tester) async {
      await pumpSection(tester, [board('Milano')]);

      await tester.tap(find.text('Milano').first);
      await tester.pump();

      expect(tapped, ['Milano']);
    });

    testWidgets('reports the tapped board, not the first one', (tester) async {
      // With several boards the section pages between them; the callback must
      // carry the one actually tapped.
      await pumpSection(tester, [board('Global'), board('Milano')]);

      await tester.tap(find.text('Global').first);
      await tester.pump();

      expect(tapped, ['Global']);
    });

    testWidgets('reports an unresolved territory verbatim', (tester) async {
      // The card *displays* 'Unknown territory' for an empty name, but the
      // callback has to carry the real value the home screen filters on —
      // substituting the display string would open a board that cannot exist.
      await pumpSection(tester, [board('')]);

      await tester.tap(find.text('Unknown territory').first);
      await tester.pump();

      expect(tapped, ['']);
    });

    testWidgets('a tap reports exactly once', (tester) async {
      await pumpSection(tester, [board('Milano')]);

      await tester.tap(find.text('Milano').first);
      await tester.pump();

      expect(tapped, hasLength(1));
    });
  });

  group('paging between boards', () {
    testWidgets('swiping moves to the next board', (tester) async {
      await pumpSection(tester, [board('Global'), board('Milano')]);

      await tester.drag(find.byType(PageView), const Offset(-600, 0));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });

    testWidgets('a single board does not break the pager', (tester) async {
      await pumpSection(tester, [board('Global')]);

      await tester.drag(find.byType(PageView), const Offset(-600, 0));
      await tester.pumpAndSettle();

      expect(find.text('Global'), findsWidgets);
    });

    testWidgets('disposes its page controller cleanly', (tester) async {
      await pumpSection(tester, [board('Global'), board('Milano')]);

      await pumpDashWidget(tester, const SizedBox());

      expect(tester.takeException(), isNull);
    });
  });
}
