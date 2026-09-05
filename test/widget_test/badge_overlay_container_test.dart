import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:network_image_mock/network_image_mock.dart';

import 'package:dash/models/home_badge_ui_model.dart';
import 'package:dash/widgets/badge/badge_overlay_container.dart';

import '../helpers/pump_app.dart';

/// The sheet shown when a badge is tapped. Its one branch that matters is the
/// status line, which has three mutually exclusive states — earned, partly
/// earned, and not started — driven by a single nullable progress value.
///
/// Progress here is a **0..1 fraction**, not the 0-100 percentage stored in
/// `badge_progress`. Every screen divides by 100 on its way in; passing the
/// stored number straight through would report "4000% Completed" or, worse,
/// silently show the earned state for anything above 1.
void main() {
  HomeBadgeUiModel badge({
    String id = 'duke',
    String title = 'Duke',
    String description = 'Hold the most territory in a city.',
    bool unlocked = false,
  }) =>
      HomeBadgeUiModel(
        badgeId: id,
        title: title,
        description: description,
        imageUrl: '',
        progress: 0,
        unlocked: unlocked,
      );

  Future<void> pumpOverlay(
    WidgetTester tester, {
    double? progress,
    HomeBadgeUiModel? model,
  }) async {
    await mockNetworkImagesFor(() async {
      await pumpDashWidget(
        tester,
        BadgeOverlayContainer(
          badge: model ?? badge(),
          progress: progress,
          userId: 'me',
        ),
        surfaceSize: const Size(900, 1200),
      );
      await tester.pump();
    });
  }

  group('what it always shows', () {
    testWidgets('the badge title and description', (tester) async {
      await pumpOverlay(
        tester,
        progress: 0.5,
        model: badge(title: 'Duke', description: 'Hold a city.'),
      );

      expect(find.text('Duke'), findsOneWidget);
      expect(find.text('Hold a city.'), findsOneWidget);
    });

    testWidgets('a close control', (tester) async {
      await pumpOverlay(tester, progress: 0.5);

      expect(find.byType(IconButton), findsWidgets);
    });
  });

  group('an earned badge', () {
    testWidgets('says so', (tester) async {
      await pumpOverlay(tester, progress: 1.0);

      expect(find.text('You have completed this badge'), findsOneWidget);
    });

    testWidgets('offers sharing', (tester) async {
      // Sharing only makes sense for something actually earned.
      await pumpOverlay(tester, progress: 1.0);

      expect(find.byIcon(Symbols.share_rounded), findsOneWidget);
    });

    testWidgets('does not invite you to go and earn it', (tester) async {
      await pumpOverlay(tester, progress: 1.0);

      expect(find.text('Complete it now'), findsNothing);
    });
  });

  group('a partly earned badge', () {
    testWidgets('shows the percentage', (tester) async {
      await pumpOverlay(tester, progress: 0.42);

      expect(find.text('42% Completed'), findsOneWidget);
    });

    testWidgets('truncates rather than rounds up', (tester) async {
      // 99.6% must not read as 100% — that is the earned state's wording.
      await pumpOverlay(tester, progress: 0.996);

      expect(find.text('99% Completed'), findsOneWidget);
    });

    testWidgets('reads as a fraction, not the stored percentage',
        (tester) async {
      // `badge_progress` stores 0-100 and every screen divides by 100 on the
      // way in. Handing this the stored number would print "4000%".
      await pumpOverlay(tester, progress: 0.4);

      expect(find.text('40% Completed'), findsOneWidget);
      expect(find.textContaining('4000'), findsNothing);
    });

    testWidgets('is not treated as earned', (tester) async {
      await pumpOverlay(tester, progress: 0.99);

      expect(find.text('You have completed this badge'), findsNothing);
      expect(find.byIcon(Symbols.share_rounded), findsNothing);
    });
  });

  group('a badge not started', () {
    testWidgets('invites you to go and earn it', (tester) async {
      await pumpOverlay(tester, progress: 0.0);

      expect(find.text('Complete it now'), findsOneWidget);
    });

    testWidgets('unknown progress is treated as not started', (tester) async {
      // Null is what a failed or not-yet-loaded read looks like. Showing the
      // earned state there would claim something untrue.
      await pumpOverlay(tester, progress: null);

      expect(find.text('Complete it now'), findsOneWidget);
      expect(find.text('You have completed this badge'), findsNothing);
    });

    testWidgets('offers no sharing', (tester) async {
      await pumpOverlay(tester, progress: 0.0);

      expect(find.byIcon(Symbols.share_rounded), findsNothing);
    });
  });
}
