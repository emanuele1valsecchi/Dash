import 'dart:math' as math;

import 'package:dash_watch_protocol/dash_watch_protocol.dart';
import 'package:flutter/material.dart';

import '../watch_theme.dart';
import 'metric.dart';

/// The direction arrow, mirrored from the phone's `_RouteGuidanceCard`.
///
/// This is the page that justifies the watch existing: on the phone the arrow
/// still means digging the handset out of a pocket or armband, which is exactly
/// what a runner won't do mid-stride. On a wrist it is a glance.
///
/// The arrow rotates to the target bearing *relative to* the runner's heading,
/// so it reads like a handheld compass. When heading is unknown — standing
/// still, or below the speed where GPS course-over-ground means anything — it
/// deliberately shows a static compass glyph instead of pointing confidently in
/// a direction that means nothing.
class NavigationPage extends StatelessWidget {
  final RunStats stats;
  final bool ambient;

  const NavigationPage({super.key, required this.stats, required this.ambient});

  @override
  Widget build(BuildContext context) {
    final guidance = stats.guidance;

    if (guidance == null) {
      return const RoundSafe(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.explore_outlined,
                  size: 30, color: WatchTheme.secondaryText),
              SizedBox(height: 8),
              Text(
                'No route\nplanned',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: WatchTheme.secondaryText),
              ),
            ],
          ),
        ),
      );
    }

    final rotation = guidance.arrowRotationDegrees();
    final offRoute = guidance.isOffRoute;
    final color = ambient
        ? WatchTheme.ambientText
        : offRoute
            ? WatchTheme.warning
            : WatchTheme.accent;

    return RoundSafe(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            offRoute ? 'OFF ROUTE' : _turnLabel(guidance),
            textAlign: TextAlign.center,
            maxLines: 2,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
          const SizedBox(height: 10),
          if (rotation == null)
            Icon(Icons.explore_outlined, size: 46, color: color)
          else
            Transform.rotate(
              angle: rotation * math.pi / 180,
              child: Icon(Icons.navigation_rounded, size: 52, color: color),
            ),
          const SizedBox(height: 10),
          Metric(
            value: WatchFormat.distanceKm(guidance.distanceRemainingMeters),
            label: 'KM LEFT',
            valueSize: 17,
            ambient: ambient,
          ),
        ],
      ),
    );
  }

  /// Same wording rules as the phone: "Bear" below 70°, "Turn" at or above,
  /// "now" inside 15 m, and an explicit carry-on when nothing is in range —
  /// which reassures mid-run in a way a blank space does not.
  String _turnLabel(WatchGuidance guidance) {
    final distance = guidance.distanceToTurnMeters;
    final angle = guidance.turnAngleDegrees;
    if (distance == null || angle == null) return 'Continue straight';

    final side = angle < 0 ? 'left' : 'right';
    final verb = angle.abs() >= 70 ? 'Turn' : 'Bear';
    if (distance < 15) return '$verb $side now';
    return '$verb $side\nin ${(distance / 10).round() * 10} m';
  }
}
