import 'package:dash/models/home_models.dart';
import 'package:dash/widgets/home/leaderboard_preview_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_image_mock/network_image_mock.dart';

import '../helpers/pump_app.dart';

/// One leaderboard card on the home screen: a territory name, a track with
/// each runner pinned along it, and the viewer's position/points/variation.
///
/// Wrapped in `mockNetworkImagesFor` throughout — the pins are profile
/// pictures, and the test binding answers every HTTP request with a 400, so
/// an unmocked `NetworkImage` throws while decoding.
void main() {
  PreviewPin pin({
    String userId = 'u1',
    double position = 0.5,
    bool isCurrentUser = false,
  }) =>
      PreviewPin(
        userId: userId,
        profileImageUrl: 'https://example.invalid/$userId.png',
        normalizedPosition: position,
        isCurrentUser: isCurrentUser,
      );

  LeaderboardPreviewData data({
    int position = 4,
    int points = 1280,
    String? variation = '+2',
    String city = 'Milano',
    List<PreviewPin>? pins,
  }) =>
      LeaderboardPreviewData(
        position: position,
        points: points,
        variation: variation,
        city: city,
        pins: pins ?? [pin(), pin(userId: 'me', position: 0.7, isCurrentUser: true)],
      );

  Future<void> pumpCard(
    WidgetTester tester,
    LeaderboardPreviewData subject, {
    VoidCallback? onTap,
  }) =>
      mockNetworkImagesFor(() => pumpDashWidget(
            tester,
            LeaderboardPreviewCard(data: subject, onTap: onTap ?? () {}),
            // A wide *surface*, not a wide parent box: the card sizes itself
            // from `MediaQuery`, so wrapping it in a `SizedBox` changes
            // nothing (the overflow stayed at exactly 27px from 560 to 800).
            //
            // It needs the room because the test font renders every glyph a
            // full em wide (TEST_NOTES §1.2) — the Position/Points/Variation
            // labels alone measure ~375px here against ~150px on a device, so
            // the stat row overflows for font-metric reasons that say nothing
            // about this widget. These tests assert content and tap
            // behaviour, not layout, so the oversized surface costs nothing.
            surfaceSize: const Size(900, 900),
          ));

  group('what it shows', () {
    testWidgets('names the territory', (tester) async {
      await pumpCard(tester, data(city: 'Milano'));

      expect(find.text('Milano'), findsOneWidget);
    });

    testWidgets('shows position, points and variation', (tester) async {
      await pumpCard(tester, data(position: 4, points: 1280, variation: '+2'));

      expect(find.text('#4'), findsOneWidget);
      expect(find.text('1280 pt'), findsOneWidget);
      expect(find.text('+2'), findsOneWidget);
      expect(find.text('Position'), findsOneWidget);
      expect(find.text('Points'), findsOneWidget);
      expect(find.text('Variation'), findsOneWidget);
    });

    testWidgets('draws a pin per runner', (tester) async {
      // Keyed by uid, which is also what stops flutter_map-style positional
      // reconciliation putting one runner's face on another's pin.
      await pumpCard(
        tester,
        data(pins: [pin(userId: 'a'), pin(userId: 'b'), pin(userId: 'c')]),
      );

      for (final uid in ['a', 'b', 'c']) {
        expect(find.byKey(ValueKey(uid)), findsOneWidget, reason: uid);
      }
    });
  });

  group('missing data degrades rather than breaking', () {
    testWidgets('an unresolved territory says so', (tester) async {
      // Every run lands on *some* board, but the name may not have resolved
      // yet — an empty header would read as a rendering bug.
      await pumpCard(tester, data(city: ''));

      expect(find.text('Unknown territory'), findsOneWidget);
    });

    testWidgets('no variation shows a dash, not "null"', (tester) async {
      await pumpCard(tester, data(variation: null));

      expect(find.text('—'), findsOneWidget);
      expect(find.textContaining('null'), findsNothing);
    });

    testWidgets('an empty board renders', (tester) async {
      // Nobody has scored here yet.
      await pumpCard(tester, data(pins: []));

      expect(tester.takeException(), isNull);
      expect(find.text('Milano'), findsOneWidget);
    });

    testWidgets('a board with no current user renders', (tester) async {
      // The viewer has not run here; the track still draws, with progress at
      // zero rather than throwing on a missing pin.
      await pumpCard(
        tester,
        data(pins: [pin(userId: 'a'), pin(userId: 'b')]),
      );

      expect(tester.takeException(), isNull);
    });

    testWidgets('zero points and last place still render', (tester) async {
      await pumpCard(tester, data(position: 0, points: 0));

      expect(find.text('#0'), findsOneWidget);
      expect(find.text('0 pt'), findsOneWidget);
    });
  });

  group('pin positions', () {
    // `normalizedPosition` is 0..1 along the track. Out-of-range values come
    // from a division somewhere upstream, so they must not throw here.
    for (final p in const [0.0, 0.5, 1.0]) {
      testWidgets('renders a pin at $p', (tester) async {
        await pumpCard(
          tester,
          data(pins: [pin(position: p, isCurrentUser: true)]),
        );

        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('an out-of-range position does not throw', (tester) async {
      await pumpCard(
        tester,
        data(pins: [pin(position: 1.4, isCurrentUser: true)]),
      );

      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('the whole card is the tap target', (tester) async {
    // It opens the full leaderboard; a card that only responded on its title
    // would be a small target on a busy screen.
    var taps = 0;
    await pumpCard(tester, data(), onTap: () => taps++);

    await tester.tap(find.text('Milano'));
    await tester.pump();

    expect(taps, 1);
  });
}
