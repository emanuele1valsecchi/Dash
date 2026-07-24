import 'dart:async';
import 'dart:math' as math;

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
import '../widgets/map/enhanced_map_gestures.dart';
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

enum _Tool { pinDrop, freeDraw }

// ── History snapshot ───────────────────────────────────────────────────────────

class _RunSnapshot {
  final List<LatLng> waypoints;
  final List<RouteSegment> segments;

  /// Every loop closed so far — plural, since a test run can close more
  /// than one separate area (see `_activeLoopStartSegment`).
  final List<List<LatLng>> loopPolygons;
  final List<double> loopAreasM2;
  final int activeLoopStartSegment;

  /// How many *leading* waypoints came from the most recent freehand-draw
  /// conversion (0 if built purely by tapping pins) — see
  /// `_isHiddenWaypoint`.
  final int drawnPointsCount;

  _RunSnapshot({
    required this.waypoints,
    required this.segments,
    this.loopPolygons = const [],
    this.loopAreasM2 = const [],
    this.activeLoopStartSegment = 0,
    this.drawnPointsCount = 0,
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
  // Plural: placing more pins after a loop closes is allowed, and each
  // closure is kept rather than overwritten, so a single test run can claim
  // several separate areas (mirrors RouteCreatePage).
  List<List<LatLng>> _loopPolygons = [];
  List<double> _loopAreasM2 = [];

  /// Index into [_segments]/[_waypoints] (kept in lockstep at
  /// `segments.length == waypoints.length - 1`) where the *current*,
  /// not-yet-closed loop starts. See RouteCreatePage's field of the same
  /// name for the full rationale — scopes self-intersection/snap-to-waypoint
  /// checks so a new segment can't get matched against an already-finalised
  /// loop's own geometry.
  int _activeLoopStartSegment = 0;

  // ── Undo / redo ───────────────────────────────────────────────────────────
  final List<_RunSnapshot> _history = [_RunSnapshot(waypoints: [], segments: [])];
  int _historyIndex = 0;

  // Also blocked while converting a drawn stroke — see
  // `_isConvertingDrawing`'s doc comment (mirrors RouteCreatePage).
  bool get _canUndo =>
      _historyIndex > 0 && !_isRouting && !_isConvertingDrawing;
  bool get _canRedo =>
      _historyIndex < _history.length - 1 &&
      !_isRouting &&
      !_isConvertingDrawing;

  bool _isDeleteMode = false;

  // ── Tools ─────────────────────────────────────────────────────────────────
  _Tool _activeTool = _Tool.pinDrop;

  // ── Freehand drawing (mirrors RouteCreatePage) ────────────────────────────
  // One-shot: only usable to lay down the very first shape on an empty run,
  // never to append a second drawn stroke onto an already-drawn (or
  // already-pinned) one.

  /// Raw finger path for the current in-progress stroke — live visual
  /// feedback only; the converted route is built from a downsampled copy.
  final List<LatLng> _drawnPoints = [];

  /// True only while a just-finished stroke is being converted into routed
  /// waypoints — guards against starting a second stroke mid-conversion.
  bool _isConvertingDrawing = false;

  /// How many leading waypoints came from the last draw conversion — see
  /// `_RunSnapshot.drawnPointsCount`. Reset to 0 by anything that breaks the
  /// assumption that this prefix is still exactly what drawing produced.
  int _drawnPointsCount = 0;

  /// A waypoint drawn as part of a freehand stroke, other than its very
  /// first or last point, is never rendered as a pin — see RouteCreatePage's
  /// `_isHiddenWaypoint` for the full rationale.
  bool _isHiddenWaypoint(int index) =>
      _drawnPointsCount > 2 && index > 0 && index < _drawnPointsCount - 1;

  bool get _canUseDrawTool => _waypoints.isEmpty;

  // ── Form ──────────────────────────────────────────────────────────────────
  final TextEditingController _nameCtrl = TextEditingController();
  int? _manualMinutes;
  bool _isPublishing = false;

  // ── Derived stats ─────────────────────────────────────────────────────────
  double get _totalDistanceKm => _segments.fold(0.0, (s, seg) => s + seg.distanceMeters) / 1000;
  double get _estimatedCalories => _totalDistanceKm * 70.0;
  double get _totalLoopAreaM2 => _loopAreasM2.fold(0.0, (a, b) => a + b);

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
      loopPolygons: _loopPolygons.map(List<LatLng>.from).toList(),
      loopAreasM2: List<double>.from(_loopAreasM2),
      activeLoopStartSegment: _activeLoopStartSegment,
      drawnPointsCount: _drawnPointsCount,
    ));
    _historyIndex++;
  }

  void _restoreSnapshot(_RunSnapshot snap) {
    setState(() {
      _waypoints = List<LatLng>.from(snap.waypoints);
      _segments = List<RouteSegment>.from(snap.segments);
      _loopPolygons = snap.loopPolygons.map(List<LatLng>.from).toList();
      _loopAreasM2 = List<double>.from(snap.loopAreasM2);
      _activeLoopStartSegment = snap.activeLoopStartSegment;
      _drawnPointsCount = snap.drawnPointsCount;
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
    // A closed loop no longer blocks placing more pins — a test run can
    // close as many separate areas as needed (see `_activeLoopStartSegment`).
    if (_isRouting || _isDeleteMode) return;

    if (_activeTool == _Tool.freeDraw) {
      // Drawing is a press-and-drag gesture handled separately (see
      // `_buildDrawGestureOverlay`/`_onDrawPanStart` etc.) — a plain tap
      // while the tool is selected does nothing.
      return;
    }

    // Only snap to waypoints in the *current*, not-yet-closed loop — see
    // RouteCreatePage's `_onMapTap` for why snapping into an already-closed
    // loop would produce a polygon spanning both.
    if (_waypoints.length >= 2) {
      for (int i = _activeLoopStartSegment; i < _waypoints.length - 1; i++) {
        if (const Distance()(_waypoints[i], tapPoint) <= _snapThresholdMeters) {
          await _routeAndCloseAtWaypoint(i);
          return;
        }
      }
    }

    await _extendRouteTo(tapPoint);
    if (!mounted) return;
    _pushHistory();
  }

  /// Adds [point] as the next waypoint — routing from the current route tip
  /// (if any) to it, and checking whether the new segment closes a loop —
  /// without pushing undo/redo history (`_onMapTap` pushes it once right
  /// after). A drawn stroke does *not* go through this — see
  /// `_convertDrawingToRoute`, which needs retry/skip-ahead behaviour this
  /// straight-to-fallback version doesn't have.
  Future<void> _extendRouteTo(LatLng point) async {
    final prev = _waypoints.isNotEmpty ? _waypoints.last : null;
    setState(() => _waypoints.add(point));

    if (prev == null) return; // first pin — nothing to route yet

    setState(() => _isRouting = true);
    final seg = await RoutingService.fetchRoute(prev, point) ??
        RoutingService.straightLine(prev, point);

    if (!mounted) return;
    setState(() {
      _segments.add(seg);
      _isRouting = false;
    });

    _checkSelfIntersection();
  }

  // ── Freehand drawing (mirrors RouteCreatePage) ────────────────────────────

  void _onDrawPanStart(DragStartDetails details) {
    if (!_canUseDrawTool || _isConvertingDrawing) return;
    setState(() {
      _drawnPoints
        ..clear()
        ..add(_mapController.camera.offsetToCrs(details.localPosition));
    });
  }

  void _onDrawPanUpdate(DragUpdateDetails details) {
    if (!_canUseDrawTool || _isConvertingDrawing || _drawnPoints.isEmpty) {
      return;
    }
    setState(() {
      _drawnPoints.add(
        _mapController.camera.offsetToCrs(details.localPosition),
      );
    });
  }

  Future<void> _onDrawPanEnd(DragEndDetails details) async {
    if (!_canUseDrawTool || _isConvertingDrawing || _drawnPoints.isEmpty) {
      return;
    }
    final rawPoints = List<LatLng>.from(_drawnPoints);
    setState(() {
      _drawnPoints.clear();
      _isConvertingDrawing = true;
    });

    await _convertDrawingToRoute(rawPoints);

    if (!mounted) return;
    setState(() {
      _isConvertingDrawing = false;
      // Only actually switch tools if the stroke produced a route — a too-
      // short/jittery gesture is silently rejected by `_sampleDrawnPath`,
      // leaving the canvas untouched, so let the user just try drawing
      // again without reselecting the tool. Draw is one-shot
      // (`_canUseDrawTool`), so once it *did* produce a route, switch back
      // to Pin automatically.
      if (_waypoints.isNotEmpty) _activeTool = _Tool.pinDrop;
    });
  }

  // Kept modest — see RouteCreatePage's `_maxDrawSamples` for the full
  // rationale (a shared, rate-limited ORS key means fewer requests per
  // drawn route matters more than tight shape fidelity).
  static const int _maxDrawSamples = 15;
  static const double _minDrawSampleSpacingMeters = 40;
  static const double _minDrawPathLengthMeters = 20;

  /// Downsamples a raw finger path to a manageable number of waypoints —
  /// see RouteCreatePage's `_sampleDrawnPath` for the full rationale.
  List<LatLng> _sampleDrawnPath(List<LatLng> raw) {
    if (raw.length < 2) return const [];
    const dist = Distance();

    double totalLength = 0;
    for (int i = 1; i < raw.length; i++) {
      totalLength += dist(raw[i - 1], raw[i]);
    }
    if (totalLength < _minDrawPathLengthMeters) return const [];

    final spacing = math.max(
      _minDrawSampleSpacingMeters,
      totalLength / _maxDrawSamples,
    );

    final sampled = <LatLng>[raw.first];
    double accumulated = 0;
    for (int i = 1; i < raw.length; i++) {
      accumulated += dist(raw[i - 1], raw[i]);
      if (accumulated >= spacing) {
        sampled.add(raw[i]);
        accumulated = 0;
      }
    }
    if (sampled.last != raw.last) sampled.add(raw.last);
    return sampled;
  }

  /// Retries a single failed road-snap request before giving up on it — see
  /// RouteCreatePage's `_fetchRoadRouteWithRetry` for the full rationale.
  /// Never retries a 429 specifically.
  static const int _drawRouteMaxRetries = 1;

  /// If a hop still fails after retries, how many additional samples ahead
  /// to try reaching in one longer hop before giving up on it — see
  /// RouteCreatePage's `_drawRouteMaxSkipAhead` (kept small so a struggling
  /// hop doesn't itself amplify request volume into more throttling).
  static const int _drawRouteMaxSkipAhead = 2;

  Future<RouteSegment?> _fetchRoadRouteWithRetry(LatLng from, LatLng to) async {
    for (int attempt = 0; ; attempt++) {
      final seg = await RoutingService.fetchRoute(
        from,
        to,
        throwOnRateLimit: true,
      );
      if (seg != null || attempt >= _drawRouteMaxRetries) return seg;
      await Future.delayed(const Duration(milliseconds: 350));
    }
  }

  /// Converts a finished freehand stroke into an actual routed sequence of
  /// waypoints — see RouteCreatePage's `_convertDrawingToRoute` for the full
  /// rationale (retry + reach-further-ahead instead of falling back to a
  /// raw straight line the moment one hop fails, so the drawn route stays
  /// road-snapped even where the finger path itself wandered off any real
  /// path). Pushes undo/redo history once for the whole conversion, not
  /// once per sampled point.
  Future<void> _convertDrawingToRoute(List<LatLng> rawPoints) async {
    final sampled = _sampleDrawnPath(rawPoints);
    if (sampled.length < 2) return;

    setState(() {
      _isRouting = true;
      _waypoints.add(sampled.first);
    });

    int i = 1;
    while (i < sampled.length) {
      if (!mounted) return;

      RouteSegment? seg;
      int target = i;
      int skipped = 0;
      while (true) {
        try {
          seg = await _fetchRoadRouteWithRetry(_waypoints.last, sampled[target]);
        } on RoutingRateLimitedException {
          // Actively throttled — don't reach further ahead into the same
          // wall. Accept a straight line for this hop only and let the
          // next one try fresh.
          seg = null;
          break;
        }
        if (seg != null) break;
        if (skipped >= _drawRouteMaxSkipAhead || target == sampled.length - 1) {
          break;
        }
        skipped++;
        target++;
      }
      if (!mounted) return;

      seg ??= RoutingService.straightLine(_waypoints.last, sampled[target]);

      setState(() {
        _waypoints.add(sampled[target]);
        _segments.add(seg!);
      });
      _checkSelfIntersection();
      i = target + 1;
    }

    if (!mounted) return;
    setState(() {
      _isRouting = false;
      _drawnPointsCount = _waypoints.length;
    });
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
    // Scoped to segments added since the last loop closed — see
    // RouteCreatePage's `_checkSelfIntersection` for the full rationale.
    if (_segments.length - _activeLoopStartSegment < 2) return;

    final newPoly = _segments.last.polyline;
    final prevCount = _segments.length - 1;

    for (int si = _activeLoopStartSegment; si < prevCount; si++) {
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
      _loopPolygons = [..._loopPolygons, polygon];
      _loopAreasM2 = [..._loopAreasM2, area];
      _activeLoopStartSegment = _segments.length;
    });
  }

  // ── Pin deletion ──────────────────────────────────────────────────────────

  Future<void> _deletePin(int index) async {
    // `_isRouting` alone isn't enough while a drawn stroke is converting —
    // it flickers false between that conversion's sequential fetches.
    if (_isRouting || _isConvertingDrawing) return;

    // Deleting any pin breaks the current topology — clear every loop
    // closed so far and restart loop-detection from scratch. Also un-hides
    // any drawn-segment interior points, since indices shifting under a
    // deletion means "the first N waypoints came from drawing" is no
    // longer a safe assumption to render off of.
    setState(() {
      _loopPolygons = [];
      _loopAreasM2 = [];
      _activeLoopStartSegment = 0;
      _drawnPointsCount = 0;
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
        loopsCompleted: _loopPolygons.length,
        path: poly,
        closedLoops: _loopPolygons,
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
          // Sits directly above the map (so it can capture the drawing
          // gesture) but below the sheet/buttons/top bar (so those still
          // get their own taps first via normal Z-order hit-testing).
          if (_activeTool == _Tool.freeDraw && _canUseDrawTool)
            _buildDrawGestureOverlay(),
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
    // Pan is disabled for the duration of Draw mode (pinch-zoom stays on) —
    // see RouteCreatePage's `_buildMap` for the full rationale: a
    // single-finger drag needs to mean "draw a shape", not "pan the map",
    // and the drawing gesture is captured by a separate overlay instead of
    // fighting flutter_map's own pan recognizer for the same gesture. Rotate
    // is excluded from flutter_map's own flags in both branches — handled
    // instead by the wrapping `EnhancedMapGestures` (dead-zoned two-finger
    // rotate + a little zoom inertia, shared with every other map screen;
    // see that widget).
    final drawModeActive = _activeTool == _Tool.freeDraw && _canUseDrawTool;

    return EnhancedMapGestures(
      mapController: _mapController,
      child: FlutterMap(
        mapController: _mapController,
        options: MapOptions(
          initialCenter: _currentPosition ?? const LatLng(45.4642, 9.1900),
          initialZoom: _defaultZoom,
          interactionOptions: InteractionOptions(
            flags: drawModeActive
                ? InteractiveFlag.pinchZoom
                : InteractiveFlag.all & ~InteractiveFlag.rotate,
          ),
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

          if (_loopPolygons.isNotEmpty)
            PolygonLayer(
              polygons: [
                for (final loop in _loopPolygons)
                  Polygon(
                    points: loop,
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
          // ── Live freehand-drawing trail (raw finger path, not yet
          // road-snapped) ────────────────────────────────────────────────
          if (_drawnPoints.length >= 2)
            PolylineLayer(
              polylines: [
                Polyline(
                  points: _drawnPoints,
                  color: const Color(0xFF4A8C52).withValues(alpha: 0.6),
                  strokeWidth: 3.0,
                  pattern: StrokePattern.dashed(segments: const [6, 6]),
                ),
              ],
            ),
          if (_currentPosition != null)
            MarkerLayer(
              markers: [
                Marker(point: _currentPosition!, width: 60, height: 60, child: const _LocationDot()),
              ],
            ),
          // Interior points of a drawn segment are excluded here — see
          // `_isHiddenWaypoint` — so a drawn shape only ever shows a start
          // and finish pin, never one per road-snap sample.
          if (_waypoints.isNotEmpty)
            MarkerLayer(
              markers: _waypoints
                  .asMap()
                  .entries
                  .where((e) => !_isHiddenWaypoint(e.key))
                  .map((e) {
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
                  })
                  .toList(),
            ),
        ],
      ),
    );
  }

  /// Captures the freehand-drawing gesture — see RouteCreatePage's
  /// `_buildDrawGestureOverlay` for the full rationale.
  Widget _buildDrawGestureOverlay() {
    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: _onDrawPanStart,
        onPanUpdate: _onDrawPanUpdate,
        onPanEnd: _onDrawPanEnd,
      ),
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
                  const SizedBox(width: 6),
                  _ToolButton(
                    icon: Icons.edit_outlined,
                    label: 'Draw',
                    active: _activeTool == _Tool.freeDraw && !_isDeleteMode,
                    // One-shot — only usable to lay down the very first
                    // shape on an empty run (see `_canUseDrawTool`).
                    onTap: _canUseDrawTool
                        ? () => setState(() {
                            _activeTool = _Tool.freeDraw;
                            _isDeleteMode = false;
                          })
                        : null,
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
                          onPressed:
                              (_waypoints.length >= 2 &&
                                  _manualMinutes != null &&
                                  !_isPublishing &&
                                  !_isConvertingDrawing)
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
        if (_loopPolygons.isNotEmpty) ...[
          const SizedBox(height: 8),
          _LoopAreaBanner(
            areaM2: _totalLoopAreaM2,
            loopCount: _loopPolygons.length,
          ),
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

  /// How many separate loops have been closed so far — a test run isn't
  /// limited to just one, so the label/total reflect all of them combined.
  final int loopCount;

  const _LoopAreaBanner({required this.areaM2, required this.loopCount});

  String get _areaLabel => GeometryUtils.formatAreaKm2(areaM2);

  @override
  Widget build(BuildContext context) {
    final label = loopCount > 1
        ? '$loopCount circuits closed!'
        : 'Circuit closed!';
    final areaLabelPrefix = loopCount > 1 ? 'Total area' : 'Area';

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
          Text(
            label,
            style: const TextStyle(color: Color(0xFF2E7D32), fontWeight: FontWeight.w600, fontSize: 13),
          ),
          const Spacer(),
          const Icon(Icons.crop_free_rounded, size: 16, color: Color(0xFF4A8C52)),
          const SizedBox(width: 6),
          Text(
            '$areaLabelPrefix: $_areaLabel',
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
