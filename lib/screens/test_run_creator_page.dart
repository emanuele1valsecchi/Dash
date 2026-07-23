import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:permission_handler/permission_handler.dart';

import '../config/map_style.dart';
import '../services/cached_tile_provider.dart';
import '../services/claimed_area_repository.dart';
import '../services/routing_service.dart';
import '../services/run_session_repository.dart';
import '../utils/geometry_utils.dart';
import '../widgets/map/area_visibility_toggle.dart';
import '../widgets/map/claimed_areas_layer.dart';
import '../widgets/run_results_dialog.dart';

/// Dev-only tool: build a fake run by placing pins — routed the same way as
/// the real route builder — and manually setting its duration, then publish
/// it straight into `runningSessions`. Lets the area-claiming logic be
/// tested with specific loop shapes without physically running them.
class TestRunCreatorPage extends StatefulWidget {
  const TestRunCreatorPage({super.key});

  @override
  State<TestRunCreatorPage> createState() => _TestRunCreatorPageState();
}

// ── History snapshot ───────────────────────────────────────────────────────────

class _RunSnapshot {
  final List<LatLng> waypoints;
  final List<RouteSegment> segments;
  final bool isLoopClosed;
  final List<LatLng> loopPolygon;
  final double loopAreaM2;

  _RunSnapshot({
    required this.waypoints,
    required this.segments,
    this.isLoopClosed = false,
    this.loopPolygon = const [],
    this.loopAreaM2 = 0.0,
  });
}

// ── Page ───────────────────────────────────────────────────────────────────────

class _TestRunCreatorPageState extends State<TestRunCreatorPage> {
  // ── Map ───────────────────────────────────────────────────────────────────
  final MapController _mapController = MapController();
  LatLng? _currentPosition;
  bool _isLoadingLocation = true;
  StreamSubscription<Position>? _positionStream;

  // ── Claimed areas (display only) ─────────────────────────────────────────
  List<ClaimedArea> _allAreas = [];
  bool _showOtherAreas = true;
  bool _showMyAreas = true;

  List<ClaimedArea> get _visibleAreas {
    final myUid = FirebaseAuth.instance.currentUser?.uid;
    return _allAreas.where((area) {
      final isMine = area.userId == myUid;
      return isMine ? _showMyAreas : _showOtherAreas;
    }).toList();
  }

  // ── Sheet ─────────────────────────────────────────────────────────────────
  final DraggableScrollableController _sheetController = DraggableScrollableController();

  // ── Route state ───────────────────────────────────────────────────────────
  List<LatLng> _waypoints = [];
  List<RouteSegment> _segments = [];
  bool _isRouting = false;

  // ── Loop state ────────────────────────────────────────────────────────────
  bool _isLoopClosed = false;
  List<LatLng> _loopPolygon = [];
  double _loopAreaM2 = 0.0;

  // ── Undo / redo ───────────────────────────────────────────────────────────
  final List<_RunSnapshot> _history = [_RunSnapshot(waypoints: [], segments: [])];
  int _historyIndex = 0;
  bool get _canUndo => _historyIndex > 0 && !_isRouting;
  bool get _canRedo => _historyIndex < _history.length - 1 && !_isRouting;

  bool _isDeleteMode = false;

  // ── Form ──────────────────────────────────────────────────────────────────
  final TextEditingController _nameCtrl = TextEditingController();
  int? _manualMinutes;
  bool _isPublishing = false;

  // ── Derived stats ─────────────────────────────────────────────────────────
  double get _totalDistanceKm => _segments.fold(0.0, (s, seg) => s + seg.distanceMeters) / 1000;
  double get _estimatedCalories => _totalDistanceKm * 70.0;

