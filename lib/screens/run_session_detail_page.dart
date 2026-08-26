import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../config/map_style.dart';
import '../services/cached_tile_provider.dart';
import '../services/favorite_route_repository.dart';
import '../services/profile_service.dart';
import '../services/route_repository.dart';
import '../services/run_session_repository.dart';
import '../utils/geometry_utils.dart';
import '../widgets/units_scope.dart';

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

String _formatDate(DateTime date) =>
    '${_months[date.month - 1]} ${date.day}, ${date.year}';

String _formatDuration(Duration d) {
  final totalSeconds = d.inSeconds;
  final h = totalSeconds ~/ 3600;
  final m = (totalSeconds % 3600) ~/ 60;
  final s = totalSeconds % 60;
  if (h > 0) return '${h}h ${m}m';
  if (m > 0) return '${m}m ${s}s';
  return '${s}s';
}

/// Full-page detail view for a single run — reached by tapping a row in
/// `AreaDetailsSheet`'s "Built from N runs" contribution list.
///
/// Shows the *whole* running session, not just the loop that happened to
/// claim the area it was reached from — a run can close a small loop partway
/// through a much longer route, so the loop alone would misrepresent the
/// session (e.g. a 10 km run showing up as a tiny few-hundred-metre shape).
/// Fetches the full `runningSessions` doc itself, by id, rather than relying
/// on anything denormalized onto the `AreaContribution` that led here —
/// firestore.rules allows any signed-in user to read any session (a
/// deliberate exposure: reading another user's already-completed run to
/// copy into a route of your own isn't the same trust boundary as writing
/// one). Distinct from `session_detail_screen.dart` (reached from the
/// calendar, always the signed-in user's own session, no username header or
/// favourite button needed there).
class RunSessionDetailPage extends StatefulWidget {
  final String sessionId;
  final String userId;

  const RunSessionDetailPage({
    super.key,
    required this.sessionId,
    required this.userId,
  });

  @override
  State<RunSessionDetailPage> createState() => _RunSessionDetailPageState();
}

class _RunSessionDetailPageState extends State<RunSessionDetailPage> {
  late final Future<String?> _usernameFuture =
      ProfileService().fetchUsername(widget.userId);
  late final Future<RunSession?> _sessionFuture =
      RunSessionRepository.instance.fetchSessionById(widget.sessionId);

  /// Id of the `routes` doc this session was favourited as, or null if it
  /// hasn't been (yet). Resolved on load by matching `sourceSessionId`
  /// against the current user's already-cached routes — see
  /// `RouteRepository.fetchUserRoutes`.
  String? _favoritedRouteId;
  bool _loadingFavoriteState = true;
  bool _togglingFavorite = false;

  @override
  void initState() {
    super.initState();
    _loadFavoriteState();
  }

  Future<void> _loadFavoriteState() async {
    final routes = await RouteRepository.instance.fetchUserRoutes();
    if (!mounted) return;
    SavedRoute? match;
    for (final r in routes) {
      if (r.sourceSessionId == widget.sessionId) {
        match = r;
        break;
      }
    }
    setState(() {
      _favoritedRouteId = match?.id;
      _loadingFavoriteState = false;
    });
  }

