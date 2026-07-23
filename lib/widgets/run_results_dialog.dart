import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../config/map_style.dart';
import '../services/cached_tile_provider.dart';
import '../utils/geometry_utils.dart';

/// Shows the post-run results popup: stats already known client-side appear
/// immediately, while XP/territory — written asynchronously by
/// `onRunningSessionCreateClaimedAreas` (functions/index.js) onto the same
/// `runningSessions/{sessionId}` doc some time after it's created — show a
/// loading state until that write lands (or a fallback if it takes too long).
///
/// Shared by both the real GPS run flow (RunTrackingPage) and the dev-only
/// test run creator (TestRunCreatorPage), so both funnel through
/// [RunSessionRepository.saveSession]'s returned session ID into here rather
/// than duplicating this UI.
///
/// Resolves once the user taps Done — callers should `await` this before
/// finishing up (popping their own screen, showing their own snackbar, etc.).
Future<void> showRunResultsDialog({
  required BuildContext context,
  required String sessionId,
  required List<LatLng> path,
  required double distanceMeters,
  required Duration duration,
  required double caloriesBurned,
  required double elevationDifferenceMeters,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _RunResultsDialog(
      sessionId: sessionId,
      path: path,
      distanceMeters: distanceMeters,
      duration: duration,
      caloriesBurned: caloriesBurned,
      elevationDifferenceMeters: elevationDifferenceMeters,
    ),
  );
}

class _RunResultsDialog extends StatefulWidget {
  final String sessionId;
  final List<LatLng> path;
  final double distanceMeters;
  final Duration duration;
  final double caloriesBurned;
  final double elevationDifferenceMeters;

  const _RunResultsDialog({
    required this.sessionId,
    required this.path,
    required this.distanceMeters,
    required this.duration,
    required this.caloriesBurned,
    required this.elevationDifferenceMeters,
  });

  @override
  State<_RunResultsDialog> createState() => _RunResultsDialogState();
}

class _RunResultsDialogState extends State<_RunResultsDialog> {
  static const _waitTimeout = Duration(seconds: 20);

  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _sub;
  Timer? _timeoutTimer;
  Map<String, dynamic>? _serverData;
  bool _timedOut = false;

