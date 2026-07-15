import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../config/map_style.dart';
import '../services/claimed_area_repository.dart';
import '../services/location_service.dart';
import '../services/route_repository.dart';
import '../services/routing_service.dart';
import '../utils/geometry_utils.dart';
import '../widgets/map/claimed_areas_layer.dart';

// ── History snapshot ───────────────────────────────────────────────────────────

/// Full state snapshot stored at every committed action for undo / redo.
/// All fields are deep-copied so history entries stay immutable.
class _RouteSnapshot {
  final List<LatLng> waypoints;
  final List<RouteSegment> segments;
  final bool isLoopClosed;
  final List<LatLng> loopPolygon;
  final double loopAreaM2;

  _RouteSnapshot({
    required this.waypoints,
    required this.segments,
    this.isLoopClosed = false,
    this.loopPolygon = const [],
    this.loopAreaM2 = 0.0,
  });
}

// ── Nominatim place ────────────────────────────────────────────────────────────

class _Place {
  final String displayName;
  final LatLng latLng;
  const _Place({required this.displayName, required this.latLng});
}

// ── Tool enum ──────────────────────────────────────────────────────────────────

enum _Tool { pinDrop, freeDraw }

// ── Page ───────────────────────────────────────────────────────────────────────

class RouteCreatePage extends StatefulWidget {
  const RouteCreatePage({super.key});

  @override
  State<RouteCreatePage> createState() => _RouteCreatePageState();
}

class _RouteCreatePageState extends State<RouteCreatePage> {
  // ── Map ───────────────────────────────────────────────────────────────────
  final MapController _mapController = MapController();
  LatLng? _currentPosition;
  bool _isLoadingLocation = true;
  StreamSubscription<LatLng>? _positionSub;

  // ── Claimed areas (display only — tapping the map drops a pin here) ──────
  List<ClaimedArea> _allAreas = [];

  // ── Sheet ─────────────────────────────────────────────────────────────────
  final DraggableScrollableController _sheetController =
      DraggableScrollableController();

  // ── Route state ───────────────────────────────────────────────────────────
  List<LatLng> _waypoints = [];
  List<RouteSegment> _segments = [];
  bool _isRouting = false;

  // ── Loop state ────────────────────────────────────────────────────────────
  bool _isLoopClosed = false;
  List<LatLng> _loopPolygon = [];
  double _loopAreaM2 = 0.0;

  // ── Undo / redo ───────────────────────────────────────────────────────────
  final List<_RouteSnapshot> _history = [_RouteSnapshot(waypoints: [], segments: [])];
  int _historyIndex = 0;

  bool get _canUndo => _historyIndex > 0 && !_isRouting;
  bool get _canRedo => _historyIndex < _history.length - 1 && !_isRouting;

  // ── Tools ─────────────────────────────────────────────────────────────────
  _Tool _activeTool = _Tool.pinDrop;
  bool _isDeleteMode = false;

  // ── Form ──────────────────────────────────────────────────────────────────
  final TextEditingController _trackNameCtrl = TextEditingController();
  bool _isPublishing = false;

  // ── Derived stats ─────────────────────────────────────────────────────────
  double get _totalDistanceKm =>
      _segments.fold(0.0, (s, seg) => s + seg.distanceMeters) / 1000;
  double get _estimatedTimeMin => _totalDistanceKm * 9.0;
  double get _estimatedCalories => _totalDistanceKm * 70.0;

  // ── Constants ─────────────────────────────────────────────────────────────

  static const double _defaultZoom = 15.0;

  /// A tap within this distance of an existing waypoint snaps to it.
  static const double _snapThresholdMeters = 40.0;

  /// Two ORS polylines that share an OSM node have identical coordinates;
  /// 5 m catches exact node matches while ignoring parallel roads.
  static const double _proximityThresholdMeters = 5.0;

  /// Minimum polygon area to count as a valid loop (filters back-and-forth routes).
  static const double _minLoopAreaM2 = 50.0;

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
    _trackNameCtrl.dispose();
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

