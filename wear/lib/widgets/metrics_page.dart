import 'package:dash_watch_protocol/dash_watch_protocol.dart';
import 'package:flutter/material.dart';

import '../watch_theme.dart';
import 'metric.dart';

/// The default page: the four numbers a runner actually glances at.
///
/// Five values is the hard ceiling on a ~203 dp round screen — beyond that
/// nothing is large enough to read at arm's length while moving, which defeats
/// the point of having it on a wrist at all. Duration gets the top slot and
/// the largest type because it is what a runner checks most.
class MetricsPage extends StatelessWidget {
  final RunStats stats;
  final bool ambient;

  const MetricsPage({super.key, required this.stats, required this.ambient});

  @override
  Widget build(BuildContext context) {
    return RoundSafe(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Metric(
            value: WatchFormat.duration(stats.elapsed),
            label: stats.phase == RunPhase.paused ? 'PAUSED' : 'TIME',
            valueSize: 38,
            valueColor:
                stats.phase == RunPhase.paused ? WatchTheme.warning : null,
            ambient: ambient,
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              Metric(
                value: WatchFormat.distanceKm(stats.distanceMeters),
                label: 'KM',
                ambient: ambient,
              ),
              Metric(
                value: WatchFormat.pace(stats.paceMinPerKm),
                label: '/KM',
                ambient: ambient,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              Metric(
                value: WatchFormat.heartRate(stats.heartRateBpm),
                label: 'BPM',
                valueSize: 19,
                ambient: ambient,
              ),
              Metric(
                value: '${stats.loopsCompleted}',
                label: 'LOOPS',
                valueSize: 19,
                valueColor: stats.loopsCompleted > 0 ? WatchTheme.accent : null,
                ambient: ambient,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
