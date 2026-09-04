import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../utils/geometry_utils.dart';
import '../../utils/route_progress.dart';
import '../../utils/unit_formatter.dart';
import '../units_scope.dart';

/// The direction card shown above the live stats while a planned route is
/// being followed. Deliberately a bearing guide, not turn-by-turn: it needs
/// no street names, so it works on hand-drawn and stitched routes alike.
///
/// Extracted from `run_tracking_page.dart` so its state machine - off route,
/// arrived, arrived-but-skipped-part, pointing, no-heading - is testable
/// without a map, a GPS stream or Firebase.

class RouteGuidanceCard extends StatelessWidget {
  final RouteGuidance guidance;

  /// How much of the route has actually been covered. Null when there is no
  /// planned route to track progress through, in which case arrival falls
  /// back to the proximity test alone.
  final RouteProgress? progress;

  final double? heading;
  final bool isVoiceEnabled;
  final VoidCallback onToggleVoice;

  const RouteGuidanceCard({
    super.key,
    required this.guidance,
    required this.progress,
    required this.heading,
    required this.isVoiceEnabled,
    required this.onToggleVoice,
  });

  static const double _arrivalRadiusMeters = 20.0;
  static const double _sharpTurnDegrees = 70.0;
  static const double _imminentTurnMeters = 15.0;

  @override
  Widget build(BuildContext context) {
    final offRoute = guidance.isOffRoute;
    final atFinish =
        !offRoute && guidance.distanceRemainingMeters < _arrivalRadiusMeters;

    // Being near the finish is not the same as having run the route. On a
    // closed loop the two ends are the same place, so proximity alone reported
    // "Route complete" before the runner had moved — see [RouteProgressTracker].
    final covered = progress?.isCovered ?? true;
    final arrived = atFinish && covered;
    final shortOfFinish = atFinish && !covered;
    final canPoint = heading != null && !arrived;

    final (Color bg, Color fg) = switch ((offRoute, arrived)) {
      (true, _) => (const Color(0xFFF4E3B2), const Color(0xFF7A5B12)),
      (_, true) => (const Color(0xFFCAF0B8), const Color(0xFF2E7D32)),
      _ => (const Color(0xFFF0F2EB), const Color(0xFF4A8C52)),
    };

    final units = Units.of(context);

    final String title;
    final String subtitle;
    if (offRoute) {
      title = 'Off route';
      subtitle = '${units.shortDistance(guidance.offRouteMeters)} away '
          '— follow the arrow back';
    } else if (arrived) {
      title = 'Route complete';
      subtitle = 'You have reached the end of the planned route';
    } else if (shortOfFinish) {
      // Standing at the finish having skipped part of the route: the distance
      // readout would say "0 m to go", which is true of the line but not of
      // the run. Say what is actually outstanding instead.
      final p = progress!;
      title = 'Keep going';
      subtitle = 'Part of the route was skipped — '
          '${p.remaining} of ${p.total} checkpoints missed';
    } else if (canPoint) {
      title = _turnLabel(units);
      subtitle = _formatRemaining(units, guidance.distanceRemainingMeters);
    } else {
      title = 'Getting your bearing';
      subtitle =
          '${_formatRemaining(units, guidance.distanceRemainingMeters)} '
          '— start moving';
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.7),
              shape: BoxShape.circle,
            ),
            child: Center(child: _buildArrow(fg, canPoint, arrived)),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: fg)),
                const SizedBox(height: 2),
                Text(subtitle, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: fg.withValues(alpha: 0.75))),
              ],
            ),
          ),
          // --- NUOVO PULSANTE MUTE A DESTRA ---
          IconButton(
            icon: Icon(
              isVoiceEnabled ? Icons.volume_up_rounded : Icons.volume_off_rounded,
              color: fg.withValues(alpha: 0.7),
            ),
            onPressed: onToggleVoice,
          ),
        ],
      ),
    );
  }

  Widget _buildArrow(Color fg, bool canPoint, bool arrived) {
    if (arrived) {
      return Icon(Icons.flag_rounded, size: 26, color: fg);
    }
    if (!canPoint) {
      return Icon(Icons.explore_outlined, size: 26, color: fg);
    }
    final relative = (guidance.targetBearingDegrees - heading!) * math.pi / 180;
    return Transform.rotate(
      angle: relative,
      child: Icon(Icons.navigation_rounded, size: 28, color: fg),
    );
  }

  String _turnLabel(UnitFormatter units) {
    final distance = guidance.distanceToTurnMeters;
    final angle = guidance.turnAngleDegrees;
    if (distance == null || angle == null) return 'Continue straight';

    final side = angle < 0 ? 'left' : 'right';
    final verb = angle.abs() >= _sharpTurnDegrees ? 'Turn' : 'Bear';
    if (distance < _imminentTurnMeters) return '$verb $side now';

    return '$verb $side in ${units.shortDistance(distance, roundTo: 10)}';
  }

  String _formatRemaining(UnitFormatter units, double meters) =>
      '${units.distance(meters)} to go';
}