  // ── History ───────────────────────────────────────────────────────────────

  void _pushHistory() {
    _history.removeRange(_historyIndex + 1, _history.length);
    _history.add(_RouteSnapshot(
      waypoints: List<LatLng>.from(_waypoints),
      segments: List<RouteSegment>.from(_segments),
      isLoopClosed: _isLoopClosed,
      loopPolygon: List<LatLng>.from(_loopPolygon),
      loopAreaM2: _loopAreaM2,
    ));
    _historyIndex++;
  }

  void _restoreSnapshot(_RouteSnapshot snap) {
    setState(() {
      _waypoints = List<LatLng>.from(snap.waypoints);
      _segments = List<RouteSegment>.from(snap.segments);
      _isLoopClosed = snap.isLoopClosed;
      _loopPolygon = List<LatLng>.from(snap.loopPolygon);
      _loopAreaM2 = snap.loopAreaM2;
    });
  }

  void _undo() {
    if (!_canUndo) return;
    _historyIndex--;
    _restoreSnapshot(_history[_historyIndex]);
  }

  void _redo() {
    if (!_canRedo) return;
    _historyIndex++;
    _restoreSnapshot(_history[_historyIndex]);
  }

  // ── Map tap entry point ───────────────────────────────────────────────────

  Future<void> _onMapTap(LatLng tapPoint) async {
    // Block new pins while routing, in delete mode, or after the loop is closed.
    if (_isRouting || _isDeleteMode || _isLoopClosed) return;

    if (_activeTool == _Tool.freeDraw) {
      // TODO: implement freehand drawing (sample gesture points as waypoints)
      return;
    }

    // ── Snap to an existing waypoint if close enough ───────────────────────
    // Check all already-placed waypoints except the current route tip.
    if (_waypoints.length >= 2) {
      for (int i = 0; i < _waypoints.length - 1; i++) {
        if (const Distance()(_waypoints[i], tapPoint) <= _snapThresholdMeters) {
          await _routeAndCloseAtWaypoint(i);
          return;
        }
      }
    }

    // ── Normal pin drop ───────────────────────────────────────────────────
    final prev = _waypoints.isNotEmpty ? _waypoints.last : null;
    setState(() => _waypoints.add(tapPoint));

    if (prev == null) {
      _pushHistory(); // first pin — nothing to route
      return;
    }

    setState(() => _isRouting = true);
    final seg = await RoutingService.fetchRoute(prev, tapPoint) ??
        RoutingService.straightLine(prev, tapPoint);

    if (!mounted) return;
    setState(() {
      _segments.add(seg);
      _isRouting = false;
    });

    // Check whether the new segment creates a self-intersection / loop.
    _checkSelfIntersection();
    _pushHistory();
  }

  // ── Snap-to-waypoint loop close ───────────────────────────────────────────

  /// Routes from the current route tip to waypoint [idx], adds the closing
  /// segment, and finalises the loop polygon.
  Future<void> _routeAndCloseAtWaypoint(int waypointIdx) async {
    final from = _waypoints.last;
    final to = _waypoints[waypointIdx];

    setState(() => _isRouting = true);
    final seg = await RoutingService.fetchRoute(from, to) ??
        RoutingService.straightLine(from, to);

    if (!mounted) return;
    setState(() {
      _isRouting = false;
      _segments.add(seg);
      // Re-add the target waypoint so segment count == waypoint count − 1.
      _waypoints.add(to);
    });

    _finaliseLoop(_polygonFromWaypointIndex(waypointIdx));
    _pushHistory();
  }

  // ── Self-intersection detection ───────────────────────────────────────────
  //
  // Two strategies, matching the OpenMap component:
  //
  // 1. Vertex proximity — ORS routes share exact OSM node coordinates when two
  //    segments pass through the same junction.  5 m catches identical nodes.
  //
  // 2. Geometric edge crossing — catches true geometric intersections (e.g.
  //    diagonal cuts or straight-line fallback segments).

