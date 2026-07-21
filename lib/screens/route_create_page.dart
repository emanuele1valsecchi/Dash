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
import '../services/route_repository.dart';
import '../services/routing_service.dart';
import '../utils/geometry_utils.dart';
import '../widgets/map/area_visibility_toggle.dart';
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

  /// Nominatim's own 0–1 "how globally significant is this place" score
  /// (roughly population/notability). Used to break ties in our own
  /// re-ranking — see `_PlaceSearchBarState._rankPlaces` — so a famous city
  /// wins over an obscure same-name village even when the latter is an
  /// exact text match and the former only a prefix match. Places without a
  /// real score (the Overpass POI fallback) get a modest default, low
  /// enough that it won't outrank a genuine well-known Nominatim result.
  final double importance;

  const _Place({
    required this.displayName,
    required this.latLng,
    this.importance = 0.15,
  });
}

// ── Tool enum ──────────────────────────────────────────────────────────────────

enum _Tool { pinDrop, freeDraw }

// ── Done-dialog action ────────────────────────────────────────────────────────

enum _SaveAction { saveOnly, saveAndRun }

// ── Page ───────────────────────────────────────────────────────────────────────

class RouteCreatePage extends StatefulWidget {
  const RouteCreatePage({super.key});

  @override
  State<RouteCreatePage> createState() => _RouteCreatePageState();
}