  Future<void> _toggleFavorite(RunSession session) async {
    if (_togglingFavorite || session.path.length < 2) return;
    setState(() => _togglingFavorite = true);
    try {
      final currentRouteId = _favoritedRouteId;
      if (currentRouteId != null) {
        await FavoriteRouteRepository.instance.unfavoriteRoute(currentRouteId);
        if (!mounted) return;
        setState(() => _favoritedRouteId = null);
      } else {
        final username = await _usernameFuture;
        final routeId = await FavoriteRouteRepository.instance
            .favoriteSessionAsRoute(
              session,
              routeName: username != null ? "$username's run" : 'Favourited run',
            );
        if (!mounted) return;
        setState(() => _favoritedRouteId = routeId);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Something went wrong: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _togglingFavorite = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
              child: Row(
                children: [
                  Material(
                    color: Colors.white,
                    shape: const CircleBorder(),
                    elevation: 2,
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: () => Navigator.of(context).pop(),
                      child: const Padding(
                        padding: EdgeInsets.all(10),
                        child: Icon(
                          Icons.arrow_back,
                          color: Color(0xFF425143),
                          size: 22,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: FutureBuilder<RunSession?>(
                future: _sessionFuture,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Center(
                      child: CircularProgressIndicator(
                        color: Color(0xFF4A8C52),
                      ),
                    );
                  }
                  final session = snapshot.data;
                  if (session == null) {
                    return const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          "This run is no longer available.",
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 14, color: Color(0xFF5E655C)),
                        ),
                      ),
                    );
                  }
                  return _buildContent(context, session);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContent(BuildContext context, RunSession session) {
    final units = Units.of(context);
    final pace = session.avgPaceMinPerKm;
    final avgSpeedKmh = pace > 0 ? 60 / pace : null;
    final hasMap = session.path.length >= 2;
    final canFavorite = session.path.length >= 2;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FutureBuilder<String?>(
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
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF1F3020),
                ),
              );
            },
          ),
          const SizedBox(height: 4),
          Text(
            _formatDate(session.createdAt),
            style: const TextStyle(fontSize: 13, color: Color(0xFF5E655C)),
          ),
          const SizedBox(height: 20),
          if (hasMap) ...[
            _RunPathPreviewMap(path: session.path),
            const SizedBox(height: 20),
          ],
          Row(
            children: [
              Expanded(
                child: _StatPill(
                  icon: Icons.straighten_rounded,
                  label: 'Distance',
                  value: units.distanceMajor(session.distanceMeters),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _StatPill(
                  icon: Icons.timer_outlined,
                  label: 'Time',
                  value: _formatDuration(session.duration),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _StatPill(
                  icon: Icons.speed_rounded,
                  label: 'Avg ${units.rateLabel.toLowerCase()}',
                  value: avgSpeedKmh != null
                      ? units.rateFromSpeedKmh(avgSpeedKmh)
                      : '—',
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _StatPill(
                  icon: Icons.square_foot_outlined,
                  label: 'Area conquered',
                  value: units.area(session.totalAreaM2),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          Align(
            alignment: Alignment.centerRight,
            child: _FavoriteButton(
              enabled: canFavorite && !_loadingFavoriteState,
              isFavorited: _favoritedRouteId != null,
              isLoading: _togglingFavorite || _loadingFavoriteState,
              onTap: () => _toggleFavorite(session),
            ),
          ),
          if (!canFavorite) ...[
            const SizedBox(height: 8),
            const Align(
              alignment: Alignment.centerRight,
              child: Text(
                "This run has no recorded path, so it can't be favourited.",
                textAlign: TextAlign.right,
                style: TextStyle(fontSize: 12, color: Color(0xFF5E655C)),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Locked-by-default preview of the run's whole path, expandable (via
/// [_MapToggleButton], not a full-page takeover — deliberately smaller than
/// `RunTrackingPage`'s own live map expansion, since this is a static
/// after-the-fact summary, not something to navigate by) into a bigger,
/// genuinely pannable/zoomable map. Same `CameraFit.coordinates` fit
/// `run_results_dialog.dart` already uses for a just-finished run's
/// summary — plus start/finish pins and a handful of direction-of-travel
/// arrows along the line, neither of which that screen needed.
///
/// Deliberately just a polyline, no fill — unlike a claimed-loop shape, a
/// whole run's path isn't guaranteed to be a simple closed loop (it might
/// never return near its start at all, or wind through one partway through
/// a much longer route), so a `Polygon` fill (which always draws closed,
/// auto-connecting its last point back to its first) could render a
/// nonsensical self-intersecting shape for an ordinary point-to-point run.
class _RunPathPreviewMap extends StatefulWidget {
  final List<LatLng> path;

  const _RunPathPreviewMap({required this.path});

  @override
  State<_RunPathPreviewMap> createState() => _RunPathPreviewMapState();
}

class _RunPathPreviewMapState extends State<_RunPathPreviewMap> {
  static const double _collapsedHeight = 200;
  static const Duration _resizeDuration = Duration(milliseconds: 300);

  /// How many direction arrows to place along the path, regardless of how
  /// many raw breadcrumb points it has — see `GeometryUtils.arrowPositions`,
  /// which spaces them by distance along the line, not by vertex count.
  static const int _arrowCount = 5;

  final MapController _mapController = MapController();
  bool _expanded = false;

  @override
  void dispose() {
    _mapController.dispose();
    super.dispose();
  }

  double _expandedHeight(BuildContext context) =>
      (MediaQuery.of(context).size.height * 0.55).clamp(360.0, 520.0);

  /// Re-fits the camera to the path once the resize animation actually
  /// finishes. `MapOptions.initialCameraFit`/`initialZoom` only ever apply
  /// on the map's first build — without this, growing the container would
  /// just reveal more surrounding map at the same old zoom rather than
  /// filling the new size with the path, the same way it was fit at the
  /// smaller size.
  void _refitCamera() {
    try {
      _mapController.fitCamera(
        CameraFit.coordinates(
          coordinates: widget.path,
          padding: const EdgeInsets.all(28),
        ),
      );
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final start = widget.path.first;
    final finish = widget.path.last;
    final arrows = GeometryUtils.arrowPositions(widget.path, count: _arrowCount);

    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: AnimatedContainer(
        duration: _resizeDuration,
        curve: Curves.easeInOut,
        height: _expanded ? _expandedHeight(context) : _collapsedHeight,
        onEnd: _refitCamera,
        child: Stack(
          fit: StackFit.expand,
          children: [
            FlutterMap(
              mapController: _mapController,
              options: MapOptions(
                initialCameraFit: CameraFit.coordinates(
                  coordinates: widget.path,
                  padding: const EdgeInsets.all(28),
                ),
                initialCenter: start,
                initialZoom: 15,
                minZoom: MapStyle.minZoom,
                // Locked while collapsed (a small preview isn't usefully
                // pannable); real pan/zoom once expanded — rotate stays
                // excluded even then, same as every other interactive map
                // in the app, so the arrow bearings above never need to
                // account for a rotated camera.
                interactionOptions: InteractionOptions(
                  flags: _expanded
                      ? (InteractiveFlag.all & ~InteractiveFlag.rotate)
                      : InteractiveFlag.none,
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
                      points: widget.path,
                      color: const Color(0xFF4A8C52),
                      strokeWidth: 4.0,
                    ),
                  ],
                ),
                MarkerLayer(
                  markers: [
                    for (final a in arrows)
                      Marker(
                        point: a.point,
                        width: 22,
                        height: 22,
                        child: Transform.rotate(
                          angle: a.bearingDegrees * math.pi / 180,
                          child: const Icon(
                            Icons.navigation_rounded,
                            size: 18,
                            color: Color(0xFF2E7D32),
                          ),
                        ),
                      ),
                    Marker(
                      point: start,
                      width: 30,
                      height: 30,
                      child: const _EndpointPin(
                        icon: Icons.play_arrow_rounded,
                        background: Color(0xFF4A8C52),
                        iconColor: Colors.white,
                      ),
                    ),
                    Marker(
                      point: finish,
                      width: 30,
                      height: 30,
                      child: const _EndpointPin(
                        // The literal checkered-flag glyph in Material Icons.
                        icon: Icons.sports_score,
                        background: Colors.white,
                        iconColor: Color(0xFF1F3020),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            Positioned(
              right: 10,
              bottom: 10,
              child: _MapToggleButton(
                expanded: _expanded,
                onTap: () => setState(() => _expanded = !_expanded),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Small circular badge shared by the start/finish markers — same chrome
/// (white ring, drop shadow, centered icon) as `RouteCreatePage._PinMarker`,
/// just parameterized on color/icon instead of a waypoint number.
class _EndpointPin extends StatelessWidget {
  final IconData icon;
  final Color background;
  final Color iconColor;

  const _EndpointPin({
    required this.icon,
    required this.background,
    required this.iconColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: background,
        border: Border.all(color: Colors.white, width: 2.5),
        boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4)],
      ),
      alignment: Alignment.center,
      child: Icon(icon, size: 16, color: iconColor),
    );
  }
}

/// Same round white Material button shape as `RouteCreatePage._RoundMapButton`
/// (duplicated rather than shared — see this file's other small
/// presentational widgets), toggling [_RunPathPreviewMapState._expanded].
class _MapToggleButton extends StatelessWidget {
  final bool expanded;
  final VoidCallback onTap;

  const _MapToggleButton({required this.expanded, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: expanded ? 'Collapse map' : 'Expand map',
      child: Material(
        color: Colors.white,
        shape: const CircleBorder(),
        elevation: 2,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Icon(
              expanded
                  ? Icons.close_fullscreen_rounded
                  : Icons.open_in_full_rounded,
              color: const Color(0xFF425143),
              size: 18,
            ),
          ),
        ),
      ),
    );
  }
}

/// Same pill shape/palette as `AreaDetailsSheet._Stat` — duplicated rather
/// than shared for two call sites, matching how small presentational
/// helpers already live per-file in this codebase (e.g. `_formatDate`/
/// `_formatDuration` above).
class _StatPill extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _StatPill({required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFF0F2EB),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: const Color(0xFF4A8C52)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(fontSize: 12, color: Color(0xFF5E655C)),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: Color(0xFF1F3020),
            ),
          ),
        ],
      ),
    );
  }
}

class _FavoriteButton extends StatelessWidget {
  final bool enabled;
  final bool isFavorited;
  final bool isLoading;
  final VoidCallback onTap;

  const _FavoriteButton({
    required this.enabled,
    required this.isFavorited,
    required this.isLoading,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ElevatedButton.icon(
      onPressed: (enabled && !isLoading) ? onTap : null,
      icon: isLoading
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Color(0xFF2E7D32),
              ),
            )
          : Icon(isFavorited ? Icons.bookmark : Icons.bookmark_border, size: 18),
      label: Text(isFavorited ? 'Unfavourite' : 'Add to favourites'),
      style: ElevatedButton.styleFrom(
        backgroundColor: isFavorited ? const Color(0xFFCAF0B8) : Colors.white,
        foregroundColor: const Color(0xFF2E7D32),
        disabledBackgroundColor: Colors.white,
        disabledForegroundColor: const Color(0xFFB9C2B5),
        elevation: 0,
        side: BorderSide(
          color: isFavorited ? Colors.transparent : const Color(0xFFCFCFCF),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }
}