  void _checkSelfIntersection() {
    if (_segments.length < 2) return;

    final newPoly = _segments.last.polyline;
    final prevCount = _segments.length - 1;

    for (int si = 0; si < prevCount; si++) {
      final existPoly = _segments[si].polyline;
      final isAdjacent = si == prevCount - 1;

      // Skip vertices too close to the shared junction to avoid false positives.
      final existEnd = isAdjacent
          ? (existPoly.length - 3).clamp(0, existPoly.length)
          : existPoly.length;
      final newStart = isAdjacent ? 3 : 1;

      if (newStart >= newPoly.length || existEnd <= 0) continue;

      // ── 1. Vertex proximity ──────────────────────────────────────────────
      for (int ni = newStart; ni < newPoly.length; ni++) {
        for (int ei = 0; ei < existEnd; ei++) {
          if (const Distance()(newPoly[ni], existPoly[ei]) <=
              _proximityThresholdMeters) {
            _finaliseLoop(
                _polygonFromIntersection(existPoly[ei], si, ei, ni));
            return;
          }
        }
      }

      // ── 2. Geometric edge crossing ───────────────────────────────────────
      final edgeEnd = isAdjacent
          ? (existPoly.length - 2).clamp(0, existPoly.length - 1)
          : existPoly.length - 1;

      for (int ei = 0; ei < edgeEnd; ei++) {
        for (int ni = 1; ni < newPoly.length - 1; ni++) {
          final pt = GeometryUtils.segmentIntersection(
            existPoly[ei], existPoly[ei + 1],
            newPoly[ni], newPoly[ni + 1],
          );
          if (pt != null) {
            _finaliseLoop(_polygonFromIntersection(pt, si, ei, ni));
            return;
          }
        }
      }
    }
  }

  // ── Loop polygon extraction ───────────────────────────────────────────────

  /// Builds the loop polygon for a snap-to-waypoint close.
  List<LatLng> _polygonFromWaypointIndex(int idx) {
    final poly = <LatLng>[];
    for (int s = idx; s < _segments.length; s++) {
      final pts = _segments[s].polyline;
      final start = s == idx ? 0 : 1; // skip shared junction vertex
      for (int i = start; i < pts.length; i++) {
        poly.add(pts[i]);
      }
    }
    return poly;
  }

  /// Builds the loop polygon for a geometric self-intersection.
  List<LatLng> _polygonFromIntersection(
    LatLng intersection,
    int segIdx,
    int edgeIdx,
    int newEdgeIdx,
  ) {
    final poly = <LatLng>[intersection];

    // Vertices of the intersected segment after the crossing edge.
    final iPoly = _segments[segIdx].polyline;
    for (int i = edgeIdx + 1; i < iPoly.length; i++) {
      poly.add(iPoly[i]);
    }

    // All intermediate segments entirely inside the loop.
    for (int s = segIdx + 1; s < _segments.length - 1; s++) {
      for (final p in _segments[s].polyline) {
        poly.add(p);
      }
    }

    // New segment from its start up to the crossing edge.
    final newPoly = _segments.last.polyline;
    for (int i = 0; i <= newEdgeIdx; i++) {
      poly.add(newPoly[i]);
    }

    return poly;
  }

  /// Validates the polygon area and marks the loop as closed.
  void _finaliseLoop(List<LatLng> polygon) {
    if (polygon.length < 3) return;
    final area = GeometryUtils.polygonAreaM2(polygon);
    if (area < _minLoopAreaM2) return;
    setState(() {
      _loopPolygon = polygon;
      _loopAreaM2 = area;
      _isLoopClosed = true;
    });
  }

  // ── Pin deletion ──────────────────────────────────────────────────────────

