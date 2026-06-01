import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

class RouteInfoPanel extends StatelessWidget {
  final LatLng? lastPoint;
  final double totalDistanceMeters;
  final int waypointCount;
  final bool isRouting;
  final bool isLoopClosed;

  /// Non-null when a closed circuit has been detected.
  final double? loopAreaM2;

  final VoidCallback onClear;

  const RouteInfoPanel({
    super.key,
    required this.lastPoint,
    required this.totalDistanceMeters,
    required this.waypointCount,
    required this.isRouting,
    required this.isLoopClosed,
    required this.loopAreaM2,
    required this.onClear,
  });

  String get _distanceLabel {
    if (waypointCount < 2) return 'Add another point';
    if (totalDistanceMeters < 1000) return '${totalDistanceMeters.round()} m';
    return '${(totalDistanceMeters / 1000).toStringAsFixed(2)} km';
  }

  String get _coordsLabel {
    if (lastPoint == null) return '—';
    return '${lastPoint!.latitude.toStringAsFixed(6)}, '
        '${lastPoint!.longitude.toStringAsFixed(6)}';
  }

  String _formatArea(double m2) {
    if (m2 >= 1000000) return '${(m2 / 1000000).toStringAsFixed(2)} km²';
    if (m2 >= 10000) return '${(m2 / 10000).toStringAsFixed(2)} ha';
    return '${m2.round()} m²';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 32),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: const [
          BoxShadow(color: Colors.black26, blurRadius: 8, offset: Offset(0, 2)),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── Header ────────────────────────────────────────────────────
          Row(
            children: [
              Icon(
                isLoopClosed ? Icons.check_circle : Icons.edit_road,
                color: isLoopClosed ? Colors.green : Colors.blue,
                size: 20,
              ),
              const SizedBox(width: 8),
              Text(
                isLoopClosed ? 'Circuit closed!' : 'Route Builder',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 15,
                  color: isLoopClosed ? Colors.green : Colors.black,
                ),
              ),
              const Spacer(),
              if (isRouting)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              const SizedBox(width: 8),
              TextButton.icon(
                onPressed: onClear,
                icon: const Icon(Icons.delete_outline, size: 16),
                label: const Text('Clear'),
                style: TextButton.styleFrom(
                  foregroundColor: Colors.red,
                  padding: EdgeInsets.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ],
          ),
          const Divider(height: 16),

          // ── Content ───────────────────────────────────────────────────
          if (waypointCount == 0)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 4),
              child: Text(
                'Tap on the map to place a waypoint',
                style: TextStyle(color: Colors.grey, fontSize: 13),
              ),
            )
          else ...[
            _InfoRow(
              icon: Icons.location_on_outlined,
              label: 'Last point',
              value: _coordsLabel,
            ),
            const SizedBox(height: 6),
            _InfoRow(
              icon: Icons.straighten,
              label: 'Distance',
              value: _distanceLabel,
            ),
            const SizedBox(height: 6),
            _InfoRow(
              icon: Icons.radio_button_checked,
              label: 'Waypoints',
              value: '$waypointCount',
            ),
            if (loopAreaM2 != null) ...[
              const SizedBox(height: 6),
              _InfoRow(
                icon: Icons.crop_free,
                label: 'Area',
                value: _formatArea(loopAreaM2!),
                highlight: true,
              ),
            ],
          ],

          if (isLoopClosed) ...[
            const SizedBox(height: 8),
            const Text(
              'Tap Clear to start a new route',
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final bool highlight;

  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
    this.highlight = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = highlight ? Colors.green : Colors.blue;
    return Row(
      children: [
        Icon(icon, size: 15, color: color),
        const SizedBox(width: 8),
        Text(label, style: const TextStyle(color: Colors.grey, fontSize: 13)),
        const Spacer(),
        Flexible(
          child: Text(
            value,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: 13,
              color: highlight ? Colors.green : Colors.black,
            ),
            textAlign: TextAlign.right,
          ),
        ),
      ],
    );
  }
}