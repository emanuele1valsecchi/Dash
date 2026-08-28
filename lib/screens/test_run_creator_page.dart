import 'dart:async';

import 'package:dash/extensions/dash_snackbar.dart';
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
import '../services/drawn_route_converter.dart';
import '../services/routing_service.dart';
import '../services/run_session_repository.dart';
import '../utils/geometry_utils.dart';
import '../widgets/units_scope.dart';
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
  /// than one separate area (see `_TestRunCreatorPageState._loopRangeStart`).
  final List<List<LatLng>> loopPolygons;
  final List<double> loopAreasM2;
  final List<int> loopRangeStart;
  final List<int> loopRangeEnd;

  /// How many *leading* waypoints came from the most recent freehand-draw
  /// conversion (0 if built purely by tapping pins) — see
  /// `_isHiddenWaypoint`.
  final int drawnPointsCount;

  _RunSnapshot({
    required this.waypoints,
    required this.segments,
    this.loopPolygons = const [],
    this.loopAreasM2 = const [],
    this.loopRangeStart = const [],
    this.loopRangeEnd = const [],
    this.drawnPointsCount = 0,
  });
}

// ── Page ───────────────────────────────────────────────────────────────────────

class _TestRunCreatorPageState extends State<TestRunCreatorPage> with TickerProviderStateMixin {
  StreamSubscription<List<ClaimedArea>>? _areasSub;

  // ── Map ───────────────────────────────────────────────────────────────────
  final MapController _mapController = MapController();
  LatLng? _currentPosition;
  bool _isLoadingLocation = true;
  bool _isCameraAnimating = false;
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