  Future<void> _deletePin(int index) async {
    if (_isRouting) return;

    // Deleting any pin breaks the current topology — clear the loop.
    setState(() {
      _isLoopClosed = false;
      _loopPolygon = [];
      _loopAreaM2 = 0.0;
    });

    final newWaypoints = List<LatLng>.from(_waypoints);
    final newSegments = List<RouteSegment>.from(_segments);

    newWaypoints.removeAt(index);

    if (index == 0) {
      if (newSegments.isNotEmpty) newSegments.removeAt(0);
      setState(() { _waypoints = newWaypoints; _segments = newSegments; });
      _pushHistory();
    } else if (index == _waypoints.length - 1) {
      if (newSegments.isNotEmpty) newSegments.removeLast();
      setState(() { _waypoints = newWaypoints; _segments = newSegments; });
      _pushHistory();
    } else {
      // Middle pin: remove its two adjacent segments then bridge the gap.
      newSegments.removeAt(index);      // outgoing segment
      newSegments.removeAt(index - 1); // incoming segment

      setState(() {
        _waypoints = newWaypoints;
        _segments = newSegments;
        _isRouting = true;
      });

      final bridge =
          await RoutingService.fetchRoute(newWaypoints[index - 1], newWaypoints[index]) ??
          RoutingService.straightLine(newWaypoints[index - 1], newWaypoints[index]);

      if (!mounted) return;
      newSegments.insert(index - 1, bridge);
      setState(() {
        _segments = List<RouteSegment>.from(newSegments);
        _isRouting = false;
      });
      _pushHistory();
    }
  }

  // ── Clear all ─────────────────────────────────────────────────────────────

  void _centerOnUser() {
    if (_currentPosition != null) {
      _mapController.move(_currentPosition!, _defaultZoom);
    }
  }

