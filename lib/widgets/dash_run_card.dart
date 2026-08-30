import 'package:dash/services/run_session_repository.dart';
import 'package:dash/widgets/dash_map_card.dart';
import 'package:dash/widgets/units_scope.dart';
import 'package:flutter/material.dart';

/// A completed run as a card: map preview of the recorded path, the run's
/// name, the date it happened, and distance/time/area.
///
/// Deliberately the same [DashMapCard] treatment as [DashRouteCard], so a
/// profile's "Runs" and "Routes" rows read as one family — the two differ
/// only in which numbers they carry and where tapping leads.
class DashRunCard extends StatelessWidget {
  /// See [DashMapCard.heightFactor] — null fills the height the parent gives.
  final double? heightFactor;
  final double widthFactor;

  final RunSession session;
  final VoidCallback onTap;

  const DashRunCard({
    super.key,
    this.heightFactor,
    this.widthFactor = 1.0,
    required this.session,
    required this.onTap,
  });

  static const List<String> _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  static String _formatDate(DateTime date) =>
      '${_months[date.month - 1]} ${date.day}, ${date.year}';

  static String _formatDuration(Duration d) {
    final totalSeconds = d.inSeconds;
    final h = totalSeconds ~/ 3600;
    final m = (totalSeconds % 3600) ~/ 60;
    final s = totalSeconds % 60;
    if (h > 0) return '${h}h ${m}m';
    if (m > 0) return '${m}m ${s}s';
    return '${s}s';
  }

  @override
  Widget build(BuildContext context) {
    final units = Units.of(context);

    return DashMapCard(
      heightFactor: heightFactor,
      widthFactor: widthFactor,
      polyline: session.path,
      title: session.name,
      subtitle: _formatDate(session.createdAt),
      onTap: onTap,
      stats: [
        DashMapCardStat(
          icon: Icons.straighten_rounded,
          label: units.distance(session.distanceMeters),
        ),
        DashMapCardStat(
          icon: Icons.timer_outlined,
          label: _formatDuration(session.duration),
        ),
        // Only shown once the claim Cloud Function has actually written an
        // area — a run that closed no loop, or whose scoring hasn't landed
        // yet, would otherwise read as "0 km²" claimed, which looks like a
        // failure rather than "this run wasn't about territory".
        if (session.totalAreaM2 > 0)
          DashMapCardStat(
            icon: Icons.square_foot_outlined,
            label: units.area(session.totalAreaM2),
            color: Theme.of(context).colorScheme.tertiary,
          ),
      ],
    );
  }
}
