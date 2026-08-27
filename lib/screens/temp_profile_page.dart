import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

import '../config/map_style.dart';
import '../services/cached_tile_provider.dart';
import '../services/favorite_route_repository.dart';
import '../services/route_repository.dart';
import '../widgets/units_scope.dart';

/// Where a listed route came from, which is what decides whether its delete
/// button destroys a document or just unlinks a favourite.
///
/// Tracked explicitly rather than inferred from a field on the route: a route
/// favourited *before* favourites became shared is an owned copy that still
/// carries a `sourceSessionId`, so branching on that field would wrongly try
/// to un-favourite it and leave the copy stranded in the list. Which query
/// returned it is unambiguous — [RouteRepository.fetchUserRoutes] only ever
/// returns documents this user owns and may delete, and
/// [FavoriteRouteRepository.fetchFavorites] only ever returns shared routes
/// they may only unlink from.
enum _RouteSource { owned, favorite }

class _RouteEntry {
  final SavedRoute route;
  final _RouteSource source;

  const _RouteEntry(this.route, this.source);
}

class TempProfilePage extends StatefulWidget {
  const TempProfilePage({super.key});

  @override
  State<TempProfilePage> createState() => _TempProfilePageState();
}

class _TempProfilePageState extends State<TempProfilePage> {
  List<_RouteEntry>? _entries;
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final owned = await RouteRepository.instance.fetchUserRoutes();
      final favorites = await FavoriteRouteRepository.instance.fetchFavorites();
      final entries = <_RouteEntry>[
        for (final r in owned) _RouteEntry(r, _RouteSource.owned),
        for (final r in favorites) _RouteEntry(r, _RouteSource.favorite),
      ]..sort((a, b) => b.route.createdAt.compareTo(a.route.createdAt));

      if (mounted) setState(() { _entries = entries; _isLoading = false; });
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _isLoading = false; });
    }
  }

  Future<void> _confirmDelete(_RouteEntry entry) async {
    final isFavorite = entry.source == _RouteSource.favorite;
    final route = entry.route;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(isFavorite ? 'Remove favourite?' : 'Delete route?'),
        content: Text(
          isFavorite
              // The route itself survives: other users' favourites may point
              // at the same shared document.
              ? 'Remove "${route.name}" from your favourites?'
              : 'Delete "${route.name}"? This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: Text(isFavorite ? 'Remove' : 'Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      if (isFavorite) {
        await FavoriteRouteRepository.instance.unfavoriteRoute(route.id);
      } else {
        await RouteRepository.instance.deleteRoute(route.id);
      }
      if (mounted) {
        setState(() => _entries?.removeWhere(
              (e) => e.route.id == route.id && e.source == entry.source,
            ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to remove: $e')),
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
              : (_entries == null || _entries!.isEmpty)
                  ? _buildEmptyState()
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      itemCount: _entries!.length,
                      itemBuilder: (context, i) =>
                          _buildRouteCard(context, _entries![i]),
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

  Widget _buildRouteCard(BuildContext context, _RouteEntry entry) {
    final route = entry.route;
    final distLabel = Units.of(context).distance(route.distanceKm * 1000);
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
                    minZoom: MapStyle.minZoom,
                    interactionOptions: const InteractionOptions(
                      flags: InteractiveFlag.none,
                    ),
                  ),
                  children: [
                    TileLayer(
                      urlTemplate: MapStyle.terrainTileUrl,
                      userAgentPackageName: 'com.dash',
                      retinaMode: RetinaMode.isHighDensity(context),
                      tileProvider: CachedTileProvider.instance,
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
                  icon: Icon(
                    entry.source == _RouteSource.favorite
                        ? Icons.favorite_rounded
                        : Icons.delete_outline_rounded,
                    color: const Color(0xFFD32F2F),
                  ),
                  onPressed: () => _confirmDelete(entry),
                  tooltip: entry.source == _RouteSource.favorite
                      ? 'Remove from favourites'
                      : 'Delete route',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