  // ── Constants ─────────────────────────────────────────────────────────────
  static const double _defaultZoom = 15.0;
  static const double _snapThresholdMeters = 40.0;
  static const double _proximityThresholdMeters = 5.0;
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
    _positionStream?.cancel();
    _mapController.dispose();
    _sheetController.dispose();
    _nameCtrl.dispose();
    super.dispose();
  }

  // ── Location ──────────────────────────────────────────────────────────────

  Future<void> _initLocation() async {
    final status = await Permission.locationWhenInUse.request();
    if (!status.isGranted) {
      setState(() => _isLoadingLocation = false);
      return;
    }
    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      );
      final ll = LatLng(pos.latitude, pos.longitude);
      setState(() {
        _currentPosition = ll;
        _isLoadingLocation = false;
      });
      _mapController.move(ll, _defaultZoom);
    } catch (_) {
      setState(() => _isLoadingLocation = false);
    }
    _positionStream = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 5),
    ).listen((p) => setState(() => _currentPosition = LatLng(p.latitude, p.longitude)));
  }

  // ── History ───────────────────────────────────────────────────────────────

  void _pushHistory() {
    _history.removeRange(_historyIndex + 1, _history.length);
    _history.add(_RunSnapshot(
      waypoints: List<LatLng>.from(_waypoints),
      segments: List<RouteSegment>.from(_segments),
      isLoopClosed: _isLoopClosed,
      loopPolygon: List<LatLng>.from(_loopPolygon),
      loopAreaM2: _loopAreaM2,
    ));
    _historyIndex++;
  }

  void _restoreSnapshot(_RunSnapshot snap) {
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
    if (_isRouting || _isDeleteMode || _isLoopClosed) return;

    if (_waypoints.length >= 2) {
      for (int i = 0; i < _waypoints.length - 1; i++) {
        if (const Distance()(_waypoints[i], tapPoint) <= _snapThresholdMeters) {
          await _routeAndCloseAtWaypoint(i);
          return;
        }
      }
    }

    final prev = _waypoints.isNotEmpty ? _waypoints.last : null;
    setState(() => _waypoints.add(tapPoint));

    if (prev == null) {
      _pushHistory();
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

    _checkSelfIntersection();
    _pushHistory();
  }

  Future<void> _routeAndCloseAtWaypoint(int waypointIdx) async {
    final from = _waypoints.last;
    final to = _waypoints[waypointIdx];

    setState(() => _isRouting = true);
    final seg = await RoutingService.fetchRoute(from, to) ?? RoutingService.straightLine(from, to);

    if (!mounted) return;
    setState(() {
      _isRouting = false;
      _segments.add(seg);
      _waypoints.add(to);
    });

    _finaliseLoop(_polygonFromWaypointIndex(waypointIdx));
    _pushHistory();
  }

  // ── Self-intersection detection (mirrors RouteCreatePage) ────────────────

  void _checkSelfIntersection() {
    if (_segments.length < 2) return;

    final newPoly = _segments.last.polyline;
    final prevCount = _segments.length - 1;

    for (int si = 0; si < prevCount; si++) {
      final existPoly = _segments[si].polyline;
      final isAdjacent = si == prevCount - 1;

      final existEnd =
          isAdjacent ? (existPoly.length - 3).clamp(0, existPoly.length) : existPoly.length;
      final newStart = isAdjacent ? 3 : 1;

      if (newStart >= newPoly.length || existEnd <= 0) continue;

      for (int ni = newStart; ni < newPoly.length; ni++) {
        for (int ei = 0; ei < existEnd; ei++) {
          if (const Distance()(newPoly[ni], existPoly[ei]) <= _proximityThresholdMeters) {
            _finaliseLoop(_polygonFromIntersection(existPoly[ei], si, ei, ni));
            return;
          }
        }
      }

      final edgeEnd =
          isAdjacent ? (existPoly.length - 2).clamp(0, existPoly.length - 1) : existPoly.length - 1;

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

  List<LatLng> _polygonFromWaypointIndex(int idx) {
    final poly = <LatLng>[];
    for (int s = idx; s < _segments.length; s++) {
      final pts = _segments[s].polyline;
      final start = s == idx ? 0 : 1;
      for (int i = start; i < pts.length; i++) {
        poly.add(pts[i]);
      }
    }
    return poly;
  }

  List<LatLng> _polygonFromIntersection(
    LatLng intersection,
    int segIdx,
    int edgeIdx,
    int newEdgeIdx,
  ) {
    final poly = <LatLng>[intersection];

    final iPoly = _segments[segIdx].polyline;
    for (int i = edgeIdx + 1; i < iPoly.length; i++) {
      poly.add(iPoly[i]);
    }

    for (int s = segIdx + 1; s < _segments.length - 1; s++) {
      for (final p in _segments[s].polyline) {
        poly.add(p);
      }
    }

    final newPoly = _segments.last.polyline;
    for (int i = 0; i <= newEdgeIdx; i++) {
      poly.add(newPoly[i]);
    }

    return poly;
  }

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
      setState(() {
        _waypoints = newWaypoints;
        _segments = newSegments;
      });
      _pushHistory();
    } else if (index == _waypoints.length - 1) {
      if (newSegments.isNotEmpty) newSegments.removeLast();
      setState(() {
        _waypoints = newWaypoints;
        _segments = newSegments;
      });
      _pushHistory();
    } else {
      newSegments.removeAt(index); // outgoing segment
      newSegments.removeAt(index - 1); // incoming segment

      setState(() {
        _waypoints = newWaypoints;
        _segments = newSegments;
        _isRouting = true;
      });

      final bridge = await RoutingService.fetchRoute(newWaypoints[index - 1], newWaypoints[index]) ??
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

  void _centerOnUser() {
    if (_currentPosition != null) {
      _mapController.move(_currentPosition!, _defaultZoom);
    }
  }

  // ── Manual time entry ─────────────────────────────────────────────────────

  Future<void> _setManualTime() async {
    final minutes = await showDialog<int>(
      context: context,
      builder: (_) => _SetTimeDialog(initialMinutes: _manualMinutes),
    );
    if (minutes != null) setState(() => _manualMinutes = minutes);
  }

  // ── Publish / discard ────────────────────────────────────────────────────

  void _discard() => Navigator.of(context).pop(false);

  Future<void> _publish() async {
    if (_isPublishing) return;
    if (_waypoints.length < 2 || _manualMinutes == null) return;

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

    final distanceKm = _totalDistanceKm;
    final avgPace = distanceKm > 0 ? _manualMinutes! / distanceKm : 0.0;

    try {
      final sessionId = await RunSessionRepository.instance.saveSession(
        name: _nameCtrl.text,
        distanceMeters: distanceKm * 1000,
        duration: Duration(minutes: _manualMinutes!),
        avgPaceMinPerKm: avgPace,
        maxPaceMinPerKm: avgPace,
        caloriesBurned: _estimatedCalories,
        elevationDifferenceMeters: 0.0,
        loopsCompleted: _isLoopClosed ? 1 : 0,
        path: poly,
        closedLoops: _isLoopClosed ? [_loopPolygon] : [],
      );
      if (!mounted) return;
      await showRunResultsDialog(
        context: context,
        sessionId: sessionId,
        path: poly,
        distanceMeters: distanceKm * 1000,
        duration: Duration(minutes: _manualMinutes!),
        caloriesBurned: _estimatedCalories,
        elevationDifferenceMeters: 0.0,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Test run published!')),
      );
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to publish: $e')));
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
          tileProvider: CachedTileProvider.instance,
        ),

        // ── Claimed areas (display only — no tap-to-view here) ─────────────
        ClaimedAreasLayer(areas: _visibleAreas),

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
        if (_segments.isNotEmpty)
          PolylineLayer(
            polylines: _segments
                .map((s) => Polyline(points: s.polyline, color: const Color(0xFF4A8C52), strokeWidth: 4.0))
                .toList(),
          ),
        if (_isRouting && _waypoints.length >= 2)
          PolylineLayer(
            polylines: [
              Polyline(
                points: [_waypoints[_waypoints.length - 2], _waypoints.last],
                color: const Color(0xFF4A8C52).withValues(alpha: 0.35),
                strokeWidth: 3.0,
              ),
            ],
          ),
        if (_currentPosition != null)
          MarkerLayer(
            markers: [
              Marker(point: _currentPosition!, width: 60, height: 60, child: const _LocationDot()),
            ],
          ),
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
              onTap: () => Navigator.of(context).pop(false),
              child: const Padding(
                padding: EdgeInsets.all(10),
                child: Icon(Icons.arrow_back, color: Color(0xFF425143), size: 22),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xFFF6D651),
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Text(
              'TESTING RUN CREATOR',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: Color(0xFF4A3B00),
                letterSpacing: 0.5,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMapButtons() {
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
          _RoundMapButton(icon: Icons.my_location, tooltip: 'My location', onTap: _centerOnUser),
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

  // ── Bottom sheet ──────────────────────────────────────────────────────────

  Widget _buildSheet() {
    return DraggableScrollableSheet(
      controller: _sheetController,
      initialChildSize: 0.34,
      minChildSize: 0.2,
      maxChildSize: 0.75,
      snap: true,
      snapSizes: const [0.2, 0.34, 0.75],
      builder: (context, scrollController) => Container(
        decoration: const BoxDecoration(
          color: Color(0xFFF3F5EE),
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 10)],
        ),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2)),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Row(
                children: [
                  _ToolButton(
                    icon: Icons.delete_outline_rounded,
                    label: 'Delete',
                    active: _isDeleteMode,
                    activeColor: const Color(0xFFD32F2F),
                    onTap:
                        _waypoints.isNotEmpty ? () => setState(() => _isDeleteMode = !_isDeleteMode) : null,
                  ),
                  if (_isRouting) ...[
                    const SizedBox(width: 8),
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF4A8C52)),
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
            Expanded(
              child: ListView(
                controller: scrollController,
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
                children: [
                  TextField(
                    controller: _nameCtrl,
                    style: const TextStyle(fontSize: 15),
                    decoration: InputDecoration(
                      hintText: 'Run name',
                      hintStyle: const TextStyle(color: Colors.grey, fontSize: 15),
                      prefixIcon: const Icon(Icons.edit_outlined, size: 18, color: Colors.grey),
                      filled: true,
                      fillColor: Colors.white,
                      contentPadding: const EdgeInsets.symmetric(vertical: 12),
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
                          onPressed: _isPublishing ? null : _discard,
                          style: OutlinedButton.styleFrom(
                            foregroundColor: const Color(0xFF8A3B34),
                            side: const BorderSide(color: Color(0xFFE3B7B2)),
                            padding: const EdgeInsets.symmetric(vertical: 13),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                          child: const Text('Discard', style: TextStyle(fontWeight: FontWeight.w600)),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        flex: 2,
                        child: ElevatedButton.icon(
                          onPressed: (_waypoints.length >= 2 && _manualMinutes != null && !_isPublishing)
                              ? _publish
                              : null,
                          icon: _isPublishing
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF2E7D32)),
                                )
                              : const Icon(Icons.check_circle_outline_rounded, size: 18),
                          label: const Text('Publish'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFFCAF0B8),
                            foregroundColor: const Color(0xFF2E7D32),
                            disabledBackgroundColor: const Color(0xFFE0E0E0),
                            elevation: 0,
                            padding: const EdgeInsets.symmetric(vertical: 13),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
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
    final timeLabel = _manualMinutes != null ? '$_manualMinutes min' : 'Tap to set';
    final calLabel = hasPins ? '${_estimatedCalories.round()} kcal' : '—';

    return Column(
      children: [
        Row(
          children: [
            _MiniStat(icon: Icons.straighten_rounded, label: 'Distance', value: distLabel),
            const SizedBox(width: 8),
            _MiniStat(
              icon: Icons.timer_outlined,
              label: 'Time',
              value: timeLabel,
              onTap: _setManualTime,
              highlighted: _manualMinutes == null,
            ),
            const SizedBox(width: 8),
            _MiniStat(icon: Icons.local_fire_department_outlined, label: 'Calories', value: calLabel),
          ],
        ),
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
            Text('Getting your location…', style: TextStyle(color: Colors.white, fontSize: 16)),
          ],
        ),
      ),
    );
  }
}

// ── Set-time dialog ─────────────────────────────────────────────────────────

/// Owns its own [TextEditingController] so disposal happens through the
/// normal State lifecycle. Disposing a controller manually right after
/// `await showDialog(...)` returns is unsafe: that Future resolves the
/// instant `Navigator.pop()` is called, while the dialog's `TextField` is
/// still mounted and animating out — disposing the controller out from
/// under it trips a framework assertion.
class _SetTimeDialog extends StatefulWidget {
  final int? initialMinutes;
  const _SetTimeDialog({this.initialMinutes});

  @override
  State<_SetTimeDialog> createState() => _SetTimeDialogState();
}

class _SetTimeDialogState extends State<_SetTimeDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialMinutes?.toString() ?? '');
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final parsed = int.tryParse(_controller.text);
    Navigator.of(context).pop(parsed != null && parsed > 0 ? parsed : null);
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFFF5F6EF),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(22, 24, 22, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Set run time',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: Color(0xFF2A3028)),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _controller,
              autofocus: true,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              style: const TextStyle(fontSize: 16),
              decoration: InputDecoration(
                hintText: 'Minutes',
                filled: true,
                fillColor: Colors.white,
                contentPadding: const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF5E655C),
                      side: const BorderSide(color: Color(0xFFCFCFCF)),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: const Text('Cancel', style: TextStyle(fontWeight: FontWeight.w600)),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _submit,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFCAF0B8),
                      foregroundColor: const Color(0xFF2E7D32),
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: const Text('Set', style: TextStyle(fontWeight: FontWeight.w600)),
                  ),
                ),
              ],
            ),
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
        border: Border.all(color: const Color(0xFF4A8C52).withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          const Icon(Icons.check_circle_outline_rounded, size: 18, color: Color(0xFF2E7D32)),
          const SizedBox(width: 8),
          const Text(
            'Circuit closed!',
            style: TextStyle(color: Color(0xFF2E7D32), fontWeight: FontWeight.w600, fontSize: 13),
          ),
          const Spacer(),
          const Icon(Icons.crop_free_rounded, size: 16, color: Color(0xFF4A8C52)),
          const SizedBox(width: 6),
          Text(
            'Area: $_areaLabel',
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: Color(0xFF2E7D32)),
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
                Icon(icon, size: 18, color: disabled ? Colors.grey[400] : fg),
                const SizedBox(width: 5),
                Text(label,
                    style: TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w500, color: disabled ? Colors.grey[400] : fg)),
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

  const _PinMarker({required this.index, required this.isDeleteMode, this.onTap});

  @override
  Widget build(BuildContext context) {
    final bg = isDeleteMode ? const Color(0xFFD32F2F) : const Color(0xFF4A8C52);

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
                style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700),
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
  final VoidCallback? onTap;
  final bool highlighted;

  const _MiniStat({
    required this.icon,
    required this.label,
    required this.value,
    this.onTap,
    this.highlighted = false,
  });

  @override
  Widget build(BuildContext context) {
    final content = Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
      decoration: BoxDecoration(
        color: highlighted ? const Color(0xFFFFF3D6) : Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: highlighted ? Border.all(color: const Color(0xFFF6D651)) : null,
      ),
      child: Column(
        children: [
          Icon(icon, size: 18, color: const Color(0xFF4A8C52)),
          const SizedBox(height: 4),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
          const SizedBox(height: 2),
          Text(label, style: const TextStyle(color: Colors.grey, fontSize: 10)),
        ],
      ),
    );

    return Expanded(
      child: onTap != null
          ? InkWell(borderRadius: BorderRadius.circular(12), onTap: onTap, child: content)
          : content,
    );
  }
}

// ── Reusable round map button ──────────────────────────────────────────────────

class _RoundMapButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;

  const _RoundMapButton({required this.icon, required this.tooltip, this.onTap});

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

// ── GPS dot ────────────────────────────────────────────────────────────────────

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
          decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.blue.withValues(alpha: 0.2)),
        ),
        Container(
          width: 16,
          height: 16,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.blue,
            border: Border.all(color: Colors.white, width: 2),
            boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4)],
          ),
        ),
      ],
    );
  }
}
