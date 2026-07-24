import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../config/map_style.dart';
import '../services/cached_tile_provider.dart';
import '../services/claimed_area_repository.dart';
import '../services/location_service.dart';
import '../services/place_search_service.dart';
import '../services/routing_service.dart';
import '../widgets/map/area_visibility_toggle.dart';
import '../widgets/map/claimed_areas_layer.dart';
import '../widgets/map/enhanced_map_gestures.dart';

// ── Data models ────────────────────────────────────────────────────────────────

class _FoundRoute {
  final List<LatLng> polyline;
  final double distanceKm;
  final double estimatedTimeMin;
  final double estimatedCalories;
  final Color color;

  const _FoundRoute({
    required this.polyline,
    required this.distanceKm,
    required this.estimatedTimeMin,
    required this.estimatedCalories,
    required this.color,
  });

  LatLng get midpoint => polyline[polyline.length ~/ 2];
}

// ── Page ───────────────────────────────────────────────────────────────────────

class RouteSearchPage extends StatefulWidget {
  const RouteSearchPage({super.key});

  @override
  State<RouteSearchPage> createState() => _RouteSearchPageState();
}

class _RouteSearchPageState extends State<RouteSearchPage> {
  // ── Map ───────────────────────────────────────────────────────────────────
  final MapController _mapController = MapController();
  LatLng? _currentPosition;
  bool _isLoadingLocation = true;
  StreamSubscription<LatLng>? _positionSub;


  // ── Claimed areas (display only — no tap-to-view here; see explore_page) ──
  List<ClaimedArea> _allAreas = [];
  bool _showOtherAreas = true;
  bool _showMyAreas = true;

  List<ClaimedArea> get _visibleAreas {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    return _allAreas.where((area) {
      final isMine = area.userId == uid;
      return isMine ? _showMyAreas : _showOtherAreas;
    }).toList();
  }

  // ── Bottom sheet ──────────────────────────────────────────────────────────
  final DraggableScrollableController _sheetController =
      DraggableScrollableController();

  // ── Form state ────────────────────────────────────────────────────────────
  bool _isClosedCircuit = false;

  bool _useCurrentPositionAsStart = true;
  final TextEditingController _startCtrl = TextEditingController();
  LatLng? _startLatLng; // pre-resolved from suggestion

  bool _useCurrentPositionAsDest = false;
  final TextEditingController _destCtrl = TextEditingController();
  LatLng? _destLatLng;

  final List<TextEditingController> _stopCtrls = [];
  final List<LatLng?> _stopLatLngs = [];

  final TextEditingController _timeCtrl = TextEditingController();
  final TextEditingController _distCtrl = TextEditingController();
  final TextEditingController _calCtrl = TextEditingController();

  // ── Result / UI state ─────────────────────────────────────────────────────
  bool _isSearching = false;
  List<_FoundRoute> _foundRoutes = [];
  bool _hasSearched = false;

  // true while routes are displayed on the map; form fields are read-only
  bool _isResultsMode = false;

  // index of the route the user last tapped (highlighted on map), -1 = none
  int _selectedRouteIndex = -1;

  // ── Constants ─────────────────────────────────────────────────────────────

  static const double _defaultZoom = 14.0;
  static const double _paceMinPerKm = 9.0;   // magic default
  static const double _calPerKm = 70.0;       // magic default
  static const double _tolerance = 0.30;

