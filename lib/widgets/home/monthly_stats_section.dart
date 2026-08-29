import 'package:dash/extensions/responsive_spacing.dart';
import 'package:dash/models/home_models.dart';
import 'package:dash/widgets/dash_section_container.dart';
import 'package:dash/widgets/home/statistic_tachometer.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

class MonthlyStatsSection extends StatelessWidget {
  final List<MonthlyStatData> stats;

  const MonthlyStatsSection({
    super.key,
    required this.stats,
  });

  @override
  Widget build(BuildContext context) {
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
            return StatisticTachometer(stat: stats[i]);
          }),
        ),
      )
    );
  }
}