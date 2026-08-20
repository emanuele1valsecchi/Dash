import 'package:dash_watch_protocol/dash_watch_protocol.dart';
import 'package:flutter/material.dart';

import '../watch_theme.dart';
import 'metric.dart';

/// Ground claimed so far this run.
///
/// Its own page rather than two more tiles on the metrics screen, because this
/// is the thing that makes Dash *Dash* rather than a stopwatch — and because a
/// closed loop is an event worth arriving at, not a counter to squint at
/// between pace and heart rate.
class TerritoryPage extends StatelessWidget {
  final RunStats stats;
  final bool ambient;

  const TerritoryPage({super.key, required this.stats, required this.ambient});

  @override
  Widget build(BuildContext context) {
    final hasClaimed = stats.loopsCompleted > 0;

    return RoundSafe(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            hasClaimed ? Icons.crop_free_rounded : Icons.crop_free_outlined,
            size: 22,
            color: ambient
                ? WatchTheme.ambientText
                : hasClaimed
                    ? WatchTheme.accent
                    : WatchTheme.secondaryText,
          ),
          const SizedBox(height: 8),
          Metric(
            value: WatchFormat.areaKm2(stats.claimedAreaM2),
            label: 'KM² CLAIMED',
            valueSize: 30,
            valueColor: hasClaimed ? WatchTheme.accent : null,
            ambient: ambient,
          ),
          const SizedBox(height: 10),
          Metric(
            value: '${stats.loopsCompleted}',
            label: stats.loopsCompleted == 1 ? 'LOOP CLOSED' : 'LOOPS CLOSED',
            valueSize: 19,
            ambient: ambient,
          ),
          if (!hasClaimed && !ambient) ...[
            const SizedBox(height: 8),
            const Text(
              'Close a loop to\nclaim ground',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 10, color: WatchTheme.secondaryText),
            ),
          ],
        ],
      ),
    );
  }
}