  static const List<Color> _palette = [
    Color(0xFF2E7D32),
    Color(0xFF1565C0),
    Color(0xFFE65100),
    Color(0xFF6A1B9A),
    Color(0xFF00695C),
    Color(0xFFAD1457),
  ];

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _initLocation();
    _loadClaimedAreas();
  }

  Future<void> _loadClaimedAreas() async {
    final areas = await ClaimedAreaRepository.instance.fetchAllAreas();
    if (!mounted) return;
    setState(() => _allAreas = areas);
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    _mapController.dispose();
    _sheetController.dispose();
    for (final c in [
      _startCtrl, _destCtrl,
      _timeCtrl, _distCtrl, _calCtrl,
    ]) {
      c.dispose();
    }
    for (final c in _stopCtrls) {
      c.dispose();
    }
    super.dispose();
  }

  // ── Location ──────────────────────────────────────────────────────────────

  /// Uses the app-wide [LocationService] instead of requesting a fresh fix
  /// itself — usually already warm by the time this page opens, since
  /// `HomeScreen` starts it right after login, so there's nothing to wait on.
  Future<void> _initLocation() async {
    await LocationService.instance.start();
    if (!mounted) return;

    final cached = LocationService.instance.current;
    setState(() {
      _currentPosition = cached;
      _isLoadingLocation = false;
    });
    if (cached != null) {
      _mapController.move(cached, _defaultZoom);
    }

    _positionSub = LocationService.instance.updates.listen((pos) {
      setState(() => _currentPosition = pos);
    });
  }

  // ── Geocoding ─────────────────────────────────────────────────────────────

  Future<LatLng?> _geocode(String address) async {
    try {
      final uri = Uri.parse(
        'https://nominatim.openstreetmap.org/search'
        '?q=${Uri.encodeComponent(address.trim())}&format=json&limit=1',
      );
      final res = await http
          .get(uri, headers: {'User-Agent': 'DashApp/1.0'})
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return null;
      final list = jsonDecode(res.body) as List<dynamic>;
      if (list.isEmpty) return null;
      final item = list[0] as Map<String, dynamic>;
      return LatLng(double.parse(item['lat'] as String),
          double.parse(item['lon'] as String));
    } catch (_) {
      return null;
    }
  }

  Future<LatLng?> _resolveStart() async {
    if (_useCurrentPositionAsStart) return _currentPosition;
    if (_startLatLng != null) return _startLatLng;
    if (_startCtrl.text.trim().isEmpty) return null;
    return _geocode(_startCtrl.text);
  }

  Future<LatLng?> _resolveDestination() async {
    if (_useCurrentPositionAsDest) return _currentPosition;
    if (_destLatLng != null) return _destLatLng;
    if (_destCtrl.text.trim().isEmpty) return null;
    return _geocode(_destCtrl.text);
  }

  Future<List<LatLng>> _resolveStops() async {
    final resolved = <LatLng>[];
    for (int i = 0; i < _stopCtrls.length; i++) {
      final cached = _stopLatLngs[i];
      if (cached != null) {
        resolved.add(cached);
      } else if (_stopCtrls[i].text.trim().isNotEmpty) {
        final ll = await _geocode(_stopCtrls[i].text);
        if (ll != null) resolved.add(ll);
      }
    }
    return resolved;
  }

  // ── Constraint resolution ─────────────────────────────────────────────────

  ({bool isConflict, bool isEmpty, double? targetKm}) _deriveTarget() {
    final double? fromTime = double.tryParse(_timeCtrl.text.trim()) != null
        ? double.parse(_timeCtrl.text.trim()) / _paceMinPerKm
        : null;
    final double? fromDist = double.tryParse(_distCtrl.text.trim());
    final double? fromCal = double.tryParse(_calCtrl.text.trim()) != null
        ? double.parse(_calCtrl.text.trim()) / _calPerKm
        : null;

    final targets =
        [fromTime, fromDist, fromCal].whereType<double>().toList();

    if (targets.isEmpty) return (isConflict: false, isEmpty: true, targetKm: null);

    if (targets.length > 1) {
      final minV = targets.reduce(math.min);
      final maxV = targets.reduce(math.max);
      if (minV > 0 && (maxV - minV) / minV > _tolerance) {
        return (isConflict: true, isEmpty: false, targetKm: null);
      }
    }

    final avg = targets.reduce((a, b) => a + b) / targets.length;
    return (isConflict: false, isEmpty: false, targetKm: avg);
  }

  // ── Geometry ──────────────────────────────────────────────────────────────

  LatLng _offset(LatLng center, double distanceM, double bearingDeg) {
    final rad = bearingDeg * math.pi / 180;
    const mPerLat = 110540.0;
    final mPerLng = 111320.0 * math.cos(center.latitude * math.pi / 180);
    return LatLng(
      center.latitude + (distanceM * math.cos(rad)) / mPerLat,
      center.longitude + (distanceM * math.sin(rad)) / mPerLng,
    );
  }

  // ── Routing helpers ───────────────────────────────────────────────────────

  Future<RouteSegment> _route(LatLng from, LatLng to) async =>
      await RoutingService.fetchRoute(from, to) ??
      RoutingService.straightLine(from, to);

  RouteSegment _stitch(RouteSegment a, RouteSegment b) => RouteSegment(
        polyline: [...a.polyline, ...b.polyline.skip(1)],
        distanceMeters: a.distanceMeters + b.distanceMeters,
      );

  _FoundRoute _toFoundRoute(RouteSegment seg, int index) {
    final km = seg.distanceMeters / 1000;
    return _FoundRoute(
      polyline: seg.polyline,
      distanceKm: km,
      estimatedTimeMin: km * _paceMinPerKm,
      estimatedCalories: km * _calPerKm,
      color: _palette[index % _palette.length],
    );
  }

  // ── Results mode ──────────────────────────────────────────────────────────

  void _enterEditMode() {
    for (final c in _stopCtrls) { c.dispose(); }
    _stopCtrls.clear();
    _stopLatLngs.clear();
    setState(() {
      _isResultsMode = false;
      _hasSearched = false;
      _foundRoutes = [];
      _selectedRouteIndex = -1;
    });
    if (_sheetController.isAttached) {
      _sheetController.animateTo(_sheetMidSize,
          duration: const Duration(milliseconds: 350), curve: Curves.easeOut);
    }
  }

  // ── Search entry point ────────────────────────────────────────────────────

  Future<void> _search() async {
    FocusScope.of(context).unfocus();

    final start = await _resolveStart();
    if (start == null) {
      _snack('Could not resolve starting point');
      return;
    }

    final target = _deriveTarget();

    // Closed circuit requires a distance/time/calorie target so the loop
    // generator knows how far to travel.
    if (_isClosedCircuit && target.isEmpty) {
      _snack('Set at least one parameter for a closed circuit');
      return;
    }

    if (target.isConflict) {
      _snack('Constraints conflict — remove one value and try again');
      return;
    }

    setState(() {
      _isSearching = true;
      _foundRoutes = [];
      _hasSearched = false;
      _selectedRouteIndex = -1;
    });

    List<_FoundRoute> routes;

    if (_isClosedCircuit) {
      routes = await _generateLoopRoutes(start, target.targetKm! * 1000);
    } else {
      final end = await _resolveDestination();
      if (end == null) {
        if (mounted) setState(() => _isSearching = false);
        _snack('Could not resolve destination');
        return;
      }
      final stops = await _resolveStops();
      // targetDistM is null when no constraints → show ORS alternatives freely
      routes = await _generateDirectRoutes(
          start, stops, end, target.targetKm?.let((km) => km * 1000));
    }

    if (!mounted) return;
    setState(() {
      _isSearching = false;
      _foundRoutes = routes;
      _hasSearched = true;
      _isResultsMode = routes.isNotEmpty;
    });

    if (routes.isNotEmpty) {
      _collapseSheet();
      _fitMap(routes);
    }
  }

  // ── Loop route generation ──────────────────────────────────────────────────
  //
  // Places two intermediate waypoints at radius = D × 0.25 from start, 90°
  // apart, and routes start → wp1 → wp2 → start.  Eight candidate bearings
  // (every 45°) are evaluated in parallel to produce geometrically distinct
  // loops.  Routes within ±30 % of the target distance are kept (up to 5).

  Future<List<_FoundRoute>> _generateLoopRoutes(
      LatLng start, double targetDistM) async {
    final radius = targetDistM * 0.25;

    final candidates = await Future.wait(
      List.generate(8, (i) async {
        final theta = i * 45.0;
        final wp1 = _offset(start, radius, theta);
        final wp2 = _offset(start, radius, theta + 90.0);
        final s1 = await _route(start, wp1);
        final s2 = await _route(wp1, wp2);
        final s3 = await _route(wp2, start);
        return _stitch(_stitch(s1, s2), s3);
      }),
    );

    final results = <_FoundRoute>[];
    for (final seg in candidates) {
      final ratio = seg.distanceMeters / targetDistM;
      if (ratio < 1 - _tolerance || ratio > 1 + _tolerance) continue;
      results.add(_toFoundRoute(seg, results.length));
      if (results.length >= 5) break;
    }
    return results;
  }

  // ── Direct (A → B) route generation ───────────────────────────────────────

  Future<List<_FoundRoute>> _generateDirectRoutes(
    LatLng start,
    List<LatLng> stops, // empty → no intermediate stops
    LatLng end,
    double? targetDistM, // null → no constraint, show all alternatives
  ) async {
    // When stops are specified, route through them sequentially (single result).
    if (stops.isNotEmpty) {
      final waypoints = [start, ...stops, end];
      var full = await _route(waypoints[0], waypoints[1]);
      for (int i = 1; i < waypoints.length - 1; i++) {
        full = _stitch(full, await _route(waypoints[i], waypoints[i + 1]));
      }
      if (targetDistM != null) {
        final ratio = full.distanceMeters / targetDistM;
        if (ratio < 1 - _tolerance || ratio > 1 + _tolerance) return [];
      }
      return [_toFoundRoute(full, 0)];
    }

    // No stops: use ORS alternative routes endpoint for up to 3 results.
    final alternatives = await RoutingService.fetchAlternatives(start, end);

    if (targetDistM == null) {
      // No constraints — return all alternatives as-is.
      return alternatives.asMap().entries
          .map((e) => _toFoundRoute(e.value, e.key))
          .toList();
    }

    // Filter by ±30 % tolerance.
    final results = <_FoundRoute>[];
    for (final seg in alternatives) {
      final ratio = seg.distanceMeters / targetDistM;
      if (ratio < 1 - _tolerance || ratio > 1 + _tolerance) continue;
      results.add(_toFoundRoute(seg, results.length));
    }
    return results;
  }

  // ── Map helpers ───────────────────────────────────────────────────────────

  void _centerOnUser() {
    if (_currentPosition != null) {
      _mapController.move(_currentPosition!, _defaultZoom);
    }
  }

  void _collapseSheet() {
    if (!_sheetController.isAttached) return;
    _sheetController.animateTo(_sheetMinSize,
        duration: const Duration(milliseconds: 350), curve: Curves.easeOut);
  }

  // ── Bottom sheet drag ─────────────────────────────────────────────────────
  //
  // The drag handle + header sit outside the ListView (see `_buildSheet`), so
  // without this they'd be inert — only the list content participates in
  // DraggableScrollableSheet's own scroll-driven drag handling. This drives
  // the sheet directly from drag deltas on that non-scrollable region
  // instead, so grabbing the handle/header (not just the form content below)
  // resizes the sheet too.

  static const double _sheetMinSize = 0.12;
  static const double _sheetMidSize = 0.52;
  static const double _sheetMaxSize = 0.90;
  static const List<double> _sheetSnapSizes = [
    _sheetMinSize,
    _sheetMidSize,
    _sheetMaxSize,
  ];

  void _onHeaderDragUpdate(DragUpdateDetails details) {
    if (!_sheetController.isAttached) return;
    final screenHeight = MediaQuery.of(context).size.height;
    final delta = details.primaryDelta! / screenHeight;
    final newSize =
        (_sheetController.size - delta).clamp(_sheetMinSize, _sheetMaxSize);
    _sheetController.jumpTo(newSize);
  }

  /// Snaps to the nearest of the sheet's own snap sizes on release,
  /// mirroring `snap: true`'s behaviour for the ListView-driven drag — a
  /// manual `jumpTo` during the drag above doesn't go through that logic.
  void _onHeaderDragEnd(DragEndDetails details) {
    if (!_sheetController.isAttached) return;
    final current = _sheetController.size;
    final nearest = _sheetSnapSizes.reduce(
        (a, b) => (a - current).abs() < (b - current).abs() ? a : b);
    _sheetController.animateTo(nearest,
        duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
  }

  void _fitMap(List<_FoundRoute> routes) {
    final pts = routes.expand((r) => r.polyline).toList();
    if (pts.isEmpty) return;

    var minLat = pts.first.latitude, maxLat = pts.first.latitude;
    var minLng = pts.first.longitude, maxLng = pts.first.longitude;
    for (final p in pts) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLng) minLng = p.longitude;
      if (p.longitude > maxLng) maxLng = p.longitude;
    }

    _mapController.fitCamera(
      CameraFit.bounds(
        bounds: LatLngBounds(
            LatLng(minLat, minLng), LatLng(maxLat, maxLng)),
        padding: const EdgeInsets.fromLTRB(48, 120, 48, 220),
      ),
    );
  }

  Widget _buildMapButtons() {
    return Positioned(
      top: MediaQuery.of(context).padding.top + 12,
      right: 12,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _RoundMapButton(
            icon: Icons.explore_outlined,
            tooltip: 'Reset north',
            onTap: () => _mapController.rotate(0),
          ),
          const SizedBox(height: 8),
          _RoundMapButton(
            icon: Icons.my_location,
            tooltip: 'My location',
            onTap: _centerOnUser,
          ),
          const SizedBox(height: 8),
          AreaVisibilityToggle(
            showOtherAreas: _showOtherAreas,
            showMyAreas: _showMyAreas,
            onShowOtherAreasChanged: (v) => setState(() => _showOtherAreas = v),
            onShowMyAreasChanged: (v) => setState(() => _showMyAreas = v),
          ),
        ],
      ),
    );
  }

  void _selectRoute(int index) {
    setState(() => _selectedRouteIndex = index);
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => _RouteDetailsSheet(
        route: _foundRoutes[index],
        routeNumber: index + 1,
      ),
    );
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          _buildMap(),
          if (_isLoadingLocation) _buildLoadingOverlay(),
          _buildSheet(),
          _buildBackButton(),
          _buildMapButtons(),
        ],
      ),
    );
  }

  // ── Map layer ─────────────────────────────────────────────────────────────

  Widget _buildMap() {
    final hasSelection = _selectedRouteIndex >= 0 &&
        _selectedRouteIndex < _foundRoutes.length;

    return EnhancedMapGestures(
      mapController: _mapController,
      child: FlutterMap(
        mapController: _mapController,
        options: MapOptions(
          initialCenter: _currentPosition ?? const LatLng(45.4642, 9.1900),
          initialZoom: _defaultZoom,
          // Rotate is handled by the wrapping EnhancedMapGestures instead
          // (dead-zoned two-finger rotate + a little zoom inertia, shared
          // with every other map screen; see that widget).
          interactionOptions: const InteractionOptions(
            flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
          ),
          onTap: (tapPos, point) {
            FocusScope.of(context).unfocus();
            // Tapping the map background clears the route highlight.
            if (_selectedRouteIndex != -1) {
              setState(() => _selectedRouteIndex = -1);
            }
          },
        ),
        children: [
          TileLayer(
            urlTemplate: MapStyle.terrainTileUrl,
            userAgentPackageName: 'com.dash',
            retinaMode: RetinaMode.isHighDensity(context),
            tileProvider: CachedTileProvider.instance,
          ),

          // ── Claimed areas (display only) ────────────────────────────────
          ClaimedAreasLayer(areas: _visibleAreas),

          // ── Dimmed non-selected routes (rendered first, below) ────────────
          if (_foundRoutes.isNotEmpty && hasSelection)
            PolylineLayer(
              polylines: _foundRoutes.asMap().entries
                  .where((e) => e.key != _selectedRouteIndex)
                  .map((e) => Polyline(
                        points: e.value.polyline,
                        color: e.value.color.withValues(alpha: 0.25),
                        strokeWidth: 3.0,
                      ))
                  .toList(),
            ),

          // ── All routes at full opacity (when nothing is selected) ──────────
          if (_foundRoutes.isNotEmpty && !hasSelection)
            PolylineLayer(
              polylines: _foundRoutes
                  .map((r) => Polyline(
                        points: r.polyline,
                        color: r.color,
                        strokeWidth: 4.5,
                      ))
                  .toList(),
            ),

          // ── Selected route on top, with white border for contrast ─────────
          if (hasSelection)
            PolylineLayer(
              polylines: [
                Polyline(
                  points: _foundRoutes[_selectedRouteIndex].polyline,
                  color: _foundRoutes[_selectedRouteIndex].color,
                  strokeWidth: 6.5,
                  borderColor: Colors.white,
                  borderStrokeWidth: 2.0,
                ),
              ],
            ),

          // ── GPS dot ───────────────────────────────────────────────────────
          if (_currentPosition != null)
            MarkerLayer(
              markers: [
                Marker(
                  point: _currentPosition!,
                  width: 60,
                  height: 60,
                  child: const _LocationDot(),
                ),
              ],
            ),

          // ── Numbered tap-targets at route midpoints ───────────────────────
          if (_foundRoutes.isNotEmpty)
            MarkerLayer(
              markers: _foundRoutes.asMap().entries.map((e) {
                final idx = e.key;
                final route = e.value;
                final isSelected = idx == _selectedRouteIndex;
                return Marker(
                  point: route.midpoint,
                  width: 38,
                  height: 38,
                  child: GestureDetector(
                    onTap: () => _selectRoute(idx),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: isSelected
                            ? route.color
                            : route.color.withValues(
                                alpha: _selectedRouteIndex == -1 ? 1.0 : 0.45),
                        border: Border.all(
                          color: Colors.white,
                          width: isSelected ? 3.0 : 2.0,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black26,
                            blurRadius: isSelected ? 8 : 4,
                          ),
                        ],
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        '${idx + 1}',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: isSelected ? 14 : 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
        ],
      ),
    );
  }

  // ── Back button ───────────────────────────────────────────────────────────

  Widget _buildBackButton() {
    return Positioned(
      top: MediaQuery.of(context).padding.top + 12,
      left: 12,
      child: Material(
        color: Colors.white,
        shape: const CircleBorder(),
        elevation: 2,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: () => Navigator.of(context).pop(),
          child: const Padding(
            padding: EdgeInsets.all(10),
            child:
                Icon(Icons.arrow_back, color: Color(0xFF425143), size: 22),
          ),
        ),
      ),
    );
  }

  // ── Bottom sheet ──────────────────────────────────────────────────────────

  Widget _buildSheet() {
    return DraggableScrollableSheet(
      controller: _sheetController,
      initialChildSize: _sheetMidSize,
      minChildSize: _sheetMinSize,
      maxChildSize: _sheetMaxSize,
      snap: true,
      snapSizes: _sheetSnapSizes,
      builder: (context, scrollController) => Container(
        decoration: const BoxDecoration(
          color: Color(0xFFF3F5EE),
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 10)],
        ),
        child: Column(
          children: [
            // Drag handle + header — outside the ListView below, so they'd
            // otherwise be inert (only the list content participates in
            // DraggableScrollableSheet's own scroll-driven drag handling).
            // A manual vertical-drag handler here drives the sheet directly,
            // so grabbing the handle or header (not just the form content)
            // resizes it, matching where users instinctively grab a sheet.
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onVerticalDragUpdate: _onHeaderDragUpdate,
              onVerticalDragEnd: _onHeaderDragEnd,
              child: Column(
                children: [
                  // Drag handle
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.grey[300],
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  // Header row
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                    child: Row(
                      children: [
                        const Text(
                          'Search a route',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFF2A3028),
                          ),
                        ),
                        const Spacer(),
                        // Loading spinner while searching
                        if (_isSearching)
                          const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Color(0xFF4A8C52)),
                          )
                        // "N found" badge in results mode
                        else if (_hasSearched && !_isResultsMode)
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: _foundRoutes.isNotEmpty
                                  ? const Color(0xFFEAF7E0)
                                  : const Color(0xFFF0F0F0),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text(
                              '${_foundRoutes.length} found',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: _foundRoutes.isNotEmpty
                                    ? const Color(0xFF2E7D32)
                                    : Colors.grey,
                              ),
                            ),
                          )
                        // "Edit search" button in results mode
                        else if (_isResultsMode)
                          TextButton.icon(
                            onPressed: _enterEditMode,
                            icon: const Icon(Icons.edit_outlined, size: 16),
                            label: const Text('Edit search'),
                            style: TextButton.styleFrom(
                              foregroundColor: const Color(0xFF4A8C52),
                              padding: EdgeInsets.zero,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            // Form content
            Expanded(
              child: ListView(
                controller: scrollController,
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 40),
                children: [
                  _buildCircuitToggle(),
                  const SizedBox(height: 16),
                  _buildStartSection(),
                  if (!_isClosedCircuit) ...[
                    const SizedBox(height: 16),
                    _buildDestinationSection(),
                  ],
                  const SizedBox(height: 16),
                  _buildIntermediateStopSection(),
                  const SizedBox(height: 20),
                  _buildParametersSection(),
                  const SizedBox(height: 24),
                  _buildBottomRow(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Form sections ─────────────────────────────────────────────────────────

  Widget _buildCircuitToggle() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: _isResultsMode ? const Color(0xFFEEEEEE) : Colors.white,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(Icons.loop_rounded,
              size: 20,
              color: _isResultsMode
                  ? Colors.grey
                  : const Color(0xFF4A8C52)),
          const SizedBox(width: 10),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Search for a closed circuit',
                    style: TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w500)),
                Text('Route must form a loop back to start',
                    style:
                        TextStyle(fontSize: 11, color: Colors.grey)),
              ],
            ),
          ),
          Switch(
            value: _isClosedCircuit,
            onChanged:
                _isResultsMode ? null : (v) => setState(() => _isClosedCircuit = v),
            activeThumbColor: const Color(0xFF4A8C52),
          ),
        ],
      ),
    );
  }

  Widget _buildStartSection() {
    return _FormSection(
      label: 'Starting point',
      child: _useCurrentPositionAsStart
          ? _LocationChip(
              enabled: !_isResultsMode,
              onEdit: _isResultsMode
                  ? null
                  : () => setState(() => _useCurrentPositionAsStart = false),
            )
          : _AddressInputField(
              controller: _startCtrl,
              hint: 'Enter an address',
              enabled: !_isResultsMode,
              near: _currentPosition,
              onUseLocation: _isResultsMode
                  ? null
                  : () => setState(() => _useCurrentPositionAsStart = true),
              onSuggestionPicked: (ll) => setState(() => _startLatLng = ll),
            ),
    );
  }

  Widget _buildDestinationSection() {
    return _FormSection(
      label: 'Destination',
      child: _useCurrentPositionAsDest
          ? _LocationChip(
              enabled: !_isResultsMode,
              onEdit: _isResultsMode
                  ? null
                  : () => setState(() => _useCurrentPositionAsDest = false),
            )
          : _AddressInputField(
              controller: _destCtrl,
              hint: 'Enter an address',
              enabled: !_isResultsMode,
              near: _currentPosition,
              onUseLocation: _isResultsMode
                  ? null
                  : () => setState(() => _useCurrentPositionAsDest = true),
              onSuggestionPicked: (ll) => setState(() => _destLatLng = ll),
            ),
    );
  }

  void _addStop() {
    setState(() {
      _stopCtrls.add(TextEditingController());
      _stopLatLngs.add(null);
    });
  }

  void _removeStop(int index) {
    final ctrl = _stopCtrls.removeAt(index);
    _stopLatLngs.removeAt(index);
    ctrl.dispose();
    setState(() {});
  }

  Widget _buildIntermediateStopSection() {
    return _FormSection(
      label: 'Intermediate stops',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // One field per added stop
          for (int i = 0; i < _stopCtrls.length; i++) ...[
            if (i > 0) const SizedBox(height: 8),
            _AddressInputField(
              controller: _stopCtrls[i],
              hint: 'Stop ${i + 1}',
              enabled: !_isResultsMode,
              near: _currentPosition,
              onRemove: _isResultsMode ? null : () => _removeStop(i),
              onSuggestionPicked: (ll) =>
                  setState(() => _stopLatLngs[i] = ll),
            ),
          ],
          // "Add a stop" button — always visible below the last field
          if (!_isResultsMode) ...[
            if (_stopCtrls.isNotEmpty) const SizedBox(height: 8),
            GestureDetector(
              onTap: _addStop,
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  border: Border.all(
                      color: const Color(0xFFCAF0B8), width: 1.5),
                  borderRadius: BorderRadius.circular(10),
                  color: Colors.white,
                ),
                child: const Row(
                  children: [
                    Icon(Icons.add_circle_outline,
                        size: 18, color: Color(0xFF4A8C52)),
                    SizedBox(width: 8),
                    Text('Add a stop',
                        style: TextStyle(
                            color: Color(0xFF4A8C52), fontSize: 14)),
                  ],
                ),  // Row
              ),    // Container
            ),      // GestureDetector
          ],        // if (!_isResultsMode)
        ],          // Column children
      ),            // Column
    );              // _FormSection
  }

  Widget _buildParametersSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text(
              'Session parameters',
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF5E655C)),
            ),
            if (_isClosedCircuit) ...[
              const SizedBox(width: 6),
              const Text(
                '(required for loops)',
                style: TextStyle(fontSize: 11, color: Color(0xFFE65100)),
              ),
            ],
          ],
        ),
        const SizedBox(height: 2),
        const Text(
          'Defaults: 9 min/km · 70 kcal/km',
          style: TextStyle(fontSize: 11, color: Colors.grey),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
                child: _ParamField(
                    controller: _timeCtrl,
                    hint: 'Time',
                    unit: 'min',
                    enabled: !_isResultsMode)),
            const SizedBox(width: 8),
            Expanded(
                child: _ParamField(
                    controller: _distCtrl,
                    hint: 'Distance',
                    unit: 'km',
                    enabled: !_isResultsMode)),
            const SizedBox(width: 8),
            Expanded(
                child: _ParamField(
                    controller: _calCtrl,
                    hint: 'Calories',
                    unit: 'kcal',
                    enabled: !_isResultsMode)),
          ],
        ),
      ],
    );
  }

  Widget _buildBottomRow() {
    final n = _foundRoutes.length;
    final label =
        _isClosedCircuit ? 'Total circuits found' : 'Total routes found';

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        ElevatedButton.icon(
          onPressed: (_isSearching || _isResultsMode) ? null : _search,
          icon: const Icon(Icons.search_rounded, size: 18),
          label: const Text('Show track'),
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFFCAF0B8),
            foregroundColor: const Color(0xFF2E7D32),
            disabledBackgroundColor: const Color(0xFFE0E0E0),
            elevation: 0,
            padding:
                const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12)),
            textStyle: const TextStyle(
                fontWeight: FontWeight.w600, fontSize: 14),
          ),
        ),
        const Spacer(),
        if (_hasSearched || _isSearching)
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label,
                  style: const TextStyle(
                      fontSize: 11, color: Colors.grey)),
              Text(
                _isSearching ? '…' : '$n',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  color: n > 0
                      ? const Color(0xFF2E7D32)
                      : const Color(0xFF9E9E9E),
                ),
              ),
            ],
          ),
      ],
    );
  }

  // ── Loading overlay ───────────────────────────────────────────────────────

  Widget _buildLoadingOverlay() {
    return Container(
      color: Colors.black45,
      child: const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: Colors.white),
            SizedBox(height: 12),
            Text('Getting your location…',
                style: TextStyle(color: Colors.white, fontSize: 16)),
          ],
        ),
      ),
    );
  }
}

