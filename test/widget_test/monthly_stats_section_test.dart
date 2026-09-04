import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dash/models/home_models.dart';
import 'package:dash/widgets/home/monthly_stats_section.dart';
import 'package:dash/widgets/home/statistic_tachometer.dart';

import '../helpers/pump_app.dart';

/// The section turns raw metric numbers into six gauges. It is given raw
/// values rather than pre-formatted strings on purpose — units are chosen by
/// the user and can change while the screen is up — so most of what matters
/// is that each gauge's progress and caption are derived, not stored.
void main() {
  MonthlyStatsRaw raw({
    double avgDurationMs = 1800000,
    int bestDurationMs = 3600000,
    double avgMaxSpeedKmh = 12,
    double bestSpeedKmh = 18,
    double avgSpeedKmh = 10,
    double bestAvgSpeedKmh = 14,
    double avgDistanceMeters = 5000,
    double bestDistanceMeters = 12000,
    int completedActivities = 8,
    int previousCompletedActivities = 5,
    double activitiesProgress = 0.6,
    double avgCalories = 350,
    double bestCalories = 800,
    String avgDurationStr = '30:00',
  }) =>
      MonthlyStatsRaw(
        avgDurationMs: avgDurationMs,
        bestDurationMs: bestDurationMs,
        avgMaxSpeedKmh: avgMaxSpeedKmh,
        bestSpeedKmh: bestSpeedKmh,
        avgSpeedKmh: avgSpeedKmh,
        bestAvgSpeedKmh: bestAvgSpeedKmh,
        avgDistanceMeters: avgDistanceMeters,
        bestDistanceMeters: bestDistanceMeters,
        completedActivities: completedActivities,
        previousCompletedActivities: previousCompletedActivities,
        activitiesProgress: activitiesProgress,
        avgCalories: avgCalories,
        bestCalories: bestCalories,
        avgDurationStr: avgDurationStr,
      );

  Future<void> pumpSection(WidgetTester tester, MonthlyStatsRaw? stats) =>
      pumpDashWidget(
        tester,
        MonthlyStatsSection(rawStats: stats),
        // The row scrolls horizontally and holds six gauges; the test font
        // makes each far wider than on a phone. See TEST_NOTES 1.2.
        surfaceSize: const Size(1400, 900),
      );

  /// The gauge whose title contains [titlePart].
  StatisticTachometer gauge(WidgetTester tester, String titlePart) {
    return tester
        .widgetList<StatisticTachometer>(find.byType(StatisticTachometer))
        .firstWhere((g) => g.stat.title.contains(titlePart));
  }

  group('before the numbers arrive', () {
    testWidgets('shows a spinner rather than empty gauges', (tester) async {
      await pumpSection(tester, null);

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byType(StatisticTachometer), findsNothing);
    });
  });

  group('the gauges', () {
    testWidgets('there is one per tracked statistic', (tester) async {
      await pumpSection(tester, raw());

      expect(find.byType(StatisticTachometer), findsNWidgets(6));
    });

    testWidgets('progress is the average against the personal best',
        (tester) async {
      await pumpSection(tester,
          raw(avgDistanceMeters: 6000, bestDistanceMeters: 12000));

      expect(gauge(tester, 'distance').stat.progress, closeTo(0.5, 1e-9));
    });

    testWidgets('progress is capped at full, never over', (tester) async {
      // A month's average can exceed a stale "best overall" — the gauge must
      // fill, not overflow its arc.
      await pumpSection(tester,
          raw(avgDistanceMeters: 20000, bestDistanceMeters: 12000));

      expect(gauge(tester, 'distance').stat.progress, 1.0);
    });

    testWidgets('a caption names the personal best', (tester) async {
      await pumpSection(tester, raw(bestDistanceMeters: 12000));

      expect(gauge(tester, 'distance').stat.bottomText, contains('12.0 km'));
    });

    testWidgets('the activity count compares against the previous month',
        (tester) async {
      // The only gauge whose caption is a comparison rather than a record.
      await pumpSection(tester,
          raw(completedActivities: 8, previousCompletedActivities: 5));

      final g = gauge(tester, 'Completed');
      expect(g.stat.value, '8');
      expect(g.stat.bottomText, contains('5'));
    });
  });

  group('a brand-new account', () {
    testWidgets('has no records to compare against', (tester) async {
      await pumpSection(
        tester,
        raw(
          bestDurationMs: 0,
          bestSpeedKmh: 0,
          bestAvgSpeedKmh: 0,
          bestDistanceMeters: 0,
          bestCalories: 0,
        ),
      );

      expect(find.text('No records yet'), findsWidgets);
    });

    testWidgets('an empty gauge reads zero rather than dividing by it',
        (tester) async {
      await pumpSection(tester, raw(bestDistanceMeters: 0));

      expect(gauge(tester, 'distance').stat.progress, 0.0);
    });

    testWidgets('a zero average shows a dash, not "0 km"', (tester) async {
      // Nothing run at all is not the same as having run zero distance.
      await pumpSection(tester, raw(avgDistanceMeters: 0));

      expect(gauge(tester, 'distance').stat.value, '--');
    });

    testWidgets('zero calories shows a dash too', (tester) async {
      await pumpSection(tester, raw(avgCalories: 0));

      expect(gauge(tester, 'calories').stat.value, '--');
    });
  });

  group('units', () {
    testWidgets('distances are formatted, not raw metres', (tester) async {
      // The section takes raw metric numbers precisely so it can re-render
      // when the user changes units; storing formatted strings would freeze
      // whichever units were active when the query ran.
      await pumpSection(tester, raw(avgDistanceMeters: 5000));

      expect(gauge(tester, 'distance').stat.value, '5.0 km');
    });

    testWidgets('the rate gauges are titled with the chosen rate word',
        (tester) async {
      await pumpSection(tester, raw());

      final titles = tester
          .widgetList<StatisticTachometer>(find.byType(StatisticTachometer))
          .map((g) => g.stat.title.toLowerCase());
      expect(titles.where((t) => t.contains('pace')), hasLength(2));
    });
  });
}