  @override
  void initState() {
    super.initState();
    _sub = FirebaseFirestore.instance
        .collection('runningSessions')
        .doc(widget.sessionId)
        .snapshots()
        .listen((snap) {
      final data = snap.data();
      // pointsEarned alone can legitimately be 0 for a negligible session —
      // pointsProcessed is the unambiguous "the Cloud Function has run" flag.
      if (data == null || data['pointsProcessed'] != true) return;
      setState(() => _serverData = data);
      _sub?.cancel();
      _timeoutTimer?.cancel();
    });
    _timeoutTimer = Timer(_waitTimeout, () {
      _sub?.cancel();
      if (mounted && _serverData == null) setState(() => _timedOut = true);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _timeoutTimer?.cancel();
    super.dispose();
  }

  // ── Formatting ────────────────────────────────────────────────────────

  String get _distanceLabel => '${(widget.distanceMeters / 1000).toStringAsFixed(2)} km';

  String get _timeLabel {
    String two(int v) => v.toString().padLeft(2, '0');
    final h = widget.duration.inHours;
    final m = widget.duration.inMinutes % 60;
    final s = widget.duration.inSeconds % 60;
    return h > 0 ? '${two(h)}:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
  }

  String get _avgSpeedLabel {
    final hours = widget.duration.inMilliseconds / 3600000;
    if (hours <= 0) return '--';
    return '${((widget.distanceMeters / 1000) / hours).toStringAsFixed(1)} km/h';
  }

  String get _caloriesLabel => '${widget.caloriesBurned.round()} kcal';

  String get _elevationLabel => '${widget.elevationDifferenceMeters.round()} m';

  String _areaLabel(double areaM2) => GeometryUtils.formatAreaKm2(areaM2);

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFFF5F6EF),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 22, 20, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Run results',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: Color(0xFF1F3020)),
              ),
              const SizedBox(height: 14),
              ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: SizedBox(height: 170, child: _buildLockedMap(context)),
              ),
              const SizedBox(height: 16),
              GridView.count(
                crossAxisCount: 2,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: 2.4,
                children: [
                  _RunStat(icon: Icons.straighten_rounded, label: 'Distance', value: _distanceLabel),
                  _RunStat(icon: Icons.timer_outlined, label: 'Time', value: _timeLabel),
                  _RunStat(icon: Icons.speed_rounded, label: 'Avg speed', value: _avgSpeedLabel),
                  _RunStat(icon: Icons.local_fire_department_outlined, label: 'Calories', value: _caloriesLabel),
                  _RunStat(icon: Icons.terrain_rounded, label: 'Elevation', value: _elevationLabel),
                  _RunStat(
                    icon: Icons.crop_free_rounded,
                    label: 'Area',
                    value: _serverData != null
                        ? _areaLabel((_serverData!['totalAreaM2'] as num?)?.toDouble() ?? 0)
                        : '…',
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _buildXpSection(),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFCAF0B8),
                    foregroundColor: const Color(0xFF2E7D32),
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
                  ),
                  child: const Text('Done'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Locked whole-route map ────────────────────────────────────────────

  Widget _buildLockedMap(BuildContext context) {
    final hasPath = widget.path.length >= 2;
    return FlutterMap(
      options: MapOptions(
        initialCameraFit: hasPath
            ? CameraFit.coordinates(coordinates: widget.path, padding: const EdgeInsets.all(28))
            : null,
        initialCenter: widget.path.isNotEmpty ? widget.path.first : const LatLng(45.4642, 9.1900),
        initialZoom: 15,
        interactionOptions: const InteractionOptions(flags: InteractiveFlag.none),
      ),
      children: [
        TileLayer(
          urlTemplate: MapStyle.terrainTileUrl,
          userAgentPackageName: 'com.dash',
          retinaMode: RetinaMode.isHighDensity(context),
          tileProvider: CachedTileProvider.instance,
        ),
        if (hasPath)
          PolylineLayer(
            polylines: [
              Polyline(points: widget.path, color: const Color(0xFF4A8C52), strokeWidth: 4.0),
            ],
          ),
      ],
    );
  }

  // ── XP / territory (waits on the Cloud Function) ─────────────────────

  Widget _buildXpSection() {
    if (_serverData == null) {
      return Container(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 14),
        decoration: BoxDecoration(color: const Color(0xFFF0F2EB), borderRadius: BorderRadius.circular(16)),
        child: Row(
          children: _timedOut
              ? const [
                  Icon(Icons.hourglass_bottom_rounded, size: 18, color: Color(0xFF9AA294)),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Still calculating — check back on your profile later.',
                      style: TextStyle(color: Color(0xFF5E655C), fontSize: 13),
                    ),
                  ),
                ]
              : const [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF4A8C52)),
                  ),
                  SizedBox(width: 12),
                  Expanded(
                    child: Text('Calculating your score…', style: TextStyle(color: Color(0xFF5E655C), fontSize: 13)),
                  ),
                ],
        ),
      );
    }

    final data = _serverData!;
    final points = (data['pointsEarned'] as num?)?.round() ?? 0;
    final leaderboard = (data['territoryCity'] as String?) ?? (data['territoryBroad'] as String?) ?? 'Unknown';
    final xpFromDistance = (data['xpFromDistance'] as num?)?.toDouble() ?? 0;
    final xpFromArea = (data['xpFromArea'] as num?)?.toDouble() ?? 0;
    final xpFromStolenArea = (data['xpFromStolenArea'] as num?)?.toDouble() ?? 0;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFEAF7E0),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF4A8C52).withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.bolt_rounded, color: Color(0xFF2E7D32), size: 20),
              const SizedBox(width: 8),
              Text('$points XP',
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: Color(0xFF2E7D32))),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20)),
                child: Text(leaderboard,
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFF2E7D32))),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Divider(height: 1, color: Color(0xFFCFE3C0)),
          const SizedBox(height: 10),
          const Text(
            'XP BREAKDOWN (DEBUG)',
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFF6B7266), letterSpacing: 0.4),
          ),
          const SizedBox(height: 6),
          _XpBreakdownRow(label: 'Straight line (distance)', value: xpFromDistance),
          _XpBreakdownRow(label: 'Area', value: xpFromArea),
          _XpBreakdownRow(label: 'Stolen area', value: xpFromStolenArea),
        ],
      ),
    );
  }
}

// ── Stat tile (mirrors _SummaryStat in run_tracking_page.dart) ─────────────

class _RunStat extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _RunStat({required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(color: const Color(0xFFF0F2EB), borderRadius: BorderRadius.circular(14)),
      child: Row(
        children: [
          Icon(icon, size: 18, color: const Color(0xFF4A8C52)),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  value,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: Color(0xFF1F3020)),
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  label,
                  style: const TextStyle(fontSize: 11, color: Color(0xFF6B7266)),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── XP breakdown row ─────────────────────────────────────────────────────

class _XpBreakdownRow extends StatelessWidget {
  final String label;
  final double value;

  const _XpBreakdownRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(child: Text(label, style: const TextStyle(fontSize: 12, color: Color(0xFF425143)))),
          Text(
            '+${value.toStringAsFixed(1)} XP',
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFF2E7D32)),
          ),
        ],
      ),
    );
  }
}