// ── Extension for nullable chaining ───────────────────────────────────────────

extension _Let<T> on T {
  R let<R>(R Function(T) block) => block(this);
}

// ── Form helper widgets ────────────────────────────────────────────────────────

class _FormSection extends StatelessWidget {
  final String label;
  final Widget child;
  const _FormSection({required this.label, required this.child});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Color(0xFF5E655C))),
        const SizedBox(height: 6),
        child,
      ],
    );
  }
}

class _LocationChip extends StatelessWidget {
  final VoidCallback? onEdit;
  final bool enabled;
  const _LocationChip({required this.onEdit, this.enabled = true});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onEdit,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color:
              enabled ? const Color(0xFFEAF7E0) : const Color(0xFFF0F0F0),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: enabled
                ? const Color(0xFF4A8C52)
                : Colors.grey.shade300,
            width: 1.0,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.my_location,
                size: 16,
                color: enabled
                    ? const Color(0xFF4A8C52)
                    : Colors.grey),
            const SizedBox(width: 6),
            Text('Current position',
                style: TextStyle(
                    color: enabled
                        ? const Color(0xFF4A8C52)
                        : Colors.grey,
                    fontSize: 14)),
            const SizedBox(width: 10),
            Icon(Icons.edit_outlined,
                size: 14,
                color: enabled
                    ? const Color(0xFF4A8C52)
                    : Colors.grey),
          ],
        ),
      ),
    );
  }
}