class _RouteCreatePageState extends State<RouteCreatePage>
    with TickerProviderStateMixin {
  // ── Map ───────────────────────────────────────────────────────────────────
  final MapController _mapController = MapController();
  LatLng? _currentPosition;
  bool _isLoadingLocation = true;
  StreamSubscription<LatLng>? _positionSub;

  /// Guards [_flyTo] against overlapping animations (e.g. a second search
  /// selection tapped mid-flight).
  bool _isCameraAnimating = false;

  // ── Search ────────────────────────────────────────────────────────────────
  final TextEditingController _searchCtrl = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  Timer? _searchDebounce;
  List<_Place> _searchSuggestions = [];
  bool _searchSuppressNext = false;

  /// Whether search is "active" — i.e. focused (keyboard up) — which
  /// switches the top bar into the full-screen white takeover (see
  /// [_buildSearchOverlay]) instead of the small pill sitting over the map.
  /// Deliberately keyed on focus alone, not also "has suggestions": an
  /// earlier version also treated a non-empty `_searchSuggestions` as
  /// active, so that a stray async fetch resolving just after the field
  /// had already been unfocused (e.g. right after selecting a result) could
  /// flip the takeover back open on its own. Purely derived, not stored —
  /// nothing to keep in sync since focus already lives on this same State.
  bool get _searchActive => _searchFocusNode.hasFocus;

  // ── Claimed areas (display only — tapping the map drops a pin here) ──────
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
  final List<_RouteSnapshot> _history = [
    _RouteSnapshot(waypoints: [], segments: []),
  ];
  int _historyIndex = 0;

  bool get _canUndo => _historyIndex > 0 && !_isRouting;
  bool get _canRedo => _historyIndex < _history.length - 1 && !_isRouting;

  // ── Tools ─────────────────────────────────────────────────────────────────
  _Tool _activeTool = _Tool.pinDrop;
  bool _isDeleteMode = false;

  // ── Form ──────────────────────────────────────────────────────────────────
  final TextEditingController _trackNameCtrl = TextEditingController();
  final FocusNode _trackNameFocusNode = FocusNode();

  /// Whether the track-name field specifically has focus — as opposed to
  /// the unrelated search bar in the top bar, which also opens the keyboard
  /// but shouldn't budge the sheet at all (see `_buildSheet`).
  bool _trackNameFocused = false;
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
    _trackNameFocusNode.addListener(_onTrackNameFocusChanged);
    _searchCtrl.addListener(_onSearchChanged);
    _searchFocusNode.addListener(_onSearchFocusChanged);
  }

  Future<void> _loadClaimedAreas() async {
    final areas = await ClaimedAreaRepository.instance.fetchAllAreas();
    if (!mounted) return;
    setState(() => _allAreas = areas);
  }

  void _onTrackNameFocusChanged() {
    setState(() => _trackNameFocused = _trackNameFocusNode.hasFocus);
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    _mapController.dispose();
    _sheetController.dispose();
    _trackNameFocusNode.dispose();
    _trackNameCtrl.dispose();
    _searchDebounce?.cancel();
    _searchCtrl.dispose();
    _searchFocusNode.dispose();
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
    _history.add(
      _RouteSnapshot(
        waypoints: List<LatLng>.from(_waypoints),
        segments: List<RouteSegment>.from(_segments),
        isLoopClosed: _isLoopClosed,
        loopPolygon: List<LatLng>.from(_loopPolygon),
        loopAreaM2: _loopAreaM2,
      ),
    );
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
    // Tapping the map is "outside the text area" — dismiss the track-name
    // keyboard regardless of whether this tap goes on to place a pin.
    FocusScope.of(context).unfocus();

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
    final seg =
        await RoutingService.fetchRoute(prev, tapPoint) ??
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
    final seg =
        await RoutingService.fetchRoute(from, to) ??
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
            _finaliseLoop(_polygonFromIntersection(existPoly[ei], si, ei, ni));
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
            existPoly[ei],
            existPoly[ei + 1],
            newPoly[ni],
            newPoly[ni + 1],
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
      // Middle pin: remove its two adjacent segments then bridge the gap.
      newSegments.removeAt(index); // outgoing segment
      newSegments.removeAt(index - 1); // incoming segment

      setState(() {
        _waypoints = newWaypoints;
        _segments = newSegments;
        _isRouting = true;
      });

      final bridge =
          await RoutingService.fetchRoute(
            newWaypoints[index - 1],
            newWaypoints[index],
          ) ??
          RoutingService.straightLine(
            newWaypoints[index - 1],
            newWaypoints[index],
          );

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
      // No zoom-out dip here (see `_flyTo`'s `zoomOutDip` param) — panning
      // back to a known nearby point doesn't need the "overview" flourish,
      // and skipping it also avoids the flurry of intermediate zoom-level
      // tile requests that dip triggered (which was tripping Jawg's rate
      // limit — a 429 on this exact button in practice).
      _flyTo(_currentPosition!, _defaultZoom, zoomOutDip: false);
    }
  }

  // ── Camera animation ──────────────────────────────────────────────────────

  /// Below this distance-and-zoom delta, [target]/[targetZoom] is considered
  /// "already there" — e.g. tapping "my location" while already centred on
  /// it should be a no-op, not a pointless little hop.
  static const double _flyToAlreadyThereMeters = 15.0;
  static const double _flyToAlreadyThereZoomDelta = 0.05;

  /// Floor for the zoom-out dip, regardless of how far apart the two points
  /// are — "un-zoom a bit" even for a transatlantic search result, not an
  /// almost-whole-Earth view. Also a deliberate guard against tile-request
  /// bursts: a very low, rarely-cached zoom level means flutter_map has to
  /// fetch a whole fresh, uncached tile set to fill the screen, and doing
  /// that mid-animation (transiting through many zoom levels in under a
  /// second) is exactly what was tripping Jawg's rate limit in practice.
  static const double _flyToMinDipZoom = 7.0;

  /// Animates the camera to [target]/[targetZoom]. When [zoomOutDip] is
  /// true (search-result selection), it's a brief "zoom out, pan, zoom back
  /// in" flourish (à la Google Maps) instead of an instant jump, scaled to
  /// the actual distance being covered: crossing a continent dips a lot,
  /// crossing the same neighbourhood barely dips at all. When false (the
  /// "my location" button), it's just a direct pan/zoom with no dip — that
  /// button is about returning to a known nearby point, not a "fly across
  /// the map" moment, and the dip's rapid intermediate zoom-level changes
  /// were also generating enough tile requests to trip Jawg's rate limit.
  Future<void> _flyTo(
    LatLng target,
    double targetZoom, {
    bool zoomOutDip = true,
  }) async {
    if (_isCameraAnimating) return;

    final MapCamera camera;
    try {
      camera = _mapController.camera;
    } catch (_) {
      _mapController.move(target, targetZoom); // map not attached yet
      return;
    }

    final startCenter = camera.center;
    final startZoom = camera.zoom;

    if (const Distance()(startCenter, target) < _flyToAlreadyThereMeters &&
        (startZoom - targetZoom).abs() < _flyToAlreadyThereZoomDelta) {
      return;
    }

    _isCameraAnimating = true;

    final Animatable<double> zoomAnimatable;
    if (zoomOutDip) {
      // The zoom level that would fit both the start and target points on
      // screen — the same technique `RunTrackingPage._fitPathInView` uses
      // for its "see whole path" overview — naturally scales with distance:
      // two nearby points already fit at (or above) the current zoom, so
      // the dip clamps away to nothing, while distant points force a real
      // zoom-out. Never lets the dip zoom IN past where the animation
      // starts or ends.
      double dipZoom;
      try {
        final fitCamera = CameraFit.coordinates(
          coordinates: [startCenter, target],
          padding: const EdgeInsets.all(40),
        ).fit(camera);
        dipZoom = fitCamera.zoom;
      } catch (_) {
        dipZoom = math.min(startZoom, targetZoom);
      }
      final dipZoomCeiling = math.max(
        _flyToMinDipZoom,
        math.min(startZoom, targetZoom),
      );
      dipZoom = dipZoom.clamp(_flyToMinDipZoom, dipZoomCeiling);

      zoomAnimatable = TweenSequence<double>([
        TweenSequenceItem(
          tween: Tween(
            begin: startZoom,
            end: dipZoom,
          ).chain(CurveTween(curve: Curves.easeOut)),
          weight: 50,
        ),
        TweenSequenceItem(
          tween: Tween(
            begin: dipZoom,
            end: targetZoom,
          ).chain(CurveTween(curve: Curves.easeIn)),
          weight: 50,
        ),
      ]);
    } else {
      zoomAnimatable = Tween<double>(begin: startZoom, end: targetZoom);
    }

    final latTween = Tween<double>(
      begin: startCenter.latitude,
      end: target.latitude,
    );
    final lngTween = Tween<double>(
      begin: startCenter.longitude,
      end: target.longitude,
    );

    final controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    final curved = CurvedAnimation(parent: controller, curve: Curves.easeInOut);

    void tick() {
      try {
        _mapController.move(
          LatLng(
            latTween.transform(curved.value),
            lngTween.transform(curved.value),
          ),
          zoomAnimatable.transform(curved.value),
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

  /// Smoothly rotates the map to [targetDegrees] (always 0 — "reset north")
  /// along whichever direction is shorter, instead of [MapController.rotate]'s
  /// instant snap. Deliberately doesn't touch zoom/centre — just a rotation.
  Future<void> _animateRotationTo(double targetDegrees) async {
    final MapCamera camera;
    try {
      camera = _mapController.camera;
    } catch (_) {
      return;
    }
    final start = camera.rotation;
    var diff = (targetDegrees - start + 180) % 360 - 180;
    if (diff < -180) diff += 360;

    final rotationTween = Tween<double>(begin: start, end: start + diff);
    final controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    final curved = CurvedAnimation(parent: controller, curve: Curves.easeInOut);

    void tick() {
      try {
        _mapController.rotate(rotationTween.transform(curved.value));
      } catch (_) {}
    }

    controller.addListener(tick);
    try {
      await controller.forward();
    } finally {
      controller.removeListener(tick);
      controller.dispose();
    }
  }

  // ── Exit confirmation ─────────────────────────────────────────────────────

  /// Handles a blocked system back gesture/hardware button (see [build]'s
  /// `PopScope.canPop`) — fires with `didPop: false` whenever search is
  /// active or the route has pins and the system tried to pop anyway.
  Future<void> _handleSystemPopInvoked(bool didPop, Object? result) async {
    if (didPop) return;
    if (_searchActive) {
      _closeSearch();
      return;
    }
    if (await _confirmDiscardRoute() && mounted) Navigator.of(context).pop();
  }

  /// Prompts before leaving if at least one pin has been placed, so an
  /// accidental back tap/gesture doesn't silently discard in-progress work.
  Future<void> _handleBackPressed() async {
    if (_waypoints.isEmpty) {
      Navigator.of(context).pop();
      return;
    }
    if (await _confirmDiscardRoute() && mounted) Navigator.of(context).pop();
  }

  /// Shared by the top-bar back button and the system back gesture/hardware
  /// button (via [PopScope] in [build]) — both need the same "discard
  /// unsaved pins?" prompt.
  Future<bool> _confirmDiscardRoute() async {
    final confirmed = await _showConfirmDialog(
      title: 'Discard this route?',
      message:
          'You have unsaved pins on the map. Going back will discard them.',
      confirmLabel: 'Discard',
      destructive: true,
    );
    return confirmed == true;
  }

  Future<bool?> _showConfirmDialog({
    required String title,
    required String message,
    required String confirmLabel,
    required bool destructive,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: const Color(0xFFF5F6EF),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 24, 22, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF2A3028),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                message,
                style: const TextStyle(
                  fontSize: 14,
                  height: 1.4,
                  color: Color(0xFF5E655C),
                ),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(ctx).pop(false),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFF5E655C),
                        side: const BorderSide(color: Color(0xFFCFCFCF)),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: const Text(
                        'Cancel',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () => Navigator.of(ctx).pop(true),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: destructive
                            ? const Color(0xFFF4C7C3)
                            : const Color(0xFFCAF0B8),
                        foregroundColor: destructive
                            ? const Color(0xFF8A3B34)
                            : const Color(0xFF2E7D32),
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: Text(
                        confirmLabel,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
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
            onTap: () => _animateRotationTo(0),
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

  /// Merges [_segments] into a single flat polyline, skipping duplicate
  /// junction points between consecutive segments.
  List<LatLng> _mergedPolyline() {
    final poly = <LatLng>[];
    for (int s = 0; s < _segments.length; s++) {
      final pts = _segments[s].polyline;
      final start = s == 0 ? 0 : 1;
      for (int i = start; i < pts.length; i++) {
        poly.add(pts[i]);
      }
    }
    return poly;
  }

  /// Writes the route to Firestore. Returns whether it succeeded; the caller
  /// decides what happens next (plain save vs. save-and-run), since a success
  /// snackbar only makes sense for one of those two flows.
  Future<bool> _saveRoute(List<LatLng> poly) async {
    if (_isPublishing) return false;
    setState(() => _isPublishing = true);
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
      return true;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to publish: $e')));
      }
      return false;
    } finally {
      if (mounted) setState(() => _isPublishing = false);
    }
  }

  Future<void> _handleDonePressed() async {
    if (_isPublishing) return;
    final action = await _showSaveOptionsDialog();
    if (action == null || !mounted) return;

    final poly = _mergedPolyline();
    final ok = await _saveRoute(poly);
    if (!ok || !mounted) return;

    if (action == _SaveAction.saveOnly) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Route published!')));
      Navigator.of(context).pop();
    } else {
      // Save route and Run — hand the polyline back so the caller can push
      // straight into RunTrackingPage with it as a guide line.
      Navigator.of(context).pop(poly);
    }
  }

  Future<_SaveAction?> _showSaveOptionsDialog() {
    return showDialog<_SaveAction>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: const Color(0xFFF5F6EF),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 24, 22, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Save route',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF2A3028),
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                'What would you like to do with this route?',
                style: TextStyle(
                  fontSize: 14,
                  height: 1.4,
                  color: Color(0xFF5E655C),
                ),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () =>
                      Navigator.of(ctx).pop(_SaveAction.saveAndRun),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFCAF0B8),
                    foregroundColor: const Color(0xFF2E7D32),
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: const Text(
                    'Save route and Run',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: () => Navigator.of(ctx).pop(_SaveAction.saveOnly),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF5E655C),
                    side: const BorderSide(color: Color(0xFFCFCFCF)),
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: const Text(
                    'Save route',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ),
              const SizedBox(height: 4),
              SizedBox(
                width: double.infinity,
                child: TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text(
                    'Cancel',
                    style: TextStyle(color: Color(0xFF5E655C)),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Only gates the system back gesture/hardware button — explicit pops
      // elsewhere (e.g. after a successful save) are untouched by this.
      // Also gated on search being active, so the first system-back while
      // searching just closes search (see `_handleSystemPopInvoked`) instead
      // of leaving route creation entirely.
      canPop: _waypoints.isEmpty && !_searchActive,
      onPopInvokedWithResult: _handleSystemPopInvoked,
      child: Scaffold(
        // Manual keyboard handling instead (see `_buildSheet`): the default
        // resize applies to the whole body regardless of which field
        // triggered the keyboard, which is exactly what made the sheet also
        // rise/shrink when the *search bar* (top bar, unrelated to the
        // sheet) was focused. We only want the sheet to react to its own
        // track-name field.
        resizeToAvoidBottomInset: false,
        body: Stack(
          children: [
            _buildMap(),
            if (_isLoadingLocation) _buildLoadingOverlay(),
            _buildSheet(),
            _buildMapButtons(),
            // Covers the map/sheet/buttons above with a full-screen white
            // takeover while searching — the top bar (search field + arrow)
            // stays on top of it below, so it's still visible/interactive.
            if (_searchActive) _buildSearchOverlay(),
            SafeArea(child: _buildTopBar()),
          ],
        ),
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

        // ── Claimed areas (display only — no hitNotifier, so tapping one
        // still drops a route pin rather than opening its details) ────────
        ClaimedAreasLayer(areas: _visibleAreas),

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
                .map(
                  (s) => Polyline(
                    points: s.polyline,
                    color: const Color(0xFF4A8C52),
                    strokeWidth: 4.0,
                  ),
                )
                .toList(),
          ),

        // ── Straight-line preview while ORS call is in flight ─────────────
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

  // ── Search ────────────────────────────────────────────────────────────────
  //
  // Lives directly on this State (rather than a separate widget) because the
  // suggestions list is rendered by the full-screen takeover in
  // [_buildSearchOverlay] — a sibling of the top bar in the Stack, not a
  // descendant of the search field itself — so the field and the results
  // list both need direct access to the same query/focus/results state.

  void _onSearchFocusChanged() {
    if (!mounted) return;
    setState(() {
      if (!_searchFocusNode.hasFocus) _searchSuggestions = [];
    });
  }

  void _onSearchChanged() {
    if (_searchSuppressNext) {
      _searchSuppressNext = false;
      return;
    }
    _searchDebounce?.cancel();
    final text = _searchCtrl.text.trim();
    if (text.length < 3) {
      if (mounted) setState(() => _searchSuggestions = []);
      return;
    }
    _searchDebounce = Timer(
      const Duration(milliseconds: 350),
      () => _fetchSearchResults(text),
    );
  }

  /// Half-width/height (in degrees) of the "viewbox" sent to Nominatim around
  /// the user's position — roughly a 75km-wide box, generous enough to cover
  /// an entire metro area. Nominatim treats an unbounded viewbox (no
  /// `bounded=1`) as a *preference*, not a hard filter — a well-known match
  /// elsewhere can still outrank a low-importance local one, but an
  /// otherwise-ambiguous query like "Via Roma" gets nudged toward the user's
  /// own city, matching how Google Maps-style search biases by location
  /// without excluding everything else.
  static const double _viewboxDegrees = 0.35;

  Future<void> _fetchSearchResults(String query) async {
    final pos = _currentPosition;
    List<_Place> places = [];

    try {
      final viewbox = pos != null
          ? '&viewbox=${pos.longitude - _viewboxDegrees},'
                '${pos.latitude + _viewboxDegrees},'
                '${pos.longitude + _viewboxDegrees},'
                '${pos.latitude - _viewboxDegrees}'
          : '';
      // Over-fetch (15, not the ~10 we'll actually show) — Nominatim's own
      // ranking for an ambiguous query (e.g. plain "London", which also
      // matches London, Ontario and a handful of small US towns) can bury a
      // globally-famous place outside a small results window; the more raw
      // candidates we pull in, the better chance our own re-ranking (see
      // `_rankPlaces`) actually has the right one to promote.
      final uri = Uri.parse(
        'https://nominatim.openstreetmap.org/search'
        '?q=${Uri.encodeComponent(query)}&format=json&limit=15$viewbox',
      );
      final res = await http
          .get(uri, headers: {'User-Agent': 'DashApp/1.0'})
          .timeout(const Duration(seconds: 5));
      if (res.statusCode == 200) {
        final list = jsonDecode(res.body) as List<dynamic>;
        places = list.map((item) {
          final m = item as Map<String, dynamic>;
          return _Place(
            displayName: m['display_name'] as String,
            latLng: LatLng(
              double.parse(m['lat'] as String),
              double.parse(m['lon'] as String),
            ),
            importance: (m['importance'] as num?)?.toDouble() ?? 0.1,
          );
        }).toList();
      }
    } catch (_) {
      // Network error/timeout — fall through to the POI fallback below
      // rather than leaving the user with a blank result list.
    }

    // Show Nominatim's results the moment they arrive — measured directly
    // against the live API, a plain search like this typically resolves in
    // well under a second. Don't make the user stare at a blank list while
    // the much slower, much less reliable Overpass fallback below (measured
    // separately at ~10s before even timing out, on the public instance) is
    // still running — that fallback only ever *adds* to what's already
    // shown, never blocks it.
    if (mounted && _searchCtrl.text.trim() == query) {
      setState(() {
        _searchSuggestions = _rankPlaces(places, query, pos).take(10).toList();
      });
    }

    // Nominatim indexes street addresses well but often misses informally
    // named places (campus buildings, landmarks) that only carry a `name`
    // tag in OSM, not a postal address — e.g. "Edificio 25 Polimi". When the
    // address geocoder comes up thin, also try an Overpass name search
    // around the user's position and merge in anything new — but only as a
    // background enhancement to the list already on screen, never gating it.
    if (places.length < 3 && pos != null) {
      try {
        final poiPlaces = await _fetchPoiFallback(query, pos);
        final seen = places.map((p) => _roundedKey(p.latLng)).toSet();
        final newPlaces = [
          for (final p in poiPlaces)
            if (seen.add(_roundedKey(p.latLng))) p,
        ];
        if (newPlaces.isNotEmpty &&
            mounted &&
            _searchCtrl.text.trim() == query) {
          final merged = _rankPlaces([...places, ...newPlaces], query, pos);
          setState(() => _searchSuggestions = merged.take(10).toList());
        }
      } catch (_) {
        // Slow/unreachable/rate-limited — the Nominatim results shown above
        // already stand on their own.
      }
    }
  }

  String _roundedKey(LatLng p) =>
      '${p.latitude.toStringAsFixed(4)},${p.longitude.toStringAsFixed(4)}';

  /// Re-ranks Nominatim/Overpass results instead of trusting their raw
  /// order. Nominatim's own ranking weighs a *worse* text match (e.g. a
  /// truncated "londo" only fuzzy-matching "London") so heavily that a tiny,
  /// obscure place with an exact name match ("Londo" the village) can
  /// outrank a globally-famous city that's merely a prefix match — which is
  /// backwards for what a user typing an incomplete name actually wants.
  ///
  /// The fix: sort by three keys in strict priority order — match quality
  /// (does the primary place name start with/equal the query?), then a
  /// *coarse tier* of Nominatim's `importance` (population/notability), then
  /// proximity — each only a tiebreaker for the one before it. Importance is
  /// bucketed into tiers rather than compared as a raw 0–1 float so a real
  /// gap (a major world capital vs. a minor same-name town) always wins
  /// outright, while two similarly-significant places (both merely "a
  /// notable town", say) land in the same tier and fall through to
  /// proximity — otherwise a purely-numeric comparison would let *any*
  /// razor-thin importance difference override proximity too, which is just
  /// as wrong as the opposite (weighted-sum) failure mode: a Europe-based
  /// search for "London" outranking London, England with London, Ontario
  /// merely for scoring a hair higher/closer on one term or the other.
  List<_Place> _rankPlaces(List<_Place> places, String query, LatLng? pos) {
    final q = query.trim().toLowerCase();
    int matchTier(_Place p) {
      final name = p.displayName.toLowerCase();
      final primaryName = name.split(',').first.trim();
      if (primaryName == q) return 3;
      if (primaryName.startsWith(q)) return 2;
      if (name.contains(q)) return 1;
      return 0;
    }

    // 5 buckets (0–0.2, 0.2–0.4, … 0.8–1.0) — coarse enough that only a
    // real notability gap crosses a tier, not day-to-day noise in
    // Nominatim's own score.
    int importanceTier(_Place p) => (p.importance * 5).floor().clamp(0, 4);

    double proximityScore(_Place p) {
      if (pos == null) return 0;
      final distanceKm = const Distance().as(
        LengthUnit.Kilometer,
        pos,
        p.latLng,
      );
      return 1 / (1 + distanceKm / 200);
    }

    final sorted = List<_Place>.of(places)
      ..sort((a, b) {
        final tierCompare = matchTier(b).compareTo(matchTier(a));
        if (tierCompare != 0) return tierCompare;
        final importanceCompare = importanceTier(
          b,
        ).compareTo(importanceTier(a));
        if (importanceCompare != 0) return importanceCompare;
        return proximityScore(b).compareTo(proximityScore(a));
      });
    return sorted;
  }

  /// Searches OpenStreetMap-tagged places by name via the Overpass API
  /// (the same free, keyless data source [WaterFountainService] already
  /// uses) — a fallback for named POIs Nominatim's address search misses.
  /// Restricted to within [radiusMeters] of [pos] both to keep the query
  /// fast and because a "place near me" bias is exactly what's wanted here.
  ///
  /// The public Overpass instance is slow and often overloaded — measured
  /// directly, a query in this shape took ~10s before failing with a 504,
  /// and a repeat at a smaller radius still didn't return within 30s. A
  /// smaller radius and a short client timeout are damage control, not a
  /// fix for that — the actual fix is that the caller (`_fetchSearchResults`)
  /// treats this purely as a background enhancement to results already on
  /// screen, never something the user waits on.
  static Future<List<_Place>> _fetchPoiFallback(
    String query,
    LatLng pos,
  ) async {
    const radiusMeters = 20000;
    final escaped = _escapeForOverpassRegex(query);
    final ql =
        '[out:json][timeout:5];'
        '('
        'node["name"~"$escaped",i](around:$radiusMeters,${pos.latitude},${pos.longitude});'
        'way["name"~"$escaped",i](around:$radiusMeters,${pos.latitude},${pos.longitude});'
        ');'
        'out center 6;';

    final res = await http
        .post(
          Uri.parse('https://overpass-api.de/api/interpreter'),
          headers: {'User-Agent': 'DashApp/1.0'},
          body: {'data': ql},
        )
        .timeout(const Duration(seconds: 4));
    if (res.statusCode != 200) return [];

    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final elements = data['elements'] as List<dynamic>? ?? [];
    return elements
        .map((e) {
          final m = e as Map<String, dynamic>;
          final tags = m['tags'] as Map<String, dynamic>? ?? {};
          final name = tags['name'] as String?;
          if (name == null) return null;
          var lat = (m['lat'] as num?)?.toDouble();
          var lon = (m['lon'] as num?)?.toDouble();
          if (lat == null || lon == null) {
            final center = m['center'] as Map<String, dynamic>?;
            lat = (center?['lat'] as num?)?.toDouble();
            lon = (center?['lon'] as num?)?.toDouble();
          }
          if (lat == null || lon == null) return null;
          return _Place(displayName: name, latLng: LatLng(lat, lon));
        })
        .whereType<_Place>()
        .toList();
  }

  /// Escapes [input] for safe embedding inside an Overpass QL `~"...",i`
  /// regex literal (both regex metacharacters and the QL string's own
  /// double-quote delimiter) so a user-typed query can only ever match
  /// itself literally, never alter the query's structure.
  static String _escapeForOverpassRegex(String input) {
    const special = r'\.*+?^${}()|[]"';
    final buffer = StringBuffer();
    for (final ch in input.split('')) {
      if (special.contains(ch)) buffer.write('\\');
      buffer.write(ch);
    }
    return buffer.toString();
  }

  void _selectSearchResult(_Place place) {
    // Any pending debounced fetch (e.g. from text typed just before this tap
    // landed) is now for a stale query — don't let it resolve later and
    // repopulate the list right after we've moved on.
    _searchDebounce?.cancel();
    _searchSuppressNext = true;
    // Set text + selection together in one `.value` assignment rather than
    // as two separate `.text =` / `.selection =` assignments — each of
    // those fires the controller's listener independently, and
    // `_searchSuppressNext` only survives the first. The second, unsuppressed
    // firing used to schedule a real debounced fetch for the full place
    // name, which — since it's basically guaranteed to match itself in
    // Nominatim — would repopulate `_searchSuggestions` a moment later, even
    // after this method had already unfocused the field and moved on.
    _searchCtrl.value = TextEditingValue(
      text: place.displayName,
      selection: TextSelection.collapsed(offset: place.displayName.length),
    );
    setState(() => _searchSuggestions = []);
    _searchFocusNode.unfocus();
    _flyTo(place.latLng, _defaultZoom);
    // Also drop a pin at the selected place, same as tapping the map there
    // directly would — respects the same rules (delete mode, closed loop,
    // free-draw tool, snap-to-existing-waypoint) rather than a bypass.
    _onMapTap(place.latLng);
  }

  /// Backs out of the full-screen search takeover without leaving the page —
  /// used by the top-bar arrow and the system back gesture (see
  /// [_handleSystemPopInvoked]) whenever search is active, instead of their
  /// normal "leave route creation" behaviour.
  void _closeSearch() {
    _searchFocusNode.unfocus();
    setState(() => _searchSuggestions = []);
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
              onTap: _searchActive ? _closeSearch : _handleBackPressed,
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
          const SizedBox(width: 10),
          Expanded(child: _buildSearchField()),
        ],
      ),
    );
  }

  Widget _buildSearchField() {
    return Container(
      height: 46,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(23),
        boxShadow: const [
          BoxShadow(color: Colors.black26, blurRadius: 6, offset: Offset(0, 2)),
        ],
      ),
      alignment: Alignment.center,
      child: TextField(
        controller: _searchCtrl,
        focusNode: _searchFocusNode,
        textAlignVertical: TextAlignVertical.center,
        style: const TextStyle(fontSize: 14),
        decoration: InputDecoration(
          // isCollapsed drops InputDecorator's own implicit vertical padding,
          // which — combined with this fixed-height 46px container — was
          // what pushed the text off-centre.
          isCollapsed: true,
          hintText: 'Search a place…',
          hintStyle: const TextStyle(color: Colors.grey, fontSize: 14),
          prefixIcon: const Icon(Icons.search, color: Colors.grey, size: 20),
          prefixIconConstraints: const BoxConstraints(
            minWidth: 40,
            minHeight: 20,
          ),
          suffixIcon: _searchCtrl.text.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.close, size: 18, color: Colors.grey),
                  onPressed: () {
                    _searchCtrl.clear();
                    setState(() => _searchSuggestions = []);
                  },
                )
              : null,
          suffixIconConstraints: const BoxConstraints(
            minWidth: 40,
            minHeight: 20,
          ),
          border: InputBorder.none,
          contentPadding: EdgeInsets.zero,
        ),
      ),
    );
  }

  // ── Full-screen search overlay ───────────────────────────────────────────
  //
  // Replaces the small map-overlay dropdown from an earlier version: while
  // search is active, the whole page goes white (map, sheet, and map
  // buttons all covered) so there's a full screen of room for results
  // instead of a cramped ~200px strip.

  /// Matches the top bar's own on-screen height (12 top padding + 46 field
  /// height) so the results list starts right below the search field
  /// (rendered separately, on top of this overlay — see `build`) instead of
  /// underneath it.
  static const double _searchOverlayTopGap = 58.0;

  Widget _buildSearchOverlay() {
    return Positioned.fill(
      child: Container(
        color: Colors.white,
        child: SafeArea(
          child: Column(
            children: [
              const SizedBox(height: _searchOverlayTopGap),
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => FocusScope.of(context).unfocus(),
                  child: _searchSuggestions.isEmpty
                      ? _buildSearchEmptyState()
                      : ListView.separated(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          itemCount: _searchSuggestions.length,
                          separatorBuilder: (_, _) => const Divider(
                            height: 1,
                            indent: 20,
                            endIndent: 20,
                          ),
                          itemBuilder: (_, i) =>
                              _buildSearchResultTile(_searchSuggestions[i]),
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSearchEmptyState() {
    return const Center(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.search, size: 40, color: Color(0xFFB9C2B5)),
            SizedBox(height: 12),
            Text(
              'Search for a place, address, or landmark',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey, fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchResultTile(_Place place) {
    final parts = place.displayName.split(',');
    final primary = parts.first.trim();
    final secondary = parts.skip(1).join(',').trim();

    return InkWell(
      onTap: () => _selectSearchResult(place),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(top: 2),
              child: Icon(
                Icons.location_on_outlined,
                size: 18,
                color: Color(0xFF4A8C52),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    primary,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (secondary.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      secondary,
                      style: const TextStyle(fontSize: 12, color: Colors.grey),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Bottom sheet ──────────────────────────────────────────────────────────

  // `initialChildSize` == `maxChildSize` — the sheet opens fully showing
  // everything (toolbar, track name, Distance/Time/Calories stats, and the
  // Cancel/Create route buttons, in that fixed order — none of it is
  // conditionally hidden) and can't be dragged any further open, so there's
  // never dead/blank space to scroll through above it. Dragging it *down*
  // instead collapses it to `_sheetMinSize` — just the drag handle and the
  // Delete/Pin/Draw toolbar, everything else scrolled out of view below.
  static const double _sheetMinSize = 0.10;
  static const double _sheetMaxSize = 0.40;

  Widget _buildSheet() {
    // Reserving the keyboard's height as bottom padding pushes the sheet up
    // to sit above it, keeping the track-name field (near its top) fully
    // visible — but only while that field itself is focused. `resizeToAvoidBottomInset`
    // is off (see `build`) specifically so this doesn't ALSO trigger when the
    // unrelated top search bar is focused: there, the keyboard should simply
    // cover the sheet as normal, not push it up. Animated so it rides up/down
    // with the keyboard instead of jumping, and settles back to exactly
    // where it was once the field is unfocused (padding back to zero) — the
    // sheet's own size fraction is never touched by any of this.
    final keyboardInset = _trackNameFocused
        ? MediaQuery.of(context).viewInsets.bottom
        : 0.0;
    return AnimatedPadding(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      padding: EdgeInsets.only(bottom: keyboardInset),
      child: DraggableScrollableSheet(
        controller: _sheetController,
        initialChildSize: _sheetMaxSize,
        minChildSize: _sheetMinSize,
        maxChildSize: _sheetMaxSize,
        snap: true,
        snapSizes: const [_sheetMinSize, _sheetMaxSize],
        builder: (context, scrollController) => GestureDetector(
          // Dismiss the keyboard when tapping a blank part of the sheet
          // (drag handle, toolbar gaps, etc.) — the track name field, and
          // every button/tool here, has its own more specific tap handling
          // that wins over this one, so this only fires on genuinely empty
          // space.
          behavior: HitTestBehavior.opaque,
          onTap: () => FocusScope.of(context).unfocus(),
          child: Container(
            decoration: const BoxDecoration(
              color: Color(0xFFF3F5EE),
              borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
              boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 10)],
            ),
            // The whole sheet — drag handle, toolbar, and form — is a single
            // scrollable so dragging from anywhere (including the toolbar area)
            // resizes/scrolls the sheet, instead of only the area below it.
            child: ListView(
              controller: scrollController,
              padding: EdgeInsets.zero,
              children: [
                // Drag handle
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.grey[300],
                        borderRadius: BorderRadius.circular(2),
                      ),
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
                            ? () =>
                                  setState(() => _isDeleteMode = !_isDeleteMode)
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
                            color: Color(0xFF4A8C52),
                          ),
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
                // ── Form — track name, stats, buttons, always together; only
                // the *sheet's* height (collapsed to toolbar-only vs. fully
                // open) decides whether this whole block is on screen ────────
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
                  child: Column(
                    children: [
                      TextField(
                        controller: _trackNameCtrl,
                        focusNode: _trackNameFocusNode,
                        style: const TextStyle(fontSize: 15),
                        decoration: InputDecoration(
                          hintText: 'Track name',
                          hintStyle: const TextStyle(
                            color: Colors.grey,
                            fontSize: 15,
                          ),
                          prefixIcon: const Icon(
                            Icons.route_rounded,
                            size: 18,
                            color: Colors.grey,
                          ),
                          filled: true,
                          fillColor: Colors.white,
                          contentPadding: const EdgeInsets.symmetric(
                            vertical: 12,
                          ),
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
                                  color: Color(0xFFCFCFCF),
                                ),
                                padding: const EdgeInsets.symmetric(
                                  vertical: 13,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                              child: const Text(
                                'Cancel',
                                style: TextStyle(fontWeight: FontWeight.w600),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            flex: 2,
                            child: ElevatedButton.icon(
                              onPressed:
                                  (_waypoints.length >= 2 && !_isPublishing)
                                  ? _handleDonePressed
                                  : null,
                              icon: _isPublishing
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Color(0xFF2E7D32),
                                      ),
                                    )
                                  : const Icon(
                                      Icons.check_circle_outline_rounded,
                                      size: 18,
                                    ),
                              label: const Text('Create route'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFFCAF0B8),
                                foregroundColor: const Color(0xFF2E7D32),
                                disabledBackgroundColor: const Color(
                                  0xFFE0E0E0,
                                ),
                                elevation: 0,
                                padding: const EdgeInsets.symmetric(
                                  vertical: 13,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                textStyle: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 14,
                                ),
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
    final calLabel = hasPins ? '${_estimatedCalories.round()} kcal' : '—';

    return Column(
      children: [
        Row(
          children: [
            _MiniStat(
              icon: Icons.straighten_rounded,
              label: 'Distance',
              value: distLabel,
            ),
            const SizedBox(width: 8),
            _MiniStat(
              icon: Icons.timer_outlined,
              label: 'Est. time',
              value: timeLabel,
            ),
            const SizedBox(width: 8),
            _MiniStat(
              icon: Icons.local_fire_department_outlined,
              label: 'Calories',
              value: calLabel,
            ),
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
            Text(
              'Getting your location…',
              style: TextStyle(color: Colors.white, fontSize: 16),
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
    if (areaM2 >= 1000000) {
      return '${(areaM2 / 1000000).toStringAsFixed(2)} km²';
    }
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
          color: const Color(0xFF4A8C52).withValues(alpha: 0.4),
        ),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.check_circle_outline_rounded,
            size: 18,
            color: Color(0xFF2E7D32),
          ),
          const SizedBox(width: 8),
          const Text(
            'Circuit closed!',
            style: TextStyle(
              color: Color(0xFF2E7D32),
              fontWeight: FontWeight.w600,
              fontSize: 13,
            ),
          ),
          const Spacer(),
          const Icon(
            Icons.crop_free_rounded,
            size: 16,
            color: Color(0xFF4A8C52),
          ),
          const SizedBox(width: 6),
          Text(
            'Area: $_areaLabel',
            style: const TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 13,
              color: Color(0xFF2E7D32),
            ),
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
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: disabled ? Colors.grey[400] : fg,
                  ),
                ),
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
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
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

  const _MiniStat({
    required this.icon,
    required this.label,
    required this.value,
  });

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
            Text(
              value,
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: const TextStyle(color: Colors.grey, fontSize: 10),
            ),
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
            boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4)],
          ),
        ),
      ],
    );
  }
}