  Widget _buildMapButtons() {
    // Offset below the search-bar row (12 top-padding + 46 bar height + 10 gap).
    final top = MediaQuery.of(context).padding.top + 68.0;
    return Positioned(
      top: top,
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
        ],
      ),
    );
  }

  void _clearAll() {
    setState(() {
      _waypoints = [];
      _segments = [];
      _isDeleteMode = false;
      _isLoopClosed = false;
      _loopPolygon = [];
      _loopAreaM2 = 0.0;
    });
    _history
      ..clear()
      ..add(_RouteSnapshot(waypoints: [], segments: []));
    _historyIndex = 0;
    _trackNameCtrl.clear();
  }

  Future<void> _publishRoute() async {
    if (_isPublishing) return;
    setState(() => _isPublishing = true);

    // Merge segments into a single flat polyline, skipping duplicate junction points.
    final poly = <LatLng>[];
    for (int s = 0; s < _segments.length; s++) {
      final pts = _segments[s].polyline;
      final start = s == 0 ? 0 : 1;
      for (int i = start; i < pts.length; i++) {
        poly.add(pts[i]);
      }
    }

    try {
      await RouteRepository.instance.publishRoute(
        name: _trackNameCtrl.text,
        waypoints: List<LatLng>.from(_waypoints),
        routePolyline: poly,
        distanceMeters: _totalDistanceKm * 1000,
        estimatedTimeMin: _estimatedTimeMin,
        estimatedCalories: _estimatedCalories,
        isLoop: _isLoopClosed,
        loopAreaM2: _loopAreaM2,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Route published!')),
      );
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Failed to publish: $e')));
    } finally {
      if (mounted) setState(() => _isPublishing = false);
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          _buildMap(),
          if (_isLoadingLocation) _buildLoadingOverlay(),
          SafeArea(child: _buildTopBar()),
          _buildSheet(),
          _buildMapButtons(),
        ],
      ),
    );
  }

  // ── Map ───────────────────────────────────────────────────────────────────

  Widget _buildMap() {
    return FlutterMap(
      mapController: _mapController,
      options: MapOptions(
        initialCenter: _currentPosition ?? const LatLng(45.4642, 9.1900),
        initialZoom: _defaultZoom,
        onTap: (_, point) => _onMapTap(point),
      ),
      children: [
        TileLayer(
          urlTemplate: MapStyle.terrainTileUrl,
          userAgentPackageName: 'com.dash',
          retinaMode: RetinaMode.isHighDensity(context),
        ),

        // ── Claimed areas (display only — no hitNotifier, so tapping one
        // still drops a route pin rather than opening its details) ────────
        ClaimedAreasLayer(areas: _allAreas),

        // ── Loop fill (below route lines) ─────────────────────────────────
        if (_loopPolygon.length >= 3)
          PolygonLayer(
            polygons: [
              Polygon(
                points: _loopPolygon,
                color: const Color(0xFF4A8C52).withValues(alpha: 0.15),
                borderColor: const Color(0xFF4A8C52).withValues(alpha: 0.55),
                borderStrokeWidth: 2.0,
              ),
            ],
          ),

        // ── Route lines ───────────────────────────────────────────────────
        if (_segments.isNotEmpty)
          PolylineLayer(
            polylines: _segments
                .map((s) => Polyline(
                      points: s.polyline,
                      color: const Color(0xFF4A8C52),
                      strokeWidth: 4.0,
                    ))
                .toList(),
          ),

        // ── Straight-line preview while ORS call is in flight ─────────────
        if (_isRouting && _waypoints.length >= 2)
          PolylineLayer(
            polylines: [
              Polyline(
                points: [
                  _waypoints[_waypoints.length - 2],
                  _waypoints.last,
                ],
                color: const Color(0xFF4A8C52).withValues(alpha: 0.35),
                strokeWidth: 3.0,
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

        // ── Waypoint pins ─────────────────────────────────────────────────
        if (_waypoints.isNotEmpty)
          MarkerLayer(
            markers: _waypoints.asMap().entries.map((e) {
              final idx = e.key;
              return Marker(
                point: e.value,
                width: 36,
                height: 36,
                child: _PinMarker(
                  index: idx,
                  isDeleteMode: _isDeleteMode,
                  onTap: _isDeleteMode ? () => _deletePin(idx) : null,
                ),
              );
            }).toList(),
          ),
      ],
    );
  }

  // ── Top bar ───────────────────────────────────────────────────────────────

  Widget _buildTopBar() {
    return Padding(
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
                child: Icon(Icons.arrow_back,
                    color: Color(0xFF425143), size: 22),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _PlaceSearchBar(
              onPlaceSelected: (latLng) =>
                  _mapController.move(latLng, _defaultZoom),
            ),
          ),
        ],
      ),
    );
  }

  // ── Bottom sheet ──────────────────────────────────────────────────────────

  Widget _buildSheet() {
    return DraggableScrollableSheet(
      controller: _sheetController,
      initialChildSize: 0.32,
      minChildSize: 0.17,
      maxChildSize: 0.72,
      snap: true,
      snapSizes: const [0.17, 0.32, 0.72],
      builder: (context, scrollController) => Container(
        decoration: const BoxDecoration(
          color: Color(0xFFF3F5EE),
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 10)],
        ),
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
            // ── Toolbar ───────────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Row(
                children: [
                  _ToolButton(
                    icon: Icons.delete_outline_rounded,
                    label: 'Delete',
                    active: _isDeleteMode,
                    activeColor: const Color(0xFFD32F2F),
                    onTap: _waypoints.isNotEmpty
                        ? () => setState(
                            () => _isDeleteMode = !_isDeleteMode)
                        : null,
                  ),
                  const SizedBox(width: 6),
                  _ToolButton(
                    icon: Icons.pin_drop_outlined,
                    label: 'Pin',
                    active: _activeTool == _Tool.pinDrop && !_isDeleteMode,
                    onTap: () => setState(() {
                      _activeTool = _Tool.pinDrop;
                      _isDeleteMode = false;
                    }),
                  ),
                  const SizedBox(width: 6),
                  _ToolButton(
                    icon: Icons.edit_outlined,
                    label: 'Draw',
                    active: _activeTool == _Tool.freeDraw && !_isDeleteMode,
                    onTap: () => setState(() {
                      _activeTool = _Tool.freeDraw;
                      _isDeleteMode = false;
                    }),
                  ),
                  if (_isRouting) ...[
                    const SizedBox(width: 8),
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Color(0xFF4A8C52)),
                    ),
                  ],
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.undo_rounded),
                    onPressed: _canUndo ? _undo : null,
                    color: const Color(0xFF425143),
                    disabledColor: Colors.grey[300],
                    tooltip: 'Undo',
                    visualDensity: VisualDensity.compact,
                  ),
                  IconButton(
                    icon: const Icon(Icons.redo_rounded),
                    onPressed: _canRedo ? _redo : null,
                    color: const Color(0xFF425143),
                    disabledColor: Colors.grey[300],
                    tooltip: 'Redo',
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
            ),
            const Divider(height: 1, indent: 16, endIndent: 16),
            // ── Scrollable form ────────────────────────────────────────────
            Expanded(
              child: ListView(
                controller: scrollController,
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
                children: [
                  TextField(
                    controller: _trackNameCtrl,
                    style: const TextStyle(fontSize: 15),
                    decoration: InputDecoration(
                      hintText: 'Track name',
                      hintStyle: const TextStyle(
                          color: Colors.grey, fontSize: 15),
                      prefixIcon: const Icon(Icons.route_rounded,
                          size: 18, color: Colors.grey),
                      filled: true,
                      fillColor: Colors.white,
                      contentPadding:
                          const EdgeInsets.symmetric(vertical: 12),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  _buildStatsSection(),
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _clearAll,
                          style: OutlinedButton.styleFrom(
                            foregroundColor: const Color(0xFF5E655C),
                            side: const BorderSide(
                                color: Color(0xFFCFCFCF)),
                            padding: const EdgeInsets.symmetric(
                                vertical: 13),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12)),
                          ),
                          child: const Text('Cancel',
                              style: TextStyle(
                                  fontWeight: FontWeight.w600)),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        flex: 2,
                        child: ElevatedButton.icon(
                          onPressed: (_waypoints.length >= 2 && !_isPublishing)
                              ? _publishRoute
                              : null,
                          icon: _isPublishing
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Color(0xFF2E7D32)),
                                )
                              : const Icon(
                                  Icons.check_circle_outline_rounded,
                                  size: 18),
                          label: const Text('Publish path'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFFCAF0B8),
                            foregroundColor: const Color(0xFF2E7D32),
                            disabledBackgroundColor:
                                const Color(0xFFE0E0E0),
                            elevation: 0,
                            padding: const EdgeInsets.symmetric(
                                vertical: 13),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12)),
                            textStyle: const TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 14),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Stats section ─────────────────────────────────────────────────────────

  Widget _buildStatsSection() {
    final hasPins = _waypoints.length >= 2;
    final distLabel = hasPins
        ? (_totalDistanceKm < 1
            ? '${(_totalDistanceKm * 1000).round()} m'
            : '${_totalDistanceKm.toStringAsFixed(2)} km')
        : '—';
    final timeLabel = hasPins
        ? (_estimatedTimeMin < 60
            ? '${_estimatedTimeMin.round()} min'
            : '${(_estimatedTimeMin / 60).floor()}h '
                '${(_estimatedTimeMin % 60).round()}min')
        : '—';
    final calLabel =
        hasPins ? '${_estimatedCalories.round()} kcal' : '—';

    return Column(
      children: [
        Row(
          children: [
            _MiniStat(
                icon: Icons.straighten_rounded,
                label: 'Distance',
                value: distLabel),
            const SizedBox(width: 8),
            _MiniStat(
                icon: Icons.timer_outlined,
                label: 'Est. time',
                value: timeLabel),
            const SizedBox(width: 8),
            _MiniStat(
                icon: Icons.local_fire_department_outlined,
                label: 'Calories',
                value: calLabel),
          ],
        ),
        // Loop area — shown only once a circuit is detected
        if (_isLoopClosed) ...[
          const SizedBox(height: 8),
          _LoopAreaBanner(areaM2: _loopAreaM2),
        ],
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

// ── Loop area banner ───────────────────────────────────────────────────────────

class _LoopAreaBanner extends StatelessWidget {
  final double areaM2;
  const _LoopAreaBanner({required this.areaM2});

  String get _areaLabel {
    if (areaM2 >= 1000000) return '${(areaM2 / 1000000).toStringAsFixed(2)} km²';
    if (areaM2 >= 10000) return '${(areaM2 / 10000).toStringAsFixed(2)} ha';
    return '${areaM2.round()} m²';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFEAF7E0),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: const Color(0xFF4A8C52).withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          const Icon(Icons.check_circle_outline_rounded,
              size: 18, color: Color(0xFF2E7D32)),
          const SizedBox(width: 8),
          const Text('Circuit closed!',
              style: TextStyle(
                  color: Color(0xFF2E7D32),
                  fontWeight: FontWeight.w600,
                  fontSize: 13)),
          const Spacer(),
          const Icon(Icons.crop_free_rounded,
              size: 16, color: Color(0xFF4A8C52)),
          const SizedBox(width: 6),
          Text(
            'Area: $_areaLabel',
            style: const TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 13,
                color: Color(0xFF2E7D32)),
          ),
        ],
      ),
    );
  }
}

