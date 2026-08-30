import 'package:dash/extensions/responsive_spacing.dart';
import 'package:dash/models/home_models.dart';
import 'package:dash/utils/unit_formatter.dart';
import 'package:dash/widgets/dash_section_container.dart';
import 'package:dash/widgets/home/statistic_tachometer.dart';
import 'package:dash/widgets/units_scope.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

class MonthlyStatsSection extends StatelessWidget {
  final MonthlyStatsRaw? rawStats;

  const MonthlyStatsSection({
    super.key,
    required this.rawStats,
  });

  @override
  Widget build(BuildContext context) {
    if (rawStats == null) {
      return const Center(child: CircularProgressIndicator());
    }

    final units = Units.of(context);
    final stats = _buildMonthlyStats(rawStats!, units);

    return DashSectionContainer.withFadeEdge(
      leadingIcon: Symbols.monitoring_rounded,
      title: "Last 30 days statistics", 
      hasForwardIcon: false,
      child: SingleChildScrollView(
        physics: const ClampingScrollPhysics(),
        scrollDirection: Axis.horizontal,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          spacing: ResponsiveSpacing().md,
          children: List.generate(stats.length, (i){
            return StatisticTachometer(
              stat: stats[i],
              allStats: stats,
            );
          }),
        ),
      )
    );
  }

  List<MonthlyStatData> _buildMonthlyStats(MonthlyStatsRaw raw, UnitFormatter units) {
    final rateWord = units.rateLabel.toLowerCase();

    return [
      MonthlyStatData(
        title: 'Average\nsession time',
        value: raw.avgDurationStr,
        icon: Icons.timer_outlined,
        progress: raw.bestDurationMs > 0
            ? (raw.avgDurationMs / raw.bestDurationMs).clamp(0.0, 1.0)
            : 0.0,
        bottomText: raw.bestDurationMs > 0
            ? 'Best overall: ${Duration(milliseconds: raw.bestDurationMs).inMinutes} min'
            : 'No records yet',
      ),
      MonthlyStatData(
        title: 'Average best\n$rateWord',
        value: units.rateFromSpeedKmh(raw.avgMaxSpeedKmh),
        icon: Icons.speed_rounded,
        progress: raw.bestSpeedKmh > 0
            ? (raw.avgMaxSpeedKmh / raw.bestSpeedKmh).clamp(0.0, 1.0)
            : 0.0,
        bottomText: raw.bestSpeedKmh > 0
            ? 'Best overall: ${units.rateFromSpeedKmh(raw.bestSpeedKmh)}'
            : 'No records yet',
      ),
      MonthlyStatData(
        title: 'Average\n$rateWord',
        value: units.rateFromSpeedKmh(raw.avgSpeedKmh),
        icon: Icons.shutter_speed_rounded,
        progress: raw.bestAvgSpeedKmh > 0
            ? (raw.avgSpeedKmh / raw.bestAvgSpeedKmh).clamp(0.0, 1.0)
            : 0.0,
        bottomText: raw.bestAvgSpeedKmh > 0
            ? 'Best overall: ${units.rateFromSpeedKmh(raw.bestAvgSpeedKmh)}'
            : 'No records yet',
      ),
      MonthlyStatData(
        title: 'Average\ndistance',
        value: raw.avgDistanceMeters > 0
            ? units.distance(raw.avgDistanceMeters, decimals: 1)
            : '--',
        icon: Icons.swap_horiz_rounded,
        progress: raw.bestDistanceMeters > 0
            ? (raw.avgDistanceMeters / raw.bestDistanceMeters).clamp(0.0, 1.0)
            : 0.0,
        bottomText: raw.bestDistanceMeters > 0
            ? 'Best overall: ${units.distance(raw.bestDistanceMeters, decimals: 1)}'
            : 'No records yet',
      ),
      MonthlyStatData(
        title: 'Completed\nactivities',
        value: '${raw.completedActivities}',
        icon: Icons.directions_run_rounded,
        progress: raw.activitiesProgress,
        bottomText: 'Previous 30 days: ${raw.previousCompletedActivities}',
      ),
      MonthlyStatData(
        title: 'Average\ncalories',
        value: raw.avgCalories > 0 ? units.energy(raw.avgCalories) : '--',
        icon: Icons.local_fire_department_rounded,
        progress: raw.bestCalories > 0
            ? (raw.avgCalories / raw.bestCalories).clamp(0.0, 1.0)
            : 0.0,
        bottomText: raw.bestCalories > 0
            ? 'Best overall: ${units.energy(raw.bestCalories)}'
            : 'No records yet',
      ),
    ];
  }
}