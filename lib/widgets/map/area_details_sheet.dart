import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

import '../../screens/public_profile_page.dart';
import '../../screens/run_session_detail_page.dart';
import '../../services/claimed_area_repository.dart';
import '../../services/profile_service.dart';
import '../../services/storage_service.dart';
import '../../services/user_appearance_service.dart';
import '../../utils/player_palette.dart';
import '../units_scope.dart';

/// Resolves whether a user holds the Duke badge, and the badge artwork to
/// draw beside their name.
///
/// Kept here rather than in a service because this is the only place that
/// asks: one document read per sheet opened, and the artwork URL — shared
/// reference data that never changes — is resolved once per process.
class _DukeBadge {
  static const String badgeId = 'duke';

  /// Process-lifetime cache of the badge image's download URL. Null once
  /// resolution has been attempted and failed, so a broken image path isn't
  /// re-fetched on every sheet.
  static Future<String?>? _imageUrl;

  static Future<String?> imageUrl() => _imageUrl ??= _resolveImageUrl();

  static Future<String?> _resolveImageUrl() async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('badges')
          .doc(badgeId)
          .get();
      final path = doc.data()?['imagePath'] as String?;
      if (path == null || path.isEmpty) return null;
      return await StorageService().getDownloadUrl(path);
    } catch (e) {
      debugPrint('Could not resolve the Duke badge image: $e');
      return null;
    }
  }

  /// Whether [uid] has unlocked it. `badge_progress` is readable by any
  /// signed-in user (see `firestore.rules`) precisely so achievements can be
  /// shown next to someone's name.
  static Future<bool> isHeldBy(String uid) async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('profiles')
          .doc(uid)
          .collection('badge_progress')
          .doc(badgeId)
          .get();
      return doc.data()?['unlocked'] == true;
    } catch (e) {
      debugPrint('Could not read Duke badge state for $uid: $e');
      return false;
    }
  }
}

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

  late final Future<bool> _hasDukeBadgeFuture =
      _DukeBadge.isHeldBy(widget.area.userId);

  /// Deliberately small — it sits beside a name, not in a trophy case, and
  /// should read as a mark of rank rather than compete with the username.
  static const double _dukeBadgeSize = 18;

  /// The Duke badge beside the owner's name, when they hold it.
  ///
  /// Renders nothing at all until both the ownership check and the artwork
  /// have resolved, and nothing if either fails: an empty box or a broken
  /// image next to someone's name reads as a bug, whereas its absence is
  /// indistinguishable from "this person is not a Duke", which is the common
  /// case anyway.
  Widget _buildDukeBadge() {
    return FutureBuilder<bool>(
      future: _hasDukeBadgeFuture,
      builder: (context, held) {
        if (held.data != true) return const SizedBox.shrink();

        return FutureBuilder<String?>(
          future: _DukeBadge.imageUrl(),
          builder: (context, image) {
            final url = image.data;
            if (url == null || url.isEmpty) return const SizedBox.shrink();

            return Padding(
              padding: const EdgeInsets.only(left: 6),
              child: Tooltip(
                message: 'Duke',
                child: CachedNetworkImage(
                  imageUrl: url,
                  width: _dukeBadgeSize,
                  height: _dukeBadgeSize,
                  fit: BoxFit.contain,
                  placeholder: (_, _) => const SizedBox.shrink(),
                  errorWidget: (_, _, _) => const SizedBox.shrink(),
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// Opens the owner's profile. The name is the obvious thing to tap once you
  /// are looking at "whose territory is this", and this sheet is the only
  /// place on the map where a stranger's identity is spelled out.
  void _openOwnerProfile() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PublicProfilePage(userId: widget.area.userId),
      ),
    );
  }

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
                      // The owner's own palette colour, matching the polygon
                      // on the map exactly — this dot is how a user connects
                      // "that purple blob" to a username.
                      color: PlayerPalette.colorFor(
                        uid: area.userId,
                        colorIndex: UserAppearanceService.instance
                            .get(area.userId)
                            ?.colorIndex,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: _openOwnerProfile,
                      child: Row(
                        children: [
                          Flexible(
                            child: FutureBuilder<String?>(
                              future: _usernameFuture,
                              builder: (context, snapshot) {
                                final username = snapshot.data;
                                final label = username ??
                                    (snapshot.connectionState ==
                                            ConnectionState.waiting
                                        ? 'Loading…'
                                        : 'Unknown runner');
                                return Text(
                                  label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w800,
                                    color: Color(0xFF1F3020),
                                  ),
                                );
                              },
                            ),
                          ),
                          _buildDukeBadge(),
                        ],
                      ),
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
                value: Units.of(context).area(area.totalAreaM2),
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
              for (final c in area.contributions)
                _ContributionRow(contribution: c, userId: area.userId),
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
/// contributed ground to this area. Tapping it opens [RunSessionDetailPage]
/// for the full picture (username, stats, favourite-as-route) — pushed from
/// inside this still-open bottom sheet, so its own back button naturally
/// returns here rather than leaving Explore entirely.
class _ContributionRow extends StatelessWidget {
  final AreaContribution contribution;
  final String userId;

  const _ContributionRow({required this.contribution, required this.userId});

  @override
  Widget build(BuildContext context) {
    final pace = contribution.avgPaceMinPerKm;
    final avgSpeedKmh = (pace != null && pace > 0) ? 60 / pace : null;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: const Color(0xFFF0F2EB),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => RunSessionDetailPage(
                sessionId: contribution.sessionId,
                userId: userId,
              ),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
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
                  // Wide enough for the longest rate string this can render
                  // ("10.4 km/h"), so switching pace↔speed never wraps.
                  width: 72,
                  child: Text(
                    avgSpeedKmh != null
                        ? Units.of(context).rateFromSpeedKmh(avgSpeedKmh)
                        : '—',
                    textAlign: TextAlign.right,
                    style: const TextStyle(fontSize: 13, color: Color(0xFF5E655C)),
                  ),
                ),
                const SizedBox(width: 4),
                const Icon(Icons.chevron_right, size: 18, color: Color(0xFFB9C2B5)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