// ── Address input with Nominatim autocomplete ──────────────────────────────────

class _AddressInputField extends StatefulWidget {
  final TextEditingController controller;
  final String hint;
  final bool enabled;
  final VoidCallback? onUseLocation;
  final VoidCallback? onRemove;
  final void Function(LatLng? latLng) onSuggestionPicked;

  /// Biases/ranks suggestions toward this position (usually the user's GPS
  /// fix) — see [PlaceSearchService.search]. Null just means no bias.
  final LatLng? near;

  const _AddressInputField({
    required this.controller,
    required this.hint,
    required this.onSuggestionPicked,
    this.enabled = true,
    this.onUseLocation,
    this.onRemove,
    this.near,
  });

  @override
  State<_AddressInputField> createState() => _AddressInputFieldState();
}

class _AddressInputFieldState extends State<_AddressInputField> {
  final FocusNode _focusNode = FocusNode();
  Timer? _debounce;
  List<Place> _suggestions = [];
  bool _showSuggestions = false;

  // Guards against the listener re-firing when text is set programmatically
  // (after tapping a suggestion).
  bool _suppressNextChange = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onTextChanged);
    _focusNode.addListener(() {
      if (!_focusNode.hasFocus && mounted) {
        setState(() => _showSuggestions = false);
      }
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _focusNode.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    if (_suppressNextChange) {
      _suppressNextChange = false;
      return;
    }
    // Invalidate any previously selected suggestion LatLng.
    widget.onSuggestionPicked(null);

    _debounce?.cancel();
    final text = widget.controller.text.trim();
    if (text.length < 3) {
      if (mounted) setState(() { _suggestions = []; _showSuggestions = false; });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 350),
        () => _fetchSuggestions(text));
  }

  /// Delegates to [PlaceSearchService.search] (Nominatim + Overpass POI
  /// fallback, re-ranked by text-match quality/importance/proximity — the
  /// same pipeline route creation's place search uses) and applies each
  /// emission as it arrives, bailing out if the field's text has moved on
  /// to a different query since.
  Future<void> _fetchSuggestions(String query) async {
    await for (final results
        in PlaceSearchService.search(query, near: widget.near, limit: 5)) {
      if (!mounted || widget.controller.text.trim() != query) return;
      setState(() {
        _suggestions = results;
        _showSuggestions = results.isNotEmpty && _focusNode.hasFocus;
      });
    }
  }

  void _selectSuggestion(Place result) {
    _debounce?.cancel();
    _suppressNextChange = true;
    // Set text + selection together in one `.value` assignment rather than
    // as two separate `.text =` / `.selection =` assignments — each of
    // those fires the controller's listener independently, and
    // `_suppressNextChange` only survives the first. The second,
    // unsuppressed firing would schedule a real debounced fetch for the
    // full place name — since it's basically guaranteed to match itself,
    // that would repopulate `_suggestions` a moment later even after this
    // method already unfocused the field and moved on.
    widget.controller.value = TextEditingValue(
      text: result.displayName,
      selection: TextSelection.collapsed(offset: result.displayName.length),
    );
    setState(() { _showSuggestions = false; _suggestions = []; });
    widget.onSuggestionPicked(result.latLng);
    _focusNode.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: widget.controller,
          focusNode: _focusNode,
          enabled: widget.enabled,
          style: const TextStyle(fontSize: 14),
          decoration: InputDecoration(
            hintText: widget.hint,
            hintStyle:
                const TextStyle(color: Colors.grey, fontSize: 14),
            prefixIcon: const Icon(Icons.search, size: 18, color: Colors.grey),
            suffixIcon: widget.onUseLocation != null
                ? IconButton(
                    icon: const Icon(Icons.my_location,
                        size: 16, color: Color(0xFF4A8C52)),
                    onPressed: widget.onUseLocation,
                    tooltip: 'Use current position',
                  )
                : widget.onRemove != null
                    ? IconButton(
                        icon: const Icon(Icons.close,
                            size: 16, color: Colors.grey),
                        onPressed: widget.onRemove,
                        tooltip: 'Remove stop',
                      )
                    : null,
            filled: true,
            fillColor:
                widget.enabled ? Colors.white : const Color(0xFFF0F0F0),
            contentPadding:
                const EdgeInsets.symmetric(vertical: 10),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide.none,
            ),
          ),
        ),
        // Suggestions dropdown
        if (_showSuggestions && _suggestions.isNotEmpty)
          Material(
            elevation: 4,
            borderRadius: const BorderRadius.vertical(
                bottom: Radius.circular(10)),
            color: Colors.white,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 200),
              child: ListView.separated(
                padding: EdgeInsets.zero,
                shrinkWrap: true,
                physics: const ClampingScrollPhysics(),
                itemCount: _suggestions.length,
                separatorBuilder: (_, _) =>
                    const Divider(height: 1, indent: 12, endIndent: 12),
                itemBuilder: (_, i) {
                  final s = _suggestions[i];
                  return InkWell(
                    onTap: () => _selectSuggestion(s),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                      child: Row(
                        children: [
                          const Icon(Icons.location_on_outlined,
                              size: 15, color: Color(0xFF4A8C52)),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              s.displayName,
                              style: const TextStyle(fontSize: 12),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
      ],
    );
  }
}

class _ParamField extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final String unit;
  final bool enabled;

  const _ParamField({
    required this.controller,
    required this.hint,
    required this.unit,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      enabled: enabled,
      keyboardType:
          const TextInputType.numberWithOptions(decimal: true),
      textAlign: TextAlign.center,
      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: Colors.grey, fontSize: 11),
        suffixText: unit,
        suffixStyle: const TextStyle(color: Colors.grey, fontSize: 11),
        filled: true,
        fillColor:
            enabled ? Colors.white : const Color(0xFFF0F0F0),
        contentPadding:
            const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}

// ── Route details modal sheet ──────────────────────────────────────────────────

class _RouteDetailsSheet extends StatelessWidget {
  final _FoundRoute route;
  final int routeNumber;
  const _RouteDetailsSheet({required this.route, required this.routeNumber});

  String _formatTime(double min) {
    if (min < 60) return '${min.round()} min';
    final h = (min / 60).floor();
    final m = (min % 60).round();
    return '${h}h ${m}min';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
                color: Colors.grey[300],
                borderRadius: BorderRadius.circular(2)),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                    shape: BoxShape.circle, color: route.color),
              ),
              const SizedBox(width: 10),
              Text('Route $routeNumber',
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w700)),
            ],
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              _StatCard(
                icon: Icons.straighten_rounded,
                label: 'Distance',
                value: '${route.distanceKm.toStringAsFixed(2)} km',
              ),
              const SizedBox(width: 10),
              _StatCard(
                icon: Icons.timer_outlined,
                label: 'Est. time',
                value: _formatTime(route.estimatedTimeMin),
              ),
              const SizedBox(width: 10),
              _StatCard(
                icon: Icons.local_fire_department_outlined,
                label: 'Calories',
                value: '${route.estimatedCalories.round()} kcal',
              ),
            ],
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () {
                // TODO: save route to user's favourites/profile in Firestore
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Save coming soon!')),
                );
              },
              icon: const Icon(Icons.bookmark_border_rounded),
              label: const Text('Save route'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFCAF0B8),
                foregroundColor: const Color(0xFF2E7D32),
                elevation: 0,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
                textStyle: const TextStyle(
                    fontWeight: FontWeight.w600, fontSize: 15),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _StatCard(
      {required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        decoration: BoxDecoration(
          color: const Color(0xFFF3F5EE),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          children: [
            Icon(icon, size: 20, color: const Color(0xFF4A8C52)),
            const SizedBox(height: 6),
            Text(value,
                style: const TextStyle(
                    fontWeight: FontWeight.w700, fontSize: 13)),
            const SizedBox(height: 2),
            Text(label,
                style: const TextStyle(color: Colors.grey, fontSize: 11)),
          ],
        ),
      ),
    );
  }
}

// ── GPS dot ────────────────────────────────────────────────────────────────────

// ── Reusable round map button ──────────────────────────────────────────────────

class _RoundMapButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;

  const _RoundMapButton({
    required this.icon,
    required this.tooltip,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.white,
        shape: const CircleBorder(),
        elevation: 2,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Icon(icon, color: const Color(0xFF425143), size: 22),
          ),
        ),
      ),
    );
  }
}

class _LocationDot extends StatelessWidget {
  const _LocationDot();

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: [
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.blue.withValues(alpha: 0.2),
          ),
        ),
        Container(
          width: 16,
          height: 16,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.blue,
            border: Border.all(color: Colors.white, width: 2),
            boxShadow: const [
              BoxShadow(color: Colors.black26, blurRadius: 4),
            ],
          ),
        ),
      ],
    );
  }
}