  /// The `[_segments]` index range each entry in [_loopPolygons] was built
  /// from — see RouteCreatePage's fields of the same name for the full
  /// rationale (used only to detect when a newly-closed loop supersedes an
  /// earlier one; the intersection search itself always looks at the whole
  /// route).
  List<int> _loopRangeStart = [];
  List<int> _loopRangeEnd = [];

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
    _startAreasStream();
  }

  void _startAreasStream() {
    _areasSub = ClaimedAreaRepository.instance.areasStream().listen((areas) {
      if (!mounted) return;
      setState(() => _allAreas = areas);
    });
  }

  @override
  void dispose() {
    _areasSub?.cancel();
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
      loopRangeStart: List<int>.from(_loopRangeStart),
      loopRangeEnd: List<int>.from(_loopRangeEnd),
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
      _loopRangeStart = List<int>.from(snap.loopRangeStart);
      _loopRangeEnd = List<int>.from(snap.loopRangeEnd);
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
    // close as many separate areas as needed.
    if (_isRouting || _isDeleteMode) return;

    if (_activeTool == _Tool.freeDraw) {
      // Drawing is a press-and-drag gesture handled separately (see
      // `_buildDrawGestureOverlay`/`_onDrawPanStart` etc.) — a plain tap
      // while the tool is selected does nothing.
      return;
    }

    // Any earlier waypoint is a valid snap target, including one already
    // part of a closed loop — see RouteCreatePage's `_onMapTap` for why.
    if (_waypoints.length >= 2) {
      for (int i = 0; i < _waypoints.length - 1; i++) {
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
    setState(() {
      // A failed draw conversion leaves the raw stroke on screen as a
      // retryable dashed trail — placing a pin means the user moved on,
      // so drop the leftover ink.
      _drawnPoints.clear();
      _waypoints.add(point);
    });

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
      // short/jittery gesture is silently rejected (see
      // DrawnRouteConverter.minStrokeLengthMeters) and a failed conversion
      // just restores the raw trail, so in both cases let the user try
      // drawing again without reselecting the tool. Draw is one-shot
      // (`_canUseDrawTool`), so once it *did* produce a route, switch back
      // to Pin automatically.
      if (_waypoints.isNotEmpty) _activeTool = _Tool.pinDrop;
    });
  }

  /// Converts a finished freehand stroke via [DrawnRouteConverter.convert]
  /// — one network operation for the whole stroke (at most 3 upstream
  /// routing calls, vs. the old 15–90 chained point-to-point requests),
  /// typed failures, and NO straight-line fallback. See RouteCreatePage's
  /// `_convertDrawingToRoute` for the full rationale; the heavy lifting is
  /// shared in DrawnRouteConverter so this dev page and the real builder
  /// can't drift apart again.
  Future<void> _convertDrawingToRoute(List<LatLng> rawPoints) async {
    setState(() => _isRouting = true);
    final result = await DrawnRouteConverter.convert(rawPoints);
    if (!mounted) return;
    setState(() => _isRouting = false);

    switch (result) {
      case DrawnRouteTooShort():
        // Accidental tap/jitter — silently ignore, like before.
        break;

      case DrawnRouteFailure failure:
        // Keep the ink on screen so Retry is meaningful; a new stroke
        // clears it via `_onDrawPanStart`, a pin via `_extendRouteTo`.
        setState(() {
          _drawnPoints
            ..clear()
            ..addAll(rawPoints);
        });
        _showDrawConversionError(failure, rawPoints);

      case DrawnRouteSuccess success:
        setState(() => _waypoints.add(success.waypoints.first));
        for (int k = 0; k < success.segments.length; k++) {
          setState(() {
            _waypoints.add(success.waypoints[k + 1]);
            _segments.add(success.segments[k]);
          });
          _checkSelfIntersection();
        }
        setState(() => _drawnPointsCount = _waypoints.length);
        _pushHistory();
    }
  }

  /// Mirrors RouteCreatePage's `_retryStrokeConversion` — snackbar Retry
  /// entry point, same guards/lifecycle as `_onDrawPanEnd`.
  Future<void> _retryStrokeConversion(List<LatLng> rawPoints) async {
    if (!_canUseDrawTool || _isConvertingDrawing) return;
    setState(() {
      _drawnPoints.clear();
      _isConvertingDrawing = true;
    });
    await _convertDrawingToRoute(rawPoints);
    if (!mounted) return;
    setState(() {
      _isConvertingDrawing = false;
      if (_waypoints.isNotEmpty) _activeTool = _Tool.pinDrop;
    });
  }

  void _showDrawConversionError(
    DrawnRouteFailure failure,
    List<LatLng> rawPoints,
  ) {
    final message = switch (failure.kind) {
      DrawnRouteFailureKind.rateLimited =>
        'Routing is busy right now — wait a few seconds and retry.',
      DrawnRouteFailureKind.quotaExhausted =>
        'The daily routing quota is used up — drawing will work again after '
            'it resets.',
      DrawnRouteFailureKind.noRoute =>
        'Couldn\'t match the drawing to walkable paths. Try following roads '
            'more closely.',
      DrawnRouteFailureKind.network =>
        'Couldn\'t reach the routing service. Check your connection and '
            'retry.',
      DrawnRouteFailureKind.serviceError =>
        'The routing service had a problem. Please try again.',
    };
    context.showErrorSnackBar(
      message,
      action: failure.isRetryable
        ? SnackBarAction(
            label: 'Retry',
            textColor: Theme.of(context).colorScheme.onErrorContainer,
            onPressed: () => _retryStrokeConversion(rawPoints),
          )
        : null,
    );
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

    // The snap target itself is always a valid closure, but the new closing
    // segment might also cut back through even earlier ground — see
    // RouteCreatePage's `_routeAndCloseAtWaypoint` for the full rationale.
    final directPolygon = _polygonFromWaypointIndex(waypointIdx);
    final crossing = _findBestSelfIntersection();

    if (crossing != null &&
        GeometryUtils.polygonAreaM2(crossing.polygon) >
            GeometryUtils.polygonAreaM2(directPolygon)) {
      _finaliseLoop(
        crossing.polygon,
        rangeStart: crossing.rangeStart,
        rangeEnd: _segments.length - 1,
      );
    } else {
      _finaliseLoop(
        directPolygon,
        rangeStart: waypointIdx,
        rangeEnd: _segments.length - 1,
      );
    }
    _pushHistory();
  }

  // ── Self-intersection detection (mirrors RouteCreatePage) ────────────────

  void _checkSelfIntersection() {
    final best = _findBestSelfIntersection();
    if (best != null) {
      _finaliseLoop(
        best.polygon,
        rangeStart: best.rangeStart,
        rangeEnd: _segments.length - 1,
      );
    }
  }

  /// Mirrors RouteCreatePage's `_findBestSelfIntersection` — pure search, no
  /// side effects, so `_routeAndCloseAtWaypoint` can also use it to check
  /// whether its own new closing segment cuts back through even earlier
  /// ground than the snap target it was aimed at.
  ({List<LatLng> polygon, int rangeStart})? _findBestSelfIntersection() {
    if (_segments.length < 2) return null;

    final newPoly = _segments.last.polyline;
    final prevCount = _segments.length - 1;

    // Checked against the *entire* route, not just segments added since the
    // last loop closed, and the crossing enclosing the largest area wins —
    // see RouteCreatePage's `_findBestSelfIntersection` for the full rationale.
    List<LatLng>? bestPolygon;
    double bestArea = 0;
    int bestStartSegment = 0;

    for (int si = 0; si < prevCount; si++) {
      final existPoly = _segments[si].polyline;
      final isAdjacent = si == prevCount - 1;

      final existEnd =
          isAdjacent ? (existPoly.length - 3).clamp(0, existPoly.length) : existPoly.length;
      final newStart = isAdjacent ? 3 : 1;

      if (newStart >= newPoly.length || existEnd <= 0) continue;

      void considerCandidate(List<LatLng> polygon) {
        if (polygon.length < 3) return;
        final area = GeometryUtils.polygonAreaM2(polygon);
        if (area < _minLoopAreaM2 || area <= bestArea) return;
        bestArea = area;
        bestPolygon = polygon;
        bestStartSegment = si;
      }

      for (int ni = newStart; ni < newPoly.length; ni++) {
        for (int ei = 0; ei < existEnd; ei++) {
          if (const Distance()(newPoly[ni], existPoly[ei]) <= _proximityThresholdMeters) {
            considerCandidate(_polygonFromIntersection(existPoly[ei], si, ei, ni));
          }
        }
      }

      // The new segment's first edge is only excluded when `si` is the
      // literal adjacent segment — see RouteCreatePage for why.
      final edgeEnd =
          isAdjacent ? (existPoly.length - 2).clamp(0, existPoly.length - 1) : existPoly.length - 1;
      final crossNewStart = isAdjacent ? 1 : 0;

      for (int ei = 0; ei < edgeEnd; ei++) {
        for (int ni = crossNewStart; ni < newPoly.length - 1; ni++) {
          final pt = GeometryUtils.segmentIntersection(
            existPoly[ei], existPoly[ei + 1],
            newPoly[ni], newPoly[ni + 1],
          );
          if (pt != null) {
            considerCandidate(_polygonFromIntersection(pt, si, ei, ni));
          }
        }
      }

      // Vertex lying exactly on the other polyline's interior (both
      // directions) — see RouteCreatePage's `_findBestSelfIntersection` for
      // why this is a distinct case from the two checks above.
      for (int ei = 0; ei < existEnd; ei++) {
        for (int ni = crossNewStart; ni < newPoly.length - 1; ni++) {
          if (GeometryUtils.pointToSegmentDistanceMeters(
                existPoly[ei], newPoly[ni], newPoly[ni + 1],
              ) <=
              _proximityThresholdMeters) {
            considerCandidate(_polygonFromIntersection(existPoly[ei], si, ei, ni));
          }
        }
      }
      for (int ni = newStart; ni < newPoly.length; ni++) {
        for (int ei = 0; ei < edgeEnd; ei++) {
          if (GeometryUtils.pointToSegmentDistanceMeters(
                newPoly[ni], existPoly[ei], existPoly[ei + 1],
              ) <=
              _proximityThresholdMeters) {
            considerCandidate(_polygonFromIntersection(newPoly[ni], si, ei, ni));
          }
        }
      }
    }

    final polygon = bestPolygon;
    if (polygon == null) return null;
    return (polygon: polygon, rangeStart: bestStartSegment);
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

  /// Mirrors RouteCreatePage's `_finaliseLoop` — supersedes any already-closed
  /// loop that this one both overlaps in `[rangeStart, rangeEnd]` segment span
  /// *and* geometrically covers — see `RouteCreatePage._finaliseLoop`, which
  /// this mirrors, for why the span test alone wrongly deleted a neighbouring
  /// block that merely shared a street with the new one.
  void _finaliseLoop(
    List<LatLng> polygon, {
    required int rangeStart,
    required int rangeEnd,
  }) {
    if (polygon.length < 3) return;
    final area = GeometryUtils.polygonAreaM2(polygon);
    if (area < _minLoopAreaM2) return;
      // The mirror image of superseding, and the other half of the same rule:
      // a loop drawn wholly inside one already recorded encloses no ground
      // that is not already claimed, so recording it would inflate the
      // route's reported area for a shape that adds nothing. Checked before
      // the supersede pass below, so a re-drawn near-identical loop keeps the
      // original rather than swapping in a duplicate of it.
      for (final existing in _loopPolygons) {
        if (GeometryUtils.polygonCoversPolygon(existing, polygon)) return;
      }
    setState(() {
      final newPolygons = <List<LatLng>>[];
      final newAreas = <double>[];
      final newRangeStart = <int>[];
      final newRangeEnd = <int>[];
      for (int i = 0; i < _loopPolygons.length; i++) {
        // Sharing a segment span is necessary but not sufficient: two blocks
        // claimed by one route share the street between them, so their spans
        // touch even though neither covers the other's ground. Superseding on
        // the span alone silently deleted the first block the moment the
        // second closed — confirmed in the field by pinning two adjacent
        // squares. The geometric check is what distinguishes "drawn around
        // it" from "next door to it".
        final supersedes =
            _loopRangeStart[i] <= rangeEnd &&
                rangeStart <= _loopRangeEnd[i] &&
                GeometryUtils.polygonCoversPolygon(polygon, _loopPolygons[i]);
        if (supersedes) continue;
        newPolygons.add(_loopPolygons[i]);
        newAreas.add(_loopAreasM2[i]);
        newRangeStart.add(_loopRangeStart[i]);
        newRangeEnd.add(_loopRangeEnd[i]);
      }
      newPolygons.add(polygon);
      newAreas.add(area);
      newRangeStart.add(rangeStart);
      newRangeEnd.add(rangeEnd);
      _loopPolygons = newPolygons;
      _loopAreasM2 = newAreas;
      _loopRangeStart = newRangeStart;
      _loopRangeEnd = newRangeEnd;
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
      _loopRangeStart = [];
      _loopRangeEnd = [];
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
      _animateCameraTo(_currentPosition!, _defaultZoom);
    }
  }

  /// Animates the camera to [targetCenter]/[targetZoom] over a short tween
  /// instead of jumping instantly — same "my location" pan/zoom flourish as
  /// `RunTrackingPage._centerOnUser`. flutter_map has no built-in animated
  /// move, so this drives one manually: an [AnimationController] ticks a
  /// lat/lng/zoom [Tween] and calls [MapController.move] each frame, then
  /// disposes itself once the animation finishes.
  Future<void> _animateCameraTo(LatLng targetCenter, double targetZoom) async {
    if (_isCameraAnimating) return;
    _isCameraAnimating = true;

    final MapCamera camera;
    try {
      camera = _mapController.camera;
    } catch (_) {
      _isCameraAnimating = false;
      return; // Map not attached yet.
    }

    final latTween = Tween<double>(begin: camera.center.latitude, end: targetCenter.latitude);
    final lngTween = Tween<double>(begin: camera.center.longitude, end: targetCenter.longitude);
    final zoomTween = Tween<double>(begin: camera.zoom, end: targetZoom);

    final controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 650));
    final curved = CurvedAnimation(parent: controller, curve: Curves.easeInOutCubic);

    void tick() {
      try {
        _mapController.move(
          LatLng(latTween.transform(curved.value), lngTween.transform(curved.value)),
          zoomTween.transform(curved.value),
        );
      } catch (_) {}
    }

    controller.addListener(tick);
    try {
      await controller.forward();
    } finally {
      controller.removeListener(tick);
      controller.dispose();
      _isCameraAnimating = false;
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
      context.showSuccessSnackBar("Test run published");

      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;

      context.showErrorSnackBar("Failed to publish");
      
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
          minZoom: MapStyle.minZoom,
          cameraConstraint: CameraConstraint.contain(bounds: MapStyle.safeCameraBounds),
          interactionOptions: InteractionOptions(
            // Fling stays enabled in the non-draw branch —
            // EnhancedMapGestures cancels it specifically when triggered by
            // a corrupted post-multi-touch velocity reading, rather than
            // blanket-disabling it; see its class doc, point 3.
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
    final units = Units.of(context);
    final hasPins = _waypoints.length >= 2;
    final distLabel =
        hasPins ? units.distance(_totalDistanceKm * 1000) : '—';
    final timeLabel = _manualMinutes != null ? '$_manualMinutes min' : 'Tap to set';
    final calLabel = hasPins ? units.energy(_estimatedCalories) : '—';

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

  @override
  Widget build(BuildContext context) {
    final areaLabel = Units.of(context).area(areaM2);
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
            '$areaLabelPrefix: $areaLabel',
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