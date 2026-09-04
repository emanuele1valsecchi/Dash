import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dash/widgets/run/expanded_stats_bar.dart';
import 'package:dash/widgets/run/loop_indicator.dart';

import '../helpers/pump_app.dart';

void main() {
  group('LoopIndicator', () {
    testWidgets('reads as unclaimed before any loop closes', (tester) async {
      await pumpDashWidget(tester, const LoopIndicator(loopsCompleted: 0));
      await tester.pumpAndSettle();

      expect(find.text('No loop closed yet'), findsOneWidget);
      expect(find.byIcon(Icons.crop_free_outlined), findsOneWidget);
    });

    testWidgets('lights up and counts once a loop closes', (tester) async {
      await pumpDashWidget(tester, const LoopIndicator(loopsCompleted: 1));
      await tester.pumpAndSettle();

      expect(find.text('Loop closed — area claimed × 1'), findsOneWidget);
      expect(find.byIcon(Icons.crop_free_rounded), findsOneWidget);
    });

    testWidgets('counts every loop, not just the first', (tester) async {
      // A run can claim several separate blocks; the readout has to say so,
      // since the claimed total is the thing being earned.
      await pumpDashWidget(tester, const LoopIndicator(loopsCompleted: 3));
      await tester.pumpAndSettle();

      expect(find.text('Loop closed — area claimed × 3'), findsOneWidget);
    });

    testWidgets('re-runs its pop animation when the count changes',
        (tester) async {
      // Keyed on the count, so a new loop replays the elastic scale rather
      // than silently swapping the number in place.
      await pumpDashWidget(tester, const LoopIndicator(loopsCompleted: 1));
      await tester.pumpAndSettle();
      final settled = tester.widget<Transform>(
        find.ancestor(
          of: find.byIcon(Icons.crop_free_rounded),
          matching: find.byType(Transform),
        ),
      );

      await pumpDashWidget(tester, const LoopIndicator(loopsCompleted: 2));
      await tester.pump(const Duration(milliseconds: 16));
      final animating = tester.widget<Transform>(
        find.ancestor(
          of: find.byIcon(Icons.crop_free_rounded),
          matching: find.byType(Transform),
        ),
      );

      expect(animating.transform, isNot(settled.transform));
      await tester.pumpAndSettle();
    });
  });

  group('ExpandedStatsBar', () {
    Future<void> pumpBar(
      WidgetTester tester, {
      int loopsCompleted = 0,
      VoidCallback? onCollapse,
    }) {
      return pumpDashWidget(
        tester,
        ExpandedStatsBar(
          time: '12:34',
          distance: '2.40 km',
          pace: '5:30',
          rateUnitLabel: '/km',
          loopsCompleted: loopsCompleted,
          onCollapse: onCollapse ?? () {},
        ),
      );
    }

    testWidgets('shows the run at a glance', (tester) async {
      await pumpBar(tester);

      expect(find.text('12:34'), findsOneWidget);
      expect(find.text('2.40 km  ·  5:30 /km'), findsOneWidget);
    });

    testWidgets('hides the loop count until there is one', (tester) async {
      await pumpBar(tester);

      expect(find.byIcon(Icons.crop_free_rounded), findsNothing);
    });

    testWidgets('shows the loop count once a loop has closed', (tester) async {
      await pumpBar(tester, loopsCompleted: 2);

      expect(find.byIcon(Icons.crop_free_rounded), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
    });

    testWidgets('collapses the map when tapped anywhere', (tester) async {
      // The whole bar is the target, not a small button — it is meant to be
      // hit mid-run without looking.
      var collapsed = 0;
      await pumpBar(tester, onCollapse: () => collapsed++);

      await tester.tap(find.text('12:34'));
      await tester.pumpAndSettle();

      expect(collapsed, 1);
    });
  });
}
