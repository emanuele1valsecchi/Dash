import 'package:flutter/material.dart';

import '../watch_theme.dart';

/// One number with a unit caption under it.
///
/// Value and label are separate rather than one "3.42 km" string so the number
/// can be large and the unit small — at arm's length while running, the digits
/// are the only part actually being read, and giving the unit equal weight
/// wastes half the space on a 203 dp screen.
class Metric extends StatelessWidget {
  final String value;
  final String label;
  final double valueSize;
  final Color? valueColor;

  /// In ambient mode everything drops to one flat colour with no accent.
  final bool ambient;

  const Metric({
    super.key,
    required this.value,
    required this.label,
    this.valueSize = 22,
    this.valueColor,
    this.ambient = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = ambient
        ? WatchTheme.ambientText
        : (valueColor ?? WatchTheme.primaryText);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            value,
            maxLines: 1,
            style: TextStyle(
              fontSize: valueSize,
              fontWeight: FontWeight.w700,
              color: color,
              height: 1.05,
              // Tabular figures stop the layout jittering sideways as digits
              // change — very visible on a ticking clock in proportional type.
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
        const SizedBox(height: 1),
        Text(
          label,
          maxLines: 1,
          style: TextStyle(
            fontSize: 9,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.6,
            color: ambient
                ? WatchTheme.ambientText.withValues(alpha: 0.55)
                : WatchTheme.secondaryText,
          ),
        ),
      ],
    );
  }
}

/// Formatting shared by every page, kept together so the metrics screen and
/// the finish summary can never disagree about how a number is written.
class WatchFormat {
  static String duration(Duration d) {
    String two(int v) => v.toString().padLeft(2, '0');
    // Hours only appear once they exist — an hour field reading "00:" for most
    // of a run steals width from digits that are actually being read.
    return d.inHours > 0
        ? '${d.inHours}:${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)}'
        : '${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)}';
  }

  static String distanceKm(double meters) =>
      (meters / 1000).toStringAsFixed(2);

  static String pace(double? minPerKm) {
    if (minPerKm == null || !minPerKm.isFinite || minPerKm <= 0) return '--';
    final minutes = minPerKm.floor();
    final seconds = ((minPerKm - minutes) * 60).round();
    // 5.999 min/km would otherwise render as "5:60".
    if (seconds == 60) return '${minutes + 1}:00';
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  static String heartRate(int? bpm) => bpm?.toString() ?? '--';

  /// Matches the phone's `GeometryUtils.formatAreaKm2` convention — always
  /// km², with precision scaling by magnitude — minus the unit suffix, which
  /// the caller renders as a separate label.
  static String areaKm2(double m2) {
    final km2 = m2 / 1000000;
    if (km2 >= 1) return km2.toStringAsFixed(2);
    if (km2 >= 0.01) return km2.toStringAsFixed(3);
    return km2.toStringAsFixed(4);
  }
}