// ── Toolbar button ─────────────────────────────────────────────────────────────

class _ToolButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final Color activeColor;
  final VoidCallback? onTap;

  const _ToolButton({
    required this.icon,
    required this.label,
    required this.active,
    this.activeColor = const Color(0xFF4A8C52),
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final fg = active ? Colors.white : const Color(0xFF425143);
    final bg = active ? activeColor : Colors.white;
    final disabled = onTap == null && !active;

    return Tooltip(
      message: label,
      child: Material(
        color: disabled ? const Color(0xFFF0F0F0) : bg,
        borderRadius: BorderRadius.circular(10),
        elevation: active ? 0 : 1,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon,
                    size: 18,
                    color: disabled ? Colors.grey[400] : fg),
                const SizedBox(width: 5),
                Text(label,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: disabled ? Colors.grey[400] : fg)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Pin marker ─────────────────────────────────────────────────────────────────

class _PinMarker extends StatelessWidget {
  final int index;
  final bool isDeleteMode;
  final VoidCallback? onTap;

  const _PinMarker({
    required this.index,
    required this.isDeleteMode,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final bg =
        isDeleteMode ? const Color(0xFFD32F2F) : const Color(0xFF4A8C52);

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: bg,
          border: Border.all(color: Colors.white, width: 2.5),
          boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4)],
        ),
        alignment: Alignment.center,
        child: isDeleteMode
            ? const Icon(Icons.close, color: Colors.white, size: 14)
            : Text(
                '${index + 1}',
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w700),
              ),
      ),
    );
  }
}

