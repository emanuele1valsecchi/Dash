import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

import '../config/map_style.dart';
import '../services/route_repository.dart';

class TempProfilePage extends StatefulWidget {
  const TempProfilePage({super.key});

  @override
  State<TempProfilePage> createState() => _TempProfilePageState();
}

class _TempProfilePageState extends State<TempProfilePage> {
  List<SavedRoute>? _routes;
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final routes = await RouteRepository.instance.fetchUserRoutes();
      if (mounted) setState(() { _routes = routes; _isLoading = false; });
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _isLoading = false; });
    }
  }

  Future<void> _confirmDelete(SavedRoute route) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Delete route?'),
        content: Text('Delete "${route.name}"? This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await RouteRepository.instance.deleteRoute(route.id);
      if (mounted) setState(() => _routes?.removeWhere((r) => r.id == route.id));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to delete: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF3F5EE),
      appBar: AppBar(
        backgroundColor: const Color(0xFFECEFE6),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Color(0xFF425143)),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text(
          'My Routes',
          style: TextStyle(fontWeight: FontWeight.w700, color: Color(0xFF2A3028)),
        ),
        centerTitle: true,
      ),
      body: _isLoading
          ? const Center(
              child: CircularProgressIndicator(color: Color(0xFF4A8C52)),
            )
          : _error != null
              ? Center(child: Text('Error: $_error'))
              : (_routes == null || _routes!.isEmpty)
                  ? _buildEmptyState()
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      itemCount: _routes!.length,
                      itemBuilder: (_, i) => _buildRouteCard(_routes![i]),
                    ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.route_rounded, size: 64, color: Colors.grey[300]),
          const SizedBox(height: 16),
          Text(
            'No routes yet',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: Colors.grey[500],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Create a route and publish it\nto see it here.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey[400], fontSize: 13),
          ),
        ],
      ),
    );
  }

  Widget _buildRouteCard(SavedRoute route) {
    final distLabel = route.distanceKm < 1
        ? '${(route.distanceKm * 1000).round()} m'
        : '${route.distanceKm.toStringAsFixed(2)} km';
    final timeMin = route.estimatedTimeMin;
    final timeLabel = timeMin < 60
        ? '${timeMin.round()} min'
        : '${(timeMin / 60).floor()}h ${(timeMin % 60).round()}min';

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      elevation: 2,
      color: Colors.white,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Map preview ────────────────────────────────────────────────────
          if (route.routePolyline.length >= 2)
            ClipRRect(
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(16)),
              child: SizedBox(
                height: 160,
                child: FlutterMap(
                  options: MapOptions(
                    initialCameraFit: CameraFit.bounds(
                      bounds: LatLngBounds.fromPoints(route.routePolyline),
                      padding: const EdgeInsets.all(28),
                    ),
                    interactionOptions: const InteractionOptions(
                      flags: InteractiveFlag.none,
                    ),
                  ),
                  children: [
                    TileLayer(
                      urlTemplate: MapStyle.terrainTileUrl,
                      userAgentPackageName: 'com.dash',
                      retinaMode: RetinaMode.isHighDensity(context),
                    ),
                    PolylineLayer(
                      polylines: [
                        Polyline(
                          points: route.routePolyline,
                          color: const Color(0xFF4A8C52),
                          strokeWidth: 3.5,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          // ── Info row ───────────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 14),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        route.name,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                          color: Color(0xFF2A3028),
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          const Icon(Icons.straighten_rounded,
                              size: 13, color: Colors.grey),
                          const SizedBox(width: 4),
                          Text(distLabel,
                              style: const TextStyle(
                                  fontSize: 12, color: Colors.grey)),
                          const SizedBox(width: 12),
                          const Icon(Icons.timer_outlined,
                              size: 13, color: Colors.grey),
                          const SizedBox(width: 4),
                          Text(timeLabel,
                              style: const TextStyle(
                                  fontSize: 12, color: Colors.grey)),
                          if (route.isLoop) ...[
                            const SizedBox(width: 12),
                            const Icon(Icons.loop_rounded,
                                size: 13, color: Color(0xFF4A8C52)),
                            const SizedBox(width: 4),
                            const Text('Loop',
                                style: TextStyle(
                                    fontSize: 12, color: Color(0xFF4A8C52))),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline_rounded,
                      color: Color(0xFFD32F2F)),
                  onPressed: () => _confirmDelete(route),
                  tooltip: 'Delete route',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
