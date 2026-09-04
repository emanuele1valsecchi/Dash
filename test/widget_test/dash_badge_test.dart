import 'package:dash/models/home_badge_ui_model.dart';
import 'package:dash/widgets/badge/badge_overlay_container.dart';
import 'package:dash/widgets/badge/dash_badge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_image_mock/network_image_mock.dart';

import '../helpers/pump_app.dart';

/// One achievement badge — a ring showing progress, the artwork inside, and a
/// tap that opens the full description.
///
/// The distinction it has to get right is **locked vs unlocked**: a badge at
/// `progress == 1.0` is earned and drawn in full colour, anything below is
/// desaturated. Getting that backwards would tell people they had earned
/// things they had not.
///
/// Wrapped in `mockNetworkImagesFor` throughout: the artwork is a
/// `CachedNetworkImage`, and the test binding answers every HTTP request with
/// a 400.
void main() {
  HomeBadgeUiModel badge({
    String badgeId = 'duke',
    String title = 'Duke',
    String description = 'Hold the largest territory in your city.',
    double progress = 0.4,
    bool unlocked = false,
  }) =>
      HomeBadgeUiModel(
        badgeId: badgeId,
        title: title,
        description: description,
        imageUrl: 'https://example.invalid/$badgeId.png',
        progress: progress,
        unlocked: unlocked,
      );

  Future<void> pumpBadge(
    WidgetTester tester, {
    HomeBadgeUiModel? subject,
    double? progress = 0.4,
    bool clickable = true,
  }) =>
      mockNetworkImagesFor(() => pumpDashWidget(
            tester,
            DashBadge(
              badge: subject ?? badge(),
              progress: progress,
              clickable: clickable,
            ),
            surfaceSize: const Size(500, 900),
          ));

  group('rendering', () {
    testWidgets('shows the badge artwork', (tester) async {
      await pumpBadge(tester);

      expect(tester.takeException(), isNull);
      expect(find.byType(DashBadge), findsOneWidget);
    });

    testWidgets('an unlocked badge is drawn in full colour', (tester) async {
      // `progress == 1.0` is the earned state; no desaturation filter.
      await pumpBadge(tester, progress: 1.0);

      expect(find.byType(ColorFiltered), findsNothing);
    });

    testWidgets('a partly-earned badge is desaturated', (tester) async {
      await pumpBadge(tester, progress: 0.4);

      expect(find.byType(ColorFiltered), findsOneWidget);
    });

    testWidgets('an unstarted badge is desaturated too', (tester) async {
      await pumpBadge(tester, progress: 0.0);

      expect(find.byType(ColorFiltered), findsOneWidget);
    });

    testWidgets('a badge with unknown progress renders', (tester) async {
      // `progress` is nullable — the caller may not have loaded it yet.
      await pumpBadge(tester, progress: null);

      expect(tester.takeException(), isNull);
    });
  });

  group('tapping', () {
    testWidgets('a clickable badge opens its description', (tester) async {
      await mockNetworkImagesFor(() async {
        await pumpBadge(tester, clickable: true);

        await tester.tap(find.byType(DashBadge));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
      });

      expect(find.byType(BadgeOverlayContainer), findsOneWidget);
    });

    testWidgets('the overlay names the badge and explains it', (tester) async {
      await mockNetworkImagesFor(() async {
        await pumpBadge(
          tester,
          subject: badge(
            title: 'Duke',
            description: 'Hold the largest territory in your city.',
          ),
        );

        await tester.tap(find.byType(DashBadge));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
      });

      expect(find.text('Duke'), findsWidgets);
      expect(
        find.text('Hold the largest territory in your city.'),
        findsWidgets,
      );
    });

    testWidgets('a non-clickable badge opens nothing', (tester) async {
      // Used where badges are decoration rather than an entry point.
      await mockNetworkImagesFor(() async {
        await pumpBadge(tester, clickable: false);

        await tester.tap(find.byType(DashBadge));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
      });

      expect(find.byType(BadgeOverlayContainer), findsNothing);
    });
  });

  group('degenerate data', () {
    testWidgets('an empty image URL does not throw', (tester) async {
      // A badge whose artwork failed to resolve still has to draw its ring.
      await mockNetworkImagesFor(() => pumpDashWidget(
            tester,
            DashBadge(
              badge: HomeBadgeUiModel(
                badgeId: 'duke',
                title: 'Duke',
                description: 'x',
                imageUrl: '',
                progress: 0.5,
                unlocked: false,
              ),
              progress: 0.5,
              clickable: false,
            ),
            surfaceSize: const Size(500, 900),
          ));

      expect(tester.takeException(), isNull);
    });

    testWidgets('an out-of-range progress does not throw', (tester) async {
      await pumpBadge(tester, progress: 1.7);

      expect(tester.takeException(), isNull);
    });

    testWidgets('a negative progress does not throw', (tester) async {
      await pumpBadge(tester, progress: -0.3);

      expect(tester.takeException(), isNull);
    });

    testWidgets('an empty title and description render', (tester) async {
      await pumpBadge(
        tester,
        subject: badge(title: '', description: ''),
        clickable: false,
      );

      expect(tester.takeException(), isNull);
    });
  });
}
