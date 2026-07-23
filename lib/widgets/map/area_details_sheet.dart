import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

import '../../services/claimed_area_repository.dart';
import '../../services/profile_service.dart';
import '../../utils/geometry_utils.dart';
import 'claimed_areas_layer.dart';

/// Opens [AreaDetailsSheet] for the area with the given id, if it's still in
/// [areas] (it always should be — ids come from a hit-test against polygons
/// built from this same list).
void showAreaDetailsSheet(
  BuildContext context,
  List<ClaimedArea> areas,
  String areaId,
) {
  ClaimedArea? area;
  for (final a in areas) {
    if (a.id == areaId) {
      area = a;
      break;
    }
  }
  final found = area;
  if (found == null) return;

  showModalBottomSheet(
    context: context,
    backgroundColor: Colors.white,
    // The contribution list below is unbounded-ish (capped at 10, but that
    // can still be taller than half the screen) — scrollable content needs
    // isScrollControlled so the sheet isn't clipped to a fixed fraction.
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => AreaDetailsSheet(area: found),
  );
}

/// Convenience for `MapOptions.onTap`: checks whether [hitNotifier]'s
/// current value (set by `ClaimedAreasLayer`'s own hit-testing just before
/// `onTap` fires) landed on an area, and opens its details sheet if so.
///
/// Returns whether a sheet was shown, so callers with their own tap
/// behaviour (e.g. dismissing a selection) can run it only when this
/// returns `false`.
bool handleAreaTap(
  BuildContext context,
  LayerHitNotifier<String> hitNotifier,
  List<ClaimedArea> areas,
) {
  final hitValues = hitNotifier.value?.hitValues;
  if (hitValues == null || hitValues.isEmpty) return false;
  showAreaDetailsSheet(context, areas, hitValues.first);
  return true;
}

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

String _formatDate(DateTime date) =>
    '${_months[date.month - 1]} ${date.day}, ${date.year}';

String _formatDuration(int ms) {
  final totalSeconds = ms ~/ 1000;
  final h = totalSeconds ~/ 3600;
  final m = (totalSeconds % 3600) ~/ 60;
  final s = totalSeconds % 60;
  if (h > 0) return '${h}h ${m}m';
  if (m > 0) return '${m}m ${s}s';
  return '${s}s';
}

/// Bottom sheet shown when a claimed-area polygon is tapped on the map.
/// Meant to be shown via `showModalBottomSheet`, which already supports
/// dragging it down or tapping outside it to dismiss — no custom gesture
/// handling needed here.
class AreaDetailsSheet extends StatefulWidget {
  final ClaimedArea area;

  const AreaDetailsSheet({super.key, required this.area});

  @override
  State<AreaDetailsSheet> createState() => _AreaDetailsSheetState();
}

class _AreaDetailsSheetState extends State<AreaDetailsSheet> {
  late final Future<String?> _usernameFuture =
      ProfileService().fetchUsername(widget.area.userId);

  @override
  Widget build(BuildContext context) {
    final area = widget.area;

    return SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey[300],
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Container(
                    width: 14,
                    height: 14,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: area.userId == FirebaseAuth.instance.currentUser?.uid
                          ? ClaimedAreasLayer.myColor
                          : ClaimedAreasLayer.otherColor,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FutureBuilder<String?>(
                      future: _usernameFuture,
                      builder: (context, snapshot) {
                        final username = snapshot.data;
                        final label = username ??
                            (snapshot.connectionState == ConnectionState.waiting
                                ? 'Loading…'
                                : 'Unknown runner');
                        return Text(
                          label,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                            color: Color(0xFF1F3020),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                'Conquered ${_formatDate(area.createdAt)}',
                style: const TextStyle(fontSize: 13, color: Color(0xFF5E655C)),
              ),
              const SizedBox(height: 20),
              _Stat(
                icon: Icons.square_foot_outlined,
                label: 'Total area',
                value: GeometryUtils.formatAreaKm2(area.totalAreaM2),
              ),
              const SizedBox(height: 20),
              Text(
                area.contributions.length == 1
                    ? 'Built from 1 run'
                    : 'Built from ${area.contributions.length} runs',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF1F3020),
                ),
              ),
              const SizedBox(height: 8),
              for (final c in area.contributions) _ContributionRow(contribution: c),
            ],
          ),
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _Stat({required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFF0F2EB),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Icon(icon, size: 20, color: const Color(0xFF4A8C52)),
          const SizedBox(width: 10),
          Text(
            value,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: Color(0xFF1F3020),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            label,
            style: const TextStyle(fontSize: 12, color: Color(0xFF5E655C)),
          ),
        ],
      ),
    );
  }
}

/// One row in the "built from N runs" list — a single past run that
/// contributed ground to this area, shown so the user can recognise (and,
/// once route-saving from other users' sessions exists, re-run) it.
class _ContributionRow extends StatelessWidget {
  final AreaContribution contribution;

  const _ContributionRow({required this.contribution});

  @override
  Widget build(BuildContext context) {
    final pace = contribution.avgPaceMinPerKm;
    final avgSpeedKmh = (pace != null && pace > 0) ? 60 / pace : null;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFF0F2EB),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          const Icon(Icons.directions_run_rounded, size: 18, color: Color(0xFF4A8C52)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _formatDate(contribution.conquestDate),
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Color(0xFF1F3020),
              ),
            ),
          ),
          Text(
            _formatDuration(contribution.durationMs),
            style: const TextStyle(fontSize: 13, color: Color(0xFF5E655C)),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 62,
            child: Text(
              avgSpeedKmh != null ? '${avgSpeedKmh.toStringAsFixed(1)} km/h' : '—',
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 13, color: Color(0xFF5E655C)),
            ),
          ),
        ],
      ),
    );
  }
}