// ── Stat card ──────────────────────────────────────────────────────────────────

class _MiniStat extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _MiniStat(
      {required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          children: [
            Icon(icon, size: 18, color: const Color(0xFF4A8C52)),
            const SizedBox(height: 4),
            Text(value,
                style: const TextStyle(
                    fontWeight: FontWeight.w700, fontSize: 13)),
            const SizedBox(height: 2),
            Text(label,
                style:
                    const TextStyle(color: Colors.grey, fontSize: 10)),
          ],
        ),
      ),
    );
  }
}

// ── Place search bar ───────────────────────────────────────────────────────────

class _PlaceSearchBar extends StatefulWidget {
  final void Function(LatLng latLng) onPlaceSelected;

  const _PlaceSearchBar({required this.onPlaceSelected});

  @override
  State<_PlaceSearchBar> createState() => _PlaceSearchBarState();
}

class _PlaceSearchBarState extends State<_PlaceSearchBar> {
  final TextEditingController _ctrl = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  Timer? _debounce;
  List<_Place> _suggestions = [];
  bool _showSuggestions = false;
  bool _suppressNext = false;

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(_onChanged);
    _focusNode.addListener(() {
      if (!_focusNode.hasFocus && mounted) {
        setState(() => _showSuggestions = false);
      }
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _ctrl.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (_suppressNext) { _suppressNext = false; return; }
    _debounce?.cancel();
    final text = _ctrl.text.trim();
    if (text.length < 3) {
      if (mounted) setState(() { _suggestions = []; _showSuggestions = false; });
      return;
    }
    _debounce =
        Timer(const Duration(milliseconds: 350), () => _fetch(text));
  }

  Future<void> _fetch(String query) async {
    try {
      final uri = Uri.parse(
        'https://nominatim.openstreetmap.org/search'
        '?q=${Uri.encodeComponent(query)}&format=json&limit=5',
      );
      final res = await http
          .get(uri, headers: {'User-Agent': 'DashApp/1.0'})
          .timeout(const Duration(seconds: 5));
      if (res.statusCode != 200) return;
      final list = jsonDecode(res.body) as List<dynamic>;
      final places = list.map((item) {
        final m = item as Map<String, dynamic>;
        return _Place(
          displayName: m['display_name'] as String,
          latLng: LatLng(
            double.parse(m['lat'] as String),
            double.parse(m['lon'] as String),
          ),
        );
      }).toList();
      if (mounted) {
        setState(() {
          _suggestions = places;
          _showSuggestions = places.isNotEmpty && _focusNode.hasFocus;
        });
      }
    } catch (_) {}
  }

  void _select(_Place place) {
    _suppressNext = true;
    _ctrl.text = place.displayName;
    _ctrl.selection = TextSelection.fromPosition(
        TextPosition(offset: _ctrl.text.length));
    setState(() { _suggestions = []; _showSuggestions = false; });
    _focusNode.unfocus();
    widget.onPlaceSelected(place.latLng);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          height: 46,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(23),
            boxShadow: const [
              BoxShadow(
                  color: Colors.black26,
                  blurRadius: 6,
                  offset: Offset(0, 2)),
            ],
          ),
          alignment: Alignment.center,
          child: TextField(
            controller: _ctrl,
            focusNode: _focusNode,
            style: const TextStyle(fontSize: 14),
            decoration: InputDecoration(
              hintText: 'Search a place…',
              hintStyle:
                  const TextStyle(color: Colors.grey, fontSize: 14),
              prefixIcon:
                  const Icon(Icons.search, color: Colors.grey, size: 20),
              suffixIcon: _ctrl.text.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.close,
                          size: 18, color: Colors.grey),
                      onPressed: () {
                        _ctrl.clear();
                        setState(() {
                          _suggestions = [];
                          _showSuggestions = false;
                        });
                      },
                    )
                  : null,
              border: InputBorder.none,
              contentPadding: EdgeInsets.zero,
            ),
          ),
        ),
        if (_showSuggestions && _suggestions.isNotEmpty)
          Material(
            elevation: 4,
            borderRadius:
                const BorderRadius.vertical(bottom: Radius.circular(12)),
            color: Colors.white,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 200),
              child: ListView.separated(
                padding: EdgeInsets.zero,
                shrinkWrap: true,
                physics: const ClampingScrollPhysics(),
                itemCount: _suggestions.length,
                separatorBuilder: (context, index) =>
                    const Divider(height: 1, indent: 12, endIndent: 12),
                itemBuilder: (_, i) {
                  final p = _suggestions[i];
                  return InkWell(
                    onTap: () => _select(p),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                      child: Row(
                        children: [
                          const Icon(Icons.location_on_outlined,
                              size: 15, color: Color(0xFF4A8C52)),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(p.displayName,
                                style: const TextStyle(fontSize: 12),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis),
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
