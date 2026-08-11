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
import '../utils/geometry_utils.dart';
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

  /// > 1 for a "laps" result (see `_generateLapRoute`) — [polyline] is the
  /// single loop shape, while distance/time/calories already have this
  /// factored in, so display code must not multiply again.
  final int laps;

  const _FoundRoute({
    required this.polyline,
    required this.distanceKm,
    required this.estimatedTimeMin,
    required this.estimatedCalories,
    required this.color,
    this.laps = 1,
  });

  LatLng get midpoint => polyline[polyline.length ~/ 2];
}

/// Which field a map tap should fill while pin-picking mode is active (see
/// `_beginPinPicking`/`_handleMapTapForPinPicking`) — the Google Maps-style
/// alternative to typing an address for the starting point, destination, or
/// an intermediate stop.
enum _PinTarget { start, destination, stop }

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
  LatLng? _startLatLng; // pre-resolved from suggestion or a dropped map pin

  bool _useCurrentPositionAsDest = false;
  final TextEditingController _destCtrl = TextEditingController();
  LatLng? _destLatLng;

  final List<TextEditingController> _stopCtrls = [];
  final List<LatLng?> _stopLatLngs = [];

  final TextEditingController _timeCtrl = TextEditingController();
  final TextEditingController _distCtrl = TextEditingController();
  final TextEditingController _calCtrl = TextEditingController();

  // Laps only apply to closed circuits (see `_buildParametersStepChildren`)
  // — the target distance/time/calories field represents the *total*
  // across all laps; the loop-finder searches for target ÷ laps per lap and
  // `_toFoundRoute` multiplies the measured result back up for display.
  final TextEditingController _lapsCtrl = TextEditingController();

  // ── Map pin-drop (place a start/destination/stop pin by tapping the map,
  // instead of typing an address — see `_beginPinPicking`) ────────────────
  _PinTarget? _pickingTarget;
  int? _pickingStopIndex;

  // ── Form wizard ───────────────────────────────────────────────────────────
  // 0 = route shape (circuit toggle, start/destination/stops), 1 =
  // parameters (distance/time/calories, laps). Splitting into two steps
  // keeps parameters — meaningless until the shape is decided — out of the
  // way until the user is ready for them.
  int _formStep = 0;

  // ── Result / UI state ─────────────────────────────────────────────────────
  bool _isSearching = false;
  List<_FoundRoute> _foundRoutes = [];
  bool _hasSearched = false;

  // Set by a route-generation method when it had to give up because ORS was
  // actively rate-limiting requests (HTTP 429), as opposed to just finding
  // no match — lets `_search` show a distinct "try again shortly" message
  // instead of a generic "no routes found".
  bool _lastSearchRateLimited = false;

  // Set when every loop candidate that otherwise qualified (real ORS
  // geometry, right distance) turned out to be a degenerate "there and
  // back" sliver rather than an actual enclosed loop — see
  // `_enclosesRealArea`. Distinct from a plain "no match" so `_search` can
  // point at the actual cause instead of a generic message.
  bool _lastSearchOnlyDegenerateLoops = false;

  // true while routes are displayed on the map; form fields are read-only
  bool _isResultsMode = false;

  // index of the route the user last tapped (highlighted on map), -1 = none
  int _selectedRouteIndex = -1;

  // ── Constants ─────────────────────────────────────────────────────────────

  static const double _defaultZoom = 14.0;
  static const double _paceMinPerKm = 9.0;   // magic default
  static const double _calPerKm = 70.0;       // magic default

  // Cross-checking the user's own time/distance/calorie entries against each
  // other in `_deriveTarget` — all three are independently derived from the
  // magic per-km constants above, so they're never expected to agree
  // exactly. Kept loose so entering, say, a time and a distance that imply
  // slightly different paces isn't treated as a hard conflict.
  static const double _conflictTolerance = 0.30;

  // Filtering *generated* routes against the resolved target distance is a
  // separate, much tighter band — a "find me an 8 km route" search
  // returning an 8.7 km result (nearly 9% over) reads as broken, even
  // though the old shared 30% tolerance allowed it.
  static const double _matchTolerance = 0.05;

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
      _timeCtrl, _distCtrl, _calCtrl, _lapsCtrl,
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

  /// Turns a map-tapped [point] into a display string for the corresponding
  /// address field — best-effort only; the resolved [LatLng] itself (not
  /// this text) is what `_resolveStart`/`_resolveDestination`/`_resolveStops`
  /// actually use, so a failed/slow reverse-geocode never blocks placing
  /// the pin, only how it's labelled.
  Future<String?> _reverseGeocode(LatLng point) async {
    try {
      final uri = Uri.parse(
        'https://nominatim.openstreetmap.org/reverse'
        '?lat=${point.latitude}&lon=${point.longitude}&format=json&zoom=18',
      );
      final res = await http
          .get(uri, headers: {'User-Agent': 'DashApp/1.0'})
          .timeout(const Duration(seconds: 6));
      if (res.statusCode != 200) return null;
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      return body['display_name'] as String?;
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

  /// Synchronous proxy for "will `_resolveStops()` return anything" — used
  /// only to steer form hints (e.g. whether a target is still required for
  /// a closed circuit), not for actual resolution.
  bool get _hasStopsEntered =>
      _stopLatLngs.any((ll) => ll != null) ||
      _stopCtrls.any((c) => c.text.trim().isNotEmpty);

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
      if (minV > 0 && (maxV - minV) / minV > _conflictTolerance) {
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
  //
  // A single ORS hop that never lets a failure pass as if it were a real
  // road-snapped result: `ok: false` means this hop fell back to a straight
  // line (network/parse failure, or ORS genuinely found no route), and every
  // route-generation method below must exclude any candidate built from one
  // rather than presenting a straight line cutting across buildings as a
  // "found route". `rateLimited: true` (HTTP 429) is called out separately
  // from an ordinary failure so callers can stop spending more of the
  // shared ORS quota immediately instead of continuing to probe into an
  // active rate-limit window — see `_routeChain`. A longer leg (a large
  // closed-circuit target means legs several km long) takes ORS noticeably
  // longer to compute, and was seen going empty-handed at 10 km where a
  // shorter search worked fine — one retry on an ordinary (non-429) failure
  // gives a transient timeout/network blip a second chance before this hop
  // gets excluded outright.
  Future<({RouteSegment seg, bool ok, bool rateLimited})> _routeHop(
      LatLng from, LatLng to) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final seg =
            await RoutingService.fetchRoute(from, to, throwOnRateLimit: true);
        if (seg != null) return (seg: seg, ok: true, rateLimited: false);
        // Ordinary (non-429) failure — try once more before giving up.
      } on RoutingRateLimitedException {
        return (seg: RoutingService.straightLine(from, to), ok: false, rateLimited: true);
      }
    }
    return (seg: RoutingService.straightLine(from, to), ok: false, rateLimited: false);
  }

  /// Routes through [waypoints] sequentially, stitching each hop. Stops
  /// early (rather than burning the rest of the chain's calls) the moment a
  /// hop reports rate-limiting, since a 429 on one hop makes the next hop
  /// failing the same way likely. `ok` is true only if *every* hop was a
  /// real ORS result — see `_routeHop`.
  Future<({RouteSegment seg, bool ok, bool rateLimited})> _routeChain(
      List<LatLng> waypoints) async {
    assert(waypoints.length >= 2);
    RouteSegment? seg;
    var ok = true;
    var rateLimited = false;
    for (int i = 0; i < waypoints.length - 1; i++) {
      if (rateLimited) {
        ok = false;
        break;
      }
      final hop = await _routeHop(waypoints[i], waypoints[i + 1]);
      seg = seg == null ? hop.seg : _stitch(seg, hop.seg);
      if (!hop.ok) ok = false;
      if (hop.rateLimited) rateLimited = true;
    }
    return (seg: seg!, ok: ok, rateLimited: rateLimited);
  }

  RouteSegment _stitch(RouteSegment a, RouteSegment b) => RouteSegment(
        polyline: [...a.polyline, ...b.polyline.skip(1)],
        distanceMeters: a.distanceMeters + b.distanceMeters,
      );

  bool _withinMatchTolerance(double meters, double targetM) {
    final ratio = meters / targetM;
    return ratio >= 1 - _matchTolerance && ratio <= 1 + _matchTolerance;
  }

  double _toleranceMiss(double meters, double targetM) =>
      (meters / targetM - 1).abs();

  _FoundRoute _toFoundRoute(RouteSegment seg, int index, {int laps = 1}) {
    final km = (seg.distanceMeters / 1000) * laps;
    return _FoundRoute(
      polyline: seg.polyline,
      distanceKm: km,
      estimatedTimeMin: km * _paceMinPerKm,
      estimatedCalories: km * _calPerKm,
      color: _palette[index % _palette.length],
      laps: laps,
    );
  }

  // ── Results mode ──────────────────────────────────────────────────────────

  void _enterEditMode() {
    setState(() {
      _isResultsMode = false;
      _hasSearched = false;
      _foundRoutes = [];
      _selectedRouteIndex = -1;
      _formStep = 0;
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
    if (target.isConflict) {
      _snack('Constraints conflict — remove one value and try again');
      return;
    }

    // Resolved once, up front — both the closed-circuit and direct paths
    // need it, and closed circuit's own target requirement below depends on
    // whether stops were given.
    final stops = await _resolveStops();

    // A closed circuit needs *something* to size the loop by: either a
    // distance/time/calorie target (sizes the auto-generated loop) or
    // explicit stops (the loop's shape — and therefore its size — is
    // already fixed by them, so no target is needed at all in that case;
    // see `_generateClosedCircuitRoutes`).
    if (_isClosedCircuit && target.isEmpty && stops.isEmpty) {
      _snack('Set a distance/time/calorie target, or add stops to shape the loop');
      return;
    }

    // Laps only apply to closed circuits — optional; empty means 1 (no
    // repeat, unchanged from a plain closed-circuit search).
    var laps = 1;
    if (_isClosedCircuit && _lapsCtrl.text.trim().isNotEmpty) {
      // `_lapsCtrl` shares `_ParamField`'s decimal-capable keyboard with the
      // other parameter fields, so accept "3" or "3.0" alike.
      final lapsRaw = double.tryParse(_lapsCtrl.text.trim());
      final parsedLaps = lapsRaw?.round();
      if (parsedLaps == null || parsedLaps < 1) {
        _snack('Enter a valid number of laps (1 or more)');
        return;
      }
      laps = parsedLaps;
    }

    setState(() {
      _isSearching = true;
      _foundRoutes = [];
      _hasSearched = false;
      _selectedRouteIndex = -1;
    });
    _lastSearchRateLimited = false;
    _lastSearchOnlyDegenerateLoops = false;

    List<_FoundRoute> routes;

    if (_isClosedCircuit) {
      final totalTargetM = target.targetKm?.let((km) => km * 1000);
      routes =
          await _generateClosedCircuitRoutes(start, stops, totalTargetM, laps);
    } else {
      final end = await _resolveDestination();
      if (end == null) {
        if (mounted) setState(() => _isSearching = false);
        _snack('Could not resolve destination');
        return;
      }
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
    } else {
      _snack(_lastSearchRateLimited
          ? 'The routing service is busy right now — wait a moment and try again.'
          : _lastSearchOnlyDegenerateLoops
              ? 'Could not find a real loop enclosing an area at that '
                  'distance — try a different distance, add a stop, or '
                  'move the start point.'
              : 'No routes found matching your criteria.');
    }
  }

  // ── Closed-circuit route generation ─────────────────────────────────────────
  //
  // `totalTargetM` is the *total* the user asked for across every lap; the
  // per-lap target the auto-loop-finder actually searches for is that
  // divided by `laps` (1 when laps isn't set), and `_toFoundRoute`'s `laps`
  // multiplier scales the measured single-loop distance/time/calories back
  // up for display — so a match against the per-lap target is automatically
  // a match against the original total too. Null when stops were given
  // instead (see below) — a target isn't required in that case.

  Future<List<_FoundRoute>> _generateClosedCircuitRoutes(LatLng start,
      List<LatLng> stops, double? totalTargetM, int laps) async {
    // Stops shape the loop explicitly — route through them rather than
    // ignoring them in favour of the auto-guesser below (the reported bug:
    // placed stops were silently dropped for closed-circuit searches).
    if (stops.isNotEmpty) {
      return _generateLoopThroughStops(start, stops, laps);
    }
    // No stops: only the auto-guesser needs a target at all, to know how
    // big a loop to search for — `_search` already requires one whenever
    // stops are empty.
    return _generateAutoLoopRoutes(start, totalTargetM! / laps, laps);
  }

  /// Roughly how much of a loop's own "circle of the same perimeter" area
  /// it actually encloses. A real street loop typically covers a sizeable
  /// fraction of that; an out-and-back "there and back" path — the reported
  /// "ran up and down the road without enclosing an area" bug — covers
  /// close to none of it regardless of how far it travelled, since walking
  /// back over (close to) the same ground cancels out in the shoelace-style
  /// area calculation `GeometryUtils.polygonAreaM2` uses. 2% of the
  /// circular max is generous enough to accept a real but elongated loop
  /// (even a lopsided 10:1 rectangle clears it several times over) while
  /// still catching a genuine sliver.
  bool _enclosesRealArea(RouteSegment seg) {
    if (seg.polyline.length < 4 || seg.distanceMeters <= 0) return false;
    final area = GeometryUtils.polygonAreaM2(seg.polyline);
    final maxCircularArea =
        (seg.distanceMeters * seg.distanceMeters) / (4 * math.pi);
    return area >= maxCircularArea * 0.02;
  }

  /// A user-shaped loop (start → stops → back to start) — no distance
  /// filter (the shape, and so the distance, is already fixed by the stops
  /// the user placed; forcing it to also match an unrelated target just
  /// produced spurious "0 routes found" results), only a check that it's
  /// real ORS geometry and an actual enclosed loop, not a degenerate
  /// out-and-back. A single stop needs special handling — see
  /// `_generateSingleStopLoop`.
  Future<List<_FoundRoute>> _generateLoopThroughStops(
      LatLng start, List<LatLng> stops, int laps) async {
    if (stops.length == 1) {
      return _generateSingleStopLoop(start, stops.single, laps);
    }
    final chain = await _routeChain([start, ...stops, start]);
    if (!chain.ok) {
      _lastSearchRateLimited = chain.rateLimited;
      return [];
    }
    if (!_enclosesRealArea(chain.seg)) {
      _lastSearchOnlyDegenerateLoops = true;
      return [];
    }
    return [_toFoundRoute(chain.seg, 0, laps: laps)];
  }

  /// `start → stop → start` with a *single* stop is, by definition, an
  /// out-and-back unless the return leg is deliberately routed differently
  /// from the outbound one — ORS's plain shortest path each way will almost
  /// always retrace the same street, which is exactly the degenerate
  /// "ran up and down the road" shape `_enclosesRealArea` exists to catch.
  /// Two or more stops naturally avoid this (there are at least two real
  /// corners), so this is only needed for the one-stop case. Routes the
  /// outbound leg normally, then asks ORS for alternative *return* routes
  /// and pairs the outbound with whichever one encloses the most real area
  /// — if none of them do (a dead-end street, a single bridge, genuinely no
  /// parallel way back), there is no loop to find here, and that's reported
  /// rather than a fake one shown.
  Future<List<_FoundRoute>> _generateSingleStopLoop(
      LatLng start, LatLng stop, int laps) async {
    final outbound = await _routeHop(start, stop);
    if (!outbound.ok) {
      _lastSearchRateLimited = outbound.rateLimited;
      return [];
    }

    List<RouteSegment> returnAlternatives;
    try {
      returnAlternatives = await RoutingService.fetchAlternatives(
        stop,
        start,
        throwOnRateLimit: true,
        allowStraightLineFallback: false,
      );
    } on RoutingRateLimitedException {
      _lastSearchRateLimited = true;
      return [];
    }
    if (returnAlternatives.isEmpty) return [];

    RouteSegment? best;
    var bestArea = 0.0;
    for (final ret in returnAlternatives) {
      final combined = _stitch(outbound.seg, ret);
      final area = GeometryUtils.polygonAreaM2(combined.polyline);
      if (area > bestArea) {
        bestArea = area;
        best = combined;
      }
    }

    if (best == null || !_enclosesRealArea(best)) {
      _lastSearchOnlyDegenerateLoops = true;
      return [];
    }
    return [_toFoundRoute(best, 0, laps: laps)];
  }

  /// Places two intermediate waypoints at radius = D × 0.25 from start, 90°
  /// apart, and routes start → wp1 → wp2 → start. 6 candidate bearings
  /// (every 60°) are evaluated in parallel to produce geometrically distinct
  /// loops — down from an earlier version's 8 (every 45°) to bound ORS call
  /// volume; repeated searches hitting the shared quota's rate limit is what
  /// was producing straight-line "triangles cutting over buildings"
  /// (`_routeHop`'s fallback, now excluded from results entirely — see
  /// below). Every candidate is also checked with `_enclosesRealArea`, not
  /// just distance — a candidate can match the target distance exactly and
  /// still be a degenerate out-and-back if the two offset waypoints happen
  /// to road-snap onto the same street. Only the single closest miss gets
  /// refined (radius rescaled by the measured ratio, distance being roughly
  /// linear in radius for a fixed bearing) — but up to *two* corrective
  /// rounds, not one: a longer target means a larger radius, and the gap
  /// between the straight-line radius estimate and the real road-network
  /// detour ratio grows (and gets less predictable) the further out it
  /// reaches, so one correction that comfortably closed a short-range miss
  /// can undershoot at longer range. Worst case this method spends
  /// 6×3 + 2×3 = 30 ORS calls, versus the original version's
  /// unbounded-up-to 8×3×2 = 48.
  Future<List<_FoundRoute>> _generateAutoLoopRoutes(
      LatLng start, double targetDistM, int laps) async {
    final radius = targetDistM * 0.25;
    const bearingCount = 6;

    final firstPass = await Future.wait(
      List.generate(bearingCount, (i) async {
        final theta = i * (360 / bearingCount);
        final wp1 = _offset(start, radius, theta);
        final wp2 = _offset(start, radius, theta + 90.0);
        final chain = await _routeChain([start, wp1, wp2, start]);
        return (theta: theta, chain: chain);
      }),
    );

    final rateLimited = firstPass.any((c) => c.chain.rateLimited);

    // Only real, road-snapped candidates (every hop succeeded) are ever
    // eligible — a candidate that fell back to a straight line anywhere in
    // its chain is discarded, never shown as a "found route".
    final usable = firstPass.where((c) => c.chain.ok).toList()
      ..sort((a, b) => _toleranceMiss(a.chain.seg.distanceMeters, targetDistM)
          .compareTo(_toleranceMiss(b.chain.seg.distanceMeters, targetDistM)));

    bool matchesDistance(RouteSegment seg) =>
        _withinMatchTolerance(seg.distanceMeters, targetDistM);

    final segments = <RouteSegment>[
      for (final c in usable)
        if (matchesDistance(c.chain.seg) && _enclosesRealArea(c.chain.seg))
          c.chain.seg,
    ];

    // A distance-matching candidate that got dropped purely for being a
    // degenerate sliver, so `_search` can name the actual cause instead of
    // a generic "no match" if nothing else pans out either.
    var sawDegenerateMatch = usable.any(
        (c) => matchesDistance(c.chain.seg) && !_enclosesRealArea(c.chain.seg));

    if (segments.isEmpty && usable.isNotEmpty && !rateLimited) {
      final best = usable.first;
      var currentRadius = radius;
      var currentDist = best.chain.seg.distanceMeters;
      const maxRefinements = 2;
      for (var attempt = 0; attempt < maxRefinements; attempt++) {
        final ratio = currentDist / targetDistM;
        // Wildly-off candidates (ratio outside 0.55–1.8) aren't worth
        // another round trip — a linear correction won't fix a road
        // network that fundamentally doesn't support this shape at this
        // bearing.
        if (ratio <= 0.55 || ratio >= 1.8) break;
        currentRadius = currentRadius / ratio;
        final wp1 = _offset(start, currentRadius, best.theta);
        final wp2 = _offset(start, currentRadius, best.theta + 90.0);
        final refined = await _routeChain([start, wp1, wp2, start]);
        if (!refined.ok) break; // failure/rate-limit — no point retrying further
        currentDist = refined.seg.distanceMeters;
        if (matchesDistance(refined.seg)) {
          if (_enclosesRealArea(refined.seg)) {
            segments.add(refined.seg);
          } else {
            sawDegenerateMatch = true;
          }
          break;
        }
      }
    }

    _lastSearchRateLimited = rateLimited && segments.isEmpty;
    _lastSearchOnlyDegenerateLoops =
        segments.isEmpty && sawDegenerateMatch && !_lastSearchRateLimited;

    final results = <_FoundRoute>[];
    for (final seg in segments.take(5)) {
      results.add(_toFoundRoute(seg, results.length, laps: laps));
    }
    return results;
  }

  // ── Direct (A → B) route generation ───────────────────────────────────────

  Future<List<_FoundRoute>> _generateDirectRoutes(
    LatLng start,
    List<LatLng> stops, // empty → no intermediate stops
    LatLng end,
    double? targetDistM, // null → no constraint; only used to rank results
  ) async {
    // When stops are specified, route through them sequentially (single
    // result) — like the closed-circuit stops case above, this shape is
    // already fixed by the user's own waypoints, so it's shown regardless
    // of how it compares to the target distance rather than being silently
    // dropped for missing an arbitrary tolerance band.
    if (stops.isNotEmpty) {
      final chain = await _routeChain([start, ...stops, end]);
      if (!chain.ok) {
        _lastSearchRateLimited = chain.rateLimited;
        return [];
      }
      return [_toFoundRoute(chain.seg, 0)];
    }

    // No stops: use ORS alternative routes endpoint for up to 3 results.
    // `allowStraightLineFallback: false` means a failure returns an empty
    // list rather than a straight line masquerading as a real alternative.
    List<RouteSegment> alternatives;
    try {
      alternatives = await RoutingService.fetchAlternatives(
        start,
        end,
        throwOnRateLimit: true,
        allowStraightLineFallback: false,
      );
    } on RoutingRateLimitedException {
      _lastSearchRateLimited = true;
      return [];
    }
    if (alternatives.isEmpty) return [];

    if (targetDistM == null) {
      // No constraints — return all alternatives as-is.
      return alternatives.asMap().entries
          .map((e) => _toFoundRoute(e.value, e.key))
          .toList();
    }

    final naturalMatches = alternatives
        .where((s) => _withinMatchTolerance(s.distanceMeters, targetDistM))
        .toList();
    if (naturalMatches.isNotEmpty) {
      return naturalMatches
          .asMap()
          .entries
          .map((e) => _toFoundRoute(e.value, e.key))
          .toList();
    }

    // None of ORS's own alternatives land near the target — they're close
    // variants of the same trip, not something that can be grown or shrunk
    // to hit an arbitrary length. If the target actually requires
    // *lengthening* the trip, try to build a real detour that reaches it
    // instead of just accepting whatever's naturally there (the reported
    // bug: a request for "4 km" between two points 1.3 km apart just
    // returned that 1.3 km trip, silently ignoring the target entirely).
    final padded = await _generatePaddedDirectRoutes(start, end, targetDistM);
    if (padded.isNotEmpty) return padded;

    // Padding wasn't possible or didn't pan out (target shorter than the
    // natural trip, so no detour applies; or the road network doesn't
    // support one) — never show literally nothing when a real route
    // exists: rank the natural alternatives by closeness so the user still
    // sees an honestly-labelled route instead of an empty result.
    final ranked = [...alternatives]
      ..sort((a, b) => _toleranceMiss(a.distanceMeters, targetDistM)
          .compareTo(_toleranceMiss(b.distanceMeters, targetDistM)));
    return ranked.asMap().entries.map((e) => _toFoundRoute(e.value, e.key)).toList();
  }

  /// Builds a detour from [start] to [end] via one synthetic waypoint,
  /// bulging perpendicular to the direct line by just enough to reach
  /// [targetDistM] — the only way to actually honour a target *longer* than
  /// the trip's natural distance, since no plain ORS alternative varies how
  /// far out of the way it goes, only which road it takes. Mirrors
  /// `_generateAutoLoopRoutes`'s offset-and-refine approach, just for an
  /// open path instead of a loop back to the start: tries both sides of the
  /// direct line in parallel, refines whichever comes closer (up to twice)
  /// if neither hits tolerance outright, and returns empty — never a
  /// straight line or a route that quietly falls short — if the road
  /// network genuinely won't support it.
  Future<List<_FoundRoute>> _generatePaddedDirectRoutes(
      LatLng start, LatLng end, double targetDistM) async {
    final straightM = const Distance().as(LengthUnit.Meter, start, end);
    // No detour can make a trip *shorter* than straight-line — nothing to
    // search for unless the target actually requires lengthening it.
    if (targetDistM <= straightM * (1 + _matchTolerance)) return [];

    final halfBase = straightM / 2;
    final halfTargetSq = (targetDistM / 2) * (targetDistM / 2);
    final baseSq = halfBase * halfBase;
    if (halfTargetSq <= baseSq) return [];
    // Straight-line estimate of the perpendicular bulge that makes
    // dist(start,W) + dist(W,end) ≈ targetDistM, from Pythagoras on the
    // isosceles triangle start–W–end.
    final estOffset = math.sqrt(halfTargetSq - baseSq);

    final bearing = GeometryUtils.bearingDegrees(start, end);
    final mid = LatLng(
      (start.latitude + end.latitude) / 2,
      (start.longitude + end.longitude) / 2,
    );

    Future<({RouteSegment seg, bool ok, bool rateLimited, double side})>
        tryOffset(double offset, double side) async {
      final w = _offset(mid, offset, bearing + 90 * side);
      final chain = await _routeChain([start, w, end]);
      return (
        seg: chain.seg,
        ok: chain.ok,
        rateLimited: chain.rateLimited,
        side: side,
      );
    }

    // Both sides of the direct line in parallel — one may run into an
    // obstacle (water, a highway with no crossing) the other doesn't.
    final firstPass =
        await Future.wait([tryOffset(estOffset, 1), tryOffset(estOffset, -1)]);

    final rateLimited = firstPass.any((c) => c.rateLimited);
    final usable = firstPass.where((c) => c.ok).toList()
      ..sort((a, b) => _toleranceMiss(a.seg.distanceMeters, targetDistM)
          .compareTo(_toleranceMiss(b.seg.distanceMeters, targetDistM)));

    final segments = <RouteSegment>[
      for (final c in usable)
        if (_withinMatchTolerance(c.seg.distanceMeters, targetDistM)) c.seg,
    ];

    if (segments.isEmpty && usable.isNotEmpty && !rateLimited) {
      final best = usable.first;
      var currentOffset = estOffset;
      var currentDist = best.seg.distanceMeters;
      const maxRefinements = 2;
      for (var attempt = 0; attempt < maxRefinements; attempt++) {
        final ratio = currentDist / targetDistM;
        if (ratio <= 0.5 || ratio >= 2.0) break;
        currentOffset = currentOffset / ratio;
        final refined = await tryOffset(currentOffset, best.side);
        if (!refined.ok) break;
        currentDist = refined.seg.distanceMeters;
        if (_withinMatchTolerance(currentDist, targetDistM)) {
          segments.add(refined.seg);
          break;
        }
      }
    }

    if (segments.isEmpty && rateLimited) _lastSearchRateLimited = true;

    final results = <_FoundRoute>[];
    for (final seg in segments.take(3)) {
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

  // ── Map pin-drop (Google Maps-style "tap the map instead of typing an
  // address") ──────────────────────────────────────────────────────────────

  /// Enters pin-picking mode for [target] (an existing [stopIndex] for
  /// `_PinTarget.stop`) — the next map tap (see `_handleMapTapForPinPicking`)
  /// fills that field instead of clearing the route-highlight selection.
  /// Collapses the sheet so the map is actually visible/tappable.
  void _beginPinPicking(_PinTarget target, {int? stopIndex}) {
    FocusScope.of(context).unfocus();
    setState(() {
      _pickingTarget = target;
      _pickingStopIndex = stopIndex;
    });
    if (_sheetController.isAttached) {
      _sheetController.animateTo(_sheetMinSize,
          duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
    }
  }

  void _cancelPinPicking() {
    setState(() {
      _pickingTarget = null;
      _pickingStopIndex = null;
    });
    if (_sheetController.isAttached) {
      _sheetController.animateTo(_sheetMidSize,
          duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
    }
  }

  /// Fills whichever field `_beginPinPicking` targeted with [point],
  /// immediately (a placeholder "Pinned location (lat, lng)" string) and
  /// then again with a real address once `_reverseGeocode` resolves — only
  /// if the field's pin hasn't since changed again (`_startLatLng == point`
  /// etc.), so a stale reverse-geocode can't clobber a newer pick.
  Future<void> _handleMapTapForPinPicking(LatLng point) async {
    final target = _pickingTarget;
    final stopIndex = _pickingStopIndex;
    if (target == null) return;

    setState(() {
      _pickingTarget = null;
      _pickingStopIndex = null;
    });
    if (_sheetController.isAttached) {
      _sheetController.animateTo(_sheetMidSize,
          duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
    }

    final placeholder = 'Pinned location '
        '(${point.latitude.toStringAsFixed(5)}, ${point.longitude.toStringAsFixed(5)})';

    setState(() {
      switch (target) {
        case _PinTarget.start:
          _useCurrentPositionAsStart = false;
          _startLatLng = point;
          _startCtrl.text = placeholder;
        case _PinTarget.destination:
          _useCurrentPositionAsDest = false;
          _destLatLng = point;
          _destCtrl.text = placeholder;
        case _PinTarget.stop:
          if (stopIndex != null && stopIndex < _stopCtrls.length) {
            _stopLatLngs[stopIndex] = point;
            _stopCtrls[stopIndex].text = placeholder;
          }
      }
    });

    final address = await _reverseGeocode(point);
    if (!mounted || address == null) return;
    setState(() {
      switch (target) {
        case _PinTarget.start:
          if (_startLatLng == point) _startCtrl.text = address;
        case _PinTarget.destination:
          if (_destLatLng == point) _destCtrl.text = address;
        case _PinTarget.stop:
          if (stopIndex != null &&
              stopIndex < _stopLatLngs.length &&
              _stopLatLngs[stopIndex] == point) {
            _stopCtrls[stopIndex].text = address;
          }
      }
    });
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

  // ── Pin-picking banner ────────────────────────────────────────────────────

  Widget _buildPinPickingBanner() {
    final target = _pickingTarget;
    if (target == null) return const SizedBox.shrink();

    final label = switch (target) {
      _PinTarget.start => 'Tap the map to set the starting point',
      _PinTarget.destination => 'Tap the map to set the destination',
      _PinTarget.stop => 'Tap the map to place this stop',
    };

    return Positioned(
      top: MediaQuery.of(context).padding.top + 12,
      left: 64,
      right: 64,
      child: Material(
        color: const Color(0xFF2A3028),
        borderRadius: BorderRadius.circular(30),
        elevation: 3,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.touch_app_outlined, size: 16, color: Colors.white),
              const SizedBox(width: 8),
              Flexible(
                child: Text(label,
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                    overflow: TextOverflow.ellipsis),
              ),
              const SizedBox(width: 10),
              GestureDetector(
                onTap: _cancelPinPicking,
                child: const Icon(Icons.close, size: 16, color: Colors.white70),
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
    return Scaffold(
      body: Stack(
        children: [
          _buildMap(),
          if (_isLoadingLocation) _buildLoadingOverlay(),
          _buildSheet(),
          _buildBackButton(),
          _buildMapButtons(),
          _buildPinPickingBanner(),
        ],
      ),
    );
  }

  // ── Map layer ─────────────────────────────────────────────────────────────

  /// Markers for whichever start/destination/stop points are currently
  /// pinned to a specific coordinate (via address suggestion or map-tap
  /// picking) — not shown for "current position", since that already has
  /// its own dedicated map indicator (the GPS dot).
  List<Marker> _planningMarkers() {
    final markers = <Marker>[];

    if (!_useCurrentPositionAsStart && _startLatLng != null) {
      markers.add(Marker(
        point: _startLatLng!,
        width: 34,
        height: 34,
        alignment: Alignment.topCenter,
        child: const Icon(Icons.location_on, size: 34, color: Color(0xFF2E7D32)),
      ));
    }

    if (!_isClosedCircuit &&
        !_useCurrentPositionAsDest &&
        _destLatLng != null) {
      markers.add(Marker(
        point: _destLatLng!,
        width: 30,
        height: 30,
        alignment: Alignment.topCenter,
        child: const Icon(Icons.sports_score, size: 28, color: Color(0xFFE65100)),
      ));
    }

    for (int i = 0; i < _stopLatLngs.length; i++) {
      final ll = _stopLatLngs[i];
      if (ll == null) continue;
      markers.add(Marker(
        point: ll,
        width: 26,
        height: 26,
        child: _StopMarkerBadge(number: i + 1),
      ));
    }

    return markers;
  }

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
          minZoom: MapStyle.minZoom,
          cameraConstraint: CameraConstraint.contain(bounds: MapStyle.safeCameraBounds),
          // Rotate is handled by the wrapping EnhancedMapGestures instead
          // (dead-zoned two-finger rotate + a little zoom inertia, shared
          // with every other map screen; see that widget). Fling stays
          // enabled — EnhancedMapGestures cancels it specifically when
          // triggered by a corrupted post-multi-touch velocity reading,
          // rather than blanket-disabling it; see its class doc, point 3.
          interactionOptions: const InteractionOptions(
            flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
          ),
          onTap: (tapPos, point) {
            if (_pickingTarget != null) {
              _handleMapTapForPinPicking(point);
              return;
            }
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

          // ── Manually-placed start/destination/stop pins (address search
          // or map-tap picking — see `_beginPinPicking`) ──────────────────
          if (_planningMarkers().isNotEmpty)
            MarkerLayer(markers: _planningMarkers()),

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
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
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
                                  tapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                ),
                              ),
                          ],
                        ),
                        // Step indicator — hidden once results are showing,
                        // since "Edit search" already communicates where
                        // things stand at that point.
                        if (!_isResultsMode) ...[
                          const SizedBox(height: 2),
                          Text(
                            _formStep == 0
                                ? 'Step 1 of 2 · Route shape'
                                : 'Step 2 of 2 · Parameters',
                            style: const TextStyle(
                                fontSize: 12, color: Color(0xFF8A9389)),
                          ),
                        ],
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
                children: _formStep == 0
                    ? _buildShapeStepChildren()
                    : _buildParametersStepChildren(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildShapeStepChildren() {
    return [
      _buildCircuitToggle(),
      const SizedBox(height: 16),
      _buildStartSection(),
      if (!_isClosedCircuit) ...[
        const SizedBox(height: 16),
        _buildDestinationSection(),
      ],
      const SizedBox(height: 16),
      _buildIntermediateStopSection(),
      const SizedBox(height: 24),
      _buildShapeStepFooter(),
    ];
  }

  List<Widget> _buildParametersStepChildren() {
    return [
      _buildParametersSection(),
      // Laps only apply to closed circuits — see the class-level note on
      // `_lapsCtrl` for why the target above is a total, not a per-lap size.
      if (_isClosedCircuit) ...[
        const SizedBox(height: 20),
        _buildLapsSection(),
      ],
      const SizedBox(height: 24),
      _buildParametersStepFooter(),
    ];
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
                Text(
                    'Loops back to start · add stops to shape it, '
                    'set laps in the next step',
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
              onPickOnMap: _isResultsMode
                  ? null
                  : () => _beginPinPicking(_PinTarget.start),
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
              onPickOnMap: _isResultsMode
                  ? null
                  : () => _beginPinPicking(_PinTarget.destination),
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
          if (_isClosedCircuit) ...[
            const Text(
              'Optional — routes through these before returning to start. '
              'Leave empty to auto-generate a loop matching your target instead.',
              style: TextStyle(fontSize: 11, color: Colors.grey),
            ),
            const SizedBox(height: 8),
          ],
          // One field per added stop
          for (int i = 0; i < _stopCtrls.length; i++) ...[
            if (i > 0) const SizedBox(height: 8),
            _AddressInputField(
              controller: _stopCtrls[i],
              hint: 'Stop ${i + 1}',
              enabled: !_isResultsMode,
              near: _currentPosition,
              onRemove: _isResultsMode ? null : () => _removeStop(i),
              onPickOnMap: _isResultsMode
                  ? null
                  : () => _beginPinPicking(_PinTarget.stop, stopIndex: i),
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

  Widget _buildLapsSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Laps',
          style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Color(0xFF5E655C)),
        ),
        const SizedBox(height: 2),
        Text(
          _hasStopsEntered
              ? 'Optional — repeat your stop-shaped loop this many times.'
              : 'Optional — repeat the loop this many times. The target '
                  'above is the total across all laps (e.g. 6 km over 3 '
                  'laps looks for a ~2 km loop).',
          style: const TextStyle(fontSize: 11, color: Colors.grey),
        ),
        const SizedBox(height: 10),
        SizedBox(
          width: 120,
          child: _ParamField(
            controller: _lapsCtrl,
            hint: 'e.g. 3',
            unit: 'laps',
            enabled: !_isResultsMode,
          ),
        ),
      ],
    );
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
            if (_isClosedCircuit && !_hasStopsEntered) ...[
              const SizedBox(width: 6),
              const Text(
                '(required — or add stops instead)',
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

  /// Step 1 (shape) footer — just advances to step 2, no validation here:
  /// address/pin resolution is async, so the real checks (start resolvable,
  /// destination resolvable, etc.) stay on the final Search button in step 2,
  /// same as before this page had steps at all.
  Widget _buildShapeStepFooter() {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: _isResultsMode ? null : () => setState(() => _formStep = 1),
        icon: const Icon(Icons.arrow_forward_rounded, size: 18),
        label: const Text('Next: parameters'),
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFFCAF0B8),
          foregroundColor: const Color(0xFF2E7D32),
          disabledBackgroundColor: const Color(0xFFE0E0E0),
          elevation: 0,
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          textStyle:
              const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
        ),
      ),
    );
  }

  Widget _buildParametersStepFooter() {
    final n = _foundRoutes.length;
    final label =
        _isClosedCircuit ? 'Total circuits found' : 'Total routes found';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            if (!_isResultsMode)
              TextButton.icon(
                onPressed: () => setState(() => _formStep = 0),
                icon: const Icon(Icons.arrow_back_rounded, size: 16),
                label: const Text('Back'),
                style: TextButton.styleFrom(
                  foregroundColor: const Color(0xFF5E655C),
                  padding: EdgeInsets.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
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
        ),
        const SizedBox(height: 12),
        ElevatedButton.icon(
          onPressed: (_isSearching || _isResultsMode) ? null : _search,
          icon: const Icon(Icons.search_rounded, size: 18),
          label: const Text('Show track'),
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFFCAF0B8),
            foregroundColor: const Color(0xFF2E7D32),
            disabledBackgroundColor: const Color(0xFFE0E0E0),
            elevation: 0,
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12)),
            textStyle: const TextStyle(
                fontWeight: FontWeight.w600, fontSize: 14),
          ),
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

  /// Enters map-tap pin-picking mode for this field (see
  /// `_beginPinPicking`) — the Google Maps-style alternative to typing an
  /// address. Independent of [onUseLocation]/[onRemove], so all three can
  /// be offered together.
  final VoidCallback? onPickOnMap;
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
    this.onPickOnMap,
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
    // A change while this field isn't focused can only be programmatic —
    // e.g. a pin dropped on the map (`_handleMapTapForPinPicking`) or a
    // reverse-geocoded address landing after the fact — never the user
    // editing text, so the LatLng that change just set must NOT be
    // invalidated (and no suggestion search should fire for it).
    if (!_focusNode.hasFocus) return;

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
            suffixIconConstraints:
                const BoxConstraints(minWidth: 0, minHeight: 0),
            suffixIcon: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.onPickOnMap != null)
                  IconButton(
                    icon: const Icon(Icons.push_pin_outlined,
                        size: 16, color: Color(0xFF4A8C52)),
                    onPressed: widget.onPickOnMap,
                    tooltip: 'Pick on map',
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints(minWidth: 32, minHeight: 32),
                  ),
                if (widget.onUseLocation != null)
                  IconButton(
                    icon: const Icon(Icons.my_location,
                        size: 16, color: Color(0xFF4A8C52)),
                    onPressed: widget.onUseLocation,
                    tooltip: 'Use current position',
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints(minWidth: 32, minHeight: 32),
                  )
                else if (widget.onRemove != null)
                  IconButton(
                    icon: const Icon(Icons.close,
                        size: 16, color: Colors.grey),
                    onPressed: widget.onRemove,
                    tooltip: 'Remove stop',
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints(minWidth: 32, minHeight: 32),
                  ),
                const SizedBox(width: 4),
              ],
            ),
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
              Text(
                route.laps > 1
                    ? 'Route $routeNumber · ×${route.laps} laps'
                    : 'Route $routeNumber',
                style: const TextStyle(
                    fontSize: 18, fontWeight: FontWeight.w700),
              ),
            ],
          ),
          if (route.laps > 1) ...[
            const SizedBox(height: 4),
            Text(
              'Each lap: '
              '${(route.distanceKm / route.laps).toStringAsFixed(2)} km',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
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

/// Small numbered marker for a manually-placed intermediate stop (address
/// suggestion or map-tap pin) — same rounded-circle shape as the found-route
/// number markers, in a distinct color so the two aren't confused.
class _StopMarkerBadge extends StatelessWidget {
  final int number;
  const _StopMarkerBadge({required this.number});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: const Color(0xFF1565C0),
        border: Border.all(color: Colors.white, width: 2),
        boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4)],
      ),
      alignment: Alignment.center,
      child: Text(
        '$number',
        style: const TextStyle(
            color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700),
      ),
    );
  }
}
