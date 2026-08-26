import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:dash/extensions/dash_snackbar.dart';
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
import '../services/route_repository.dart';
import '../services/routing_service.dart';
import '../utils/geometry_utils.dart';
import '../utils/unit_formatter.dart';
import '../widgets/units_scope.dart';
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

/// What the user chose in `_RouteDetailsSheet` — returned as the modal
/// bottom sheet's own pop result so the actual (async, page-level) handling
/// happens in `_RouteSearchPageState`, not the sheet itself. Mirrors route
/// creation's `_SaveAction`/`_showSaveOptionsDialog` pattern.
enum _RouteSheetAction { save, runNow }

// ── Page ───────────────────────────────────────────────────────────────────────

class RouteSearchPage extends StatefulWidget {
  const RouteSearchPage({super.key});

  @override
  State<RouteSearchPage> createState() => _RouteSearchPageState();
}

class _RouteSearchPageState extends State<RouteSearchPage> with TickerProviderStateMixin {
  // ── Map ───────────────────────────────────────────────────────────────────
  final MapController _mapController = MapController();
  LatLng? _currentPosition;
  bool _isLoadingLocation = true;
  bool _isCameraAnimating = false;
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

  // ── Route-generation tuning ──────────────────────────────────────────────

  // Candidate round-trip loops requested per auto-loop search — one ORS
  // call each, so the whole first pass costs `_loopSeedCount` calls
  // (versus the old geometric guesser's 6 bearings × 3 legs = 18).
  static const int _loopSeedCount = 4;

  // ORS `options.round_trip.points` — higher = rounder loop. Round is
  // exactly what this app wants: for a fixed perimeter, rounder means
  // more enclosed (claimable) area.
  static const int _loopRoundness = 5;

  // Typical road-network detour factor (road distance ÷ straight-line
  // distance) for city walking — hand-picked like the other tuning
  // constants here. `_paddedLegCandidates` divides the target by it
  // before solving for the detour offset, so the first probe lands near
  // the target instead of systematically overshooting by this factor.
  static const double _roadWindingFactor = 1.25;

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

  /// Synchronous proxy for "will `_resolveDestination()` return anything" —
  /// mirrors [_hasStopsEntered], used to gate advancing from the shape step
  /// to the parameters step. Only meaningful for a direct A→B search: a
  /// closed circuit has no destination field at all (it loops back to
  /// `_buildStartSection`'s own point), so callers must also check
  /// `_isClosedCircuit` themselves.
  bool get _hasDestinationEntered =>
      _useCurrentPositionAsDest ||
      _destLatLng != null ||
      _destCtrl.text.trim().isNotEmpty;

  // ── Constraint resolution ─────────────────────────────────────────────────

  ({bool isConflict, bool isEmpty, double? targetKm}) _deriveTarget() {
    // The distance and calorie fields are typed in whatever units the user
    // has chosen, but everything downstream of here — `_paceMinPerKm`,
    // `_calPerKm`, every generator's target, `_matchTolerance` — is metric.
    // Converting at this single boundary is what keeps the search logic
    // itself unit-agnostic.
    final units = Units.current;

    final double? fromTime = double.tryParse(_timeCtrl.text.trim()) != null
        ? double.parse(_timeCtrl.text.trim()) / _paceMinPerKm
        : null;
    final double? typedDist = double.tryParse(_distCtrl.text.trim());
    final double? fromDist =
        typedDist == null ? null : units.majorToMeters(typedDist) / 1000.0;
    final double? typedCal = double.tryParse(_calCtrl.text.trim());
    final double? fromCal = typedCal == null
        ? null
        : units.displayToKcal(typedCal) / _calPerKm;

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
      _sheetController.animateTo(_sheetDefaultSize,
          duration: const Duration(milliseconds: 350), curve: Curves.easeOut);
    }
  }

  // ── Search entry point ────────────────────────────────────────────────────

  Future<void> _search() async {
    FocusScope.of(context).unfocus();

    final start = await _resolveStart();
    
    if (!mounted) return;

    if (start == null) {
      context.showErrorSnackBar("Could not resolve starting point");
      return;
    }

    final target = _deriveTarget();
    if (target.isConflict) {
      context.showErrorSnackBar('Constraints conflict — remove one value and try again');
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
      if (!mounted) return;

      context.showWarningSnackBar("Set a distance/time/calorie target, or add stops to shape the loop");
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
        if (!mounted) return;
        context.showWarningSnackBar("Enter a valid number of laps (1 or more)");
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
        if (mounted){
          setState(() => _isSearching = false);
          context.showErrorSnackBar("Could not resolve destination. Try again later");
        } 

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
      if (_lastSearchRateLimited){
        context.showErrorSnackBar('The routing service is busy right now — wait a moment and try again.');
      } else if (_lastSearchOnlyDegenerateLoops) {
        context.showErrorSnackBar('Could not find a real loop enclosing an area at that '
                  'distance — try a different distance, add a stop, or '
                  'move the start point.');
      } else {
        context.showErrorSnackBar("No routes found matching your criteria.");
      }
    }
  }

  // ── Closed-circuit route generation ─────────────────────────────────────────
  //
  // `totalTargetM` is the *total* the user asked for across every lap; the
  // per-lap target the loop generators actually work with is that divided
  // by `laps` (1 when laps isn't set), and `_toFoundRoute`'s `laps`
  // multiplier scales the measured single-loop distance/time/calories back
  // up for display — so a match against the per-lap target is automatically
  // a match against the original total too. Null when no target was given
  // at all (stops-only loops — `_search` requires a target whenever stops
  // are empty, so the auto-generator below always has one).

  Future<List<_FoundRoute>> _generateClosedCircuitRoutes(LatLng start,
      List<LatLng> stops, double? totalTargetM, int laps) async {
    final perLapTargetM = totalTargetM == null ? null : totalTargetM / laps;
    // Stops shape the loop explicitly — route through them (and, when a
    // target was also given, stretch the loop's closing leg toward it; see
    // `_generateLoopThroughStops`) rather than ignoring them in favour of
    // the auto-generator below.
    if (stops.isNotEmpty) {
      return _generateLoopThroughStops(start, stops, perLapTargetM, laps);
    }
    return _generateAutoLoopRoutes(start, perLapTargetM!, laps);
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

  /// Average of a polyline's vertices — a cheap shape fingerprint for
  /// `_dedupeSimilarRoutes` (adequate at city scale; true polygon
  /// centroids aren't needed there).
  LatLng _polylineCentroid(List<LatLng> points) {
    var lat = 0.0, lng = 0.0;
    for (final p in points) {
      lat += p.latitude;
      lng += p.longitude;
    }
    return LatLng(lat / points.length, lng / points.length);
  }

  /// Drops candidates that are effectively the same route as one already
  /// kept — different round-trip seeds (or a padded detour and a natural
  /// alternative) can converge on identical geometry in a sparse road
  /// network, and showing the same shape twice in two colours reads as a
  /// bug. "Same" = lengths within 3% AND centroids within
  /// max(60 m, 2% of the length) — deliberately loose fingerprints, since
  /// near-identical routes offer the user nothing distinct anyway. Keeps
  /// input order, so callers sort by preference first.
  List<RouteSegment> _dedupeSimilarRoutes(List<RouteSegment> segments) {
    final kept = <RouteSegment>[];
    final centroids = <LatLng>[];
    const dist = Distance();
    for (final s in segments) {
      final c = _polylineCentroid(s.polyline);
      var isDup = false;
      for (var i = 0; i < kept.length; i++) {
        final lengthGap = (kept[i].distanceMeters - s.distanceMeters).abs() /
            math.max(kept[i].distanceMeters, s.distanceMeters);
        if (lengthGap > 0.03) continue;
        if (dist(centroids[i], c) <= math.max(60.0, s.distanceMeters * 0.02)) {
          isDup = true;
          break;
        }
      }
      if (!isDup) {
        kept.add(s);
        centroids.add(c);
      }
    }
    return kept;
  }

  /// A user-shaped loop (start → stops → back to start). With no target the
  /// stops fully determine the shape — the natural loop is returned as long
  /// as it's real ORS geometry enclosing an actual area. With a target, the
  /// user-pinned part (start → … → last stop) stays fixed and the *closing
  /// leg* back to start absorbs the difference: padded-detour variants of
  /// it (`_paddedLegCandidates`) are sized so the whole loop lands on the
  /// target. The natural loop is never dropped for missing the target — if
  /// no padded variant reaches it, the natural loop is still shown as the
  /// closest honest answer, per the standing rule that routes shaped by
  /// the user's own waypoints are never silently filtered away. A single
  /// stop needs special handling — see `_generateSingleStopLoop`.
  ///
  /// Worst-case ORS calls: stops.length + 1 for the natural loop, plus
  /// `_paddedLegCandidates`'s own bound (12) when a target asks for
  /// padding.
  Future<List<_FoundRoute>> _generateLoopThroughStops(LatLng start,
      List<LatLng> stops, double? perLapTargetM, int laps) async {
    if (stops.length == 1) {
      return _generateSingleStopLoop(start, stops.single, perLapTargetM, laps);
    }

    // The pinned part and the closing leg are routed separately, so a
    // target can re-route just the closing leg without re-spending the
    // through-stops calls. Same total hop count as the old single
    // start → … → start chain.
    final through = await _routeChain([start, ...stops]);
    if (!through.ok) {
      _lastSearchRateLimited = through.rateLimited;
      return [];
    }
    final closing = await _routeHop(stops.last, start);
    if (!closing.ok) {
      _lastSearchRateLimited = closing.rateLimited;
      return [];
    }
    final natural = _stitch(through.seg, closing.seg);

    final candidates = <RouteSegment>[natural];
    var paddingRateLimited = false;
    if (perLapTargetM != null) {
      final closingTargetM = perLapTargetM - through.seg.distanceMeters;
      // Padding only helps when the target genuinely asks for a longer
      // closing leg than the natural one — a shorter target can't be
      // honoured at all, the stops already force this much distance.
      if (closingTargetM > closing.seg.distanceMeters * (1 + _matchTolerance)) {
        final padded = await _paddedLegCandidates(
          stops.last,
          start,
          closingTargetM,
          naturalLegM: closing.seg.distanceMeters,
        );
        paddingRateLimited = padded.rateLimited;
        candidates.addAll(
            [for (final leg in padded.segments) _stitch(through.seg, leg)]);
      }
    }

    final real = candidates.where(_enclosesRealArea).toList();
    if (real.isEmpty) {
      _lastSearchOnlyDegenerateLoops = true;
      _lastSearchRateLimited = paddingRateLimited;
      return [];
    }

    List<RouteSegment> chosen;
    if (perLapTargetM != null) {
      final matched = real
          .where((s) => _withinMatchTolerance(s.distanceMeters, perLapTargetM))
          .toList()
        ..sort((a, b) => _toleranceMiss(a.distanceMeters, perLapTargetM)
            .compareTo(_toleranceMiss(b.distanceMeters, perLapTargetM)));
      // Nothing reached the target → the natural loop (or the best real
      // candidate, if the natural one is degenerate) is still the honest
      // best answer for the user's own stops — never an empty result.
      chosen = matched.isNotEmpty
          ? matched
          : (_enclosesRealArea(natural)
              ? [natural]
              : (real
                ..sort((a, b) => GeometryUtils.polygonAreaM2(b.polyline)
                    .compareTo(GeometryUtils.polygonAreaM2(a.polyline)))));
    } else {
      chosen = [natural];
    }

    final results = <_FoundRoute>[];
    for (final seg in _dedupeSimilarRoutes(chosen).take(3)) {
      results.add(_toFoundRoute(seg, results.length, laps: laps));
    }
    return results;
  }

  /// `start → stop → start` with a *single* stop is, by definition, an
  /// out-and-back unless the return leg is deliberately routed differently
  /// from the outbound one — ORS's plain shortest path each way will almost
  /// always retrace the same street, which is exactly the degenerate
  /// "ran up and down the road" shape `_enclosesRealArea` exists to catch.
  /// The outbound leg is routed normally; return-leg candidates come from
  /// ORS's alternative routes and — when a target asks for more distance
  /// than any natural return can offer — from padded detours sized so the
  /// whole loop lands on the target (`_paddedLegCandidates`). Preference
  /// order: real loops on target → real natural loops (best-effort, ranked
  /// by enclosed area — same "user-shaped routes are never dropped" rule
  /// as everywhere else) → nothing, with the degenerate/rate-limit flag
  /// set so `_search` can name the actual cause.
  ///
  /// Worst-case ORS calls: 2 (outbound + return alternatives) plus
  /// `_paddedLegCandidates`'s own bound (12) when a target asks for
  /// padding.
  Future<List<_FoundRoute>> _generateSingleStopLoop(
      LatLng start, LatLng stop, double? perLapTargetM, int laps) async {
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

    final candidates = <RouteSegment>[
      for (final ret in returnAlternatives) _stitch(outbound.seg, ret),
    ];

    var paddingRateLimited = false;
    if (perLapTargetM != null) {
      final returnTargetM = perLapTargetM - outbound.seg.distanceMeters;
      final naturalReturnM = returnAlternatives.isEmpty
          ? null
          : returnAlternatives.map((s) => s.distanceMeters).reduce(math.min);
      // Padding only helps when the target asks for a longer return leg
      // than any natural alternative provides — a target below
      // outbound + shortest return can't be honoured through this stop.
      if (returnTargetM > 0 &&
          (naturalReturnM == null ||
              returnTargetM > naturalReturnM * (1 + _matchTolerance))) {
        final padded = await _paddedLegCandidates(
          stop,
          start,
          returnTargetM,
          naturalLegM: naturalReturnM,
        );
        paddingRateLimited = padded.rateLimited;
        candidates.addAll(
            [for (final leg in padded.segments) _stitch(outbound.seg, leg)]);
      }
    }

    if (candidates.isEmpty) {
      _lastSearchRateLimited = paddingRateLimited;
      return [];
    }

    final real = candidates.where(_enclosesRealArea).toList();
    if (real.isEmpty) {
      _lastSearchOnlyDegenerateLoops = true;
      _lastSearchRateLimited = paddingRateLimited;
      return [];
    }

    List<RouteSegment> chosen;
    if (perLapTargetM != null) {
      final matched = real
          .where((s) => _withinMatchTolerance(s.distanceMeters, perLapTargetM))
          .toList()
        ..sort((a, b) => _toleranceMiss(a.distanceMeters, perLapTargetM)
            .compareTo(_toleranceMiss(b.distanceMeters, perLapTargetM)));
      chosen = matched.isNotEmpty
          ? matched
          : (real
            ..sort((a, b) => GeometryUtils.polygonAreaM2(b.polyline)
                .compareTo(GeometryUtils.polygonAreaM2(a.polyline))));
    } else {
      chosen = real
        ..sort((a, b) => GeometryUtils.polygonAreaM2(b.polyline)
            .compareTo(GeometryUtils.polygonAreaM2(a.polyline)));
    }

    final results = <_FoundRoute>[];
    for (final seg in _dedupeSimilarRoutes(chosen).take(3)) {
      results.add(_toFoundRoute(seg, results.length, laps: laps));
    }
    return results;
  }

  /// Closed-loop search with no stops: asks ORS's native round-trip
  /// generator (`RoutingService.fetchRoundTrip`) for `_loopSeedCount`
  /// candidate loops in parallel, each with a different seed — a different
  /// overall direction out of the start point. Unlike the old geometric
  /// guesser (offset two synthetic waypoints and hope the roads
  /// cooperate), the routing engine grows each loop out of the actual road
  /// network, so candidates can't strand across rivers/highways, land far
  /// closer to the requested length, and cost ONE ORS call each instead of
  /// three. ORS documents the requested `length` as a preferred value
  /// rather than a guarantee, so the closest misses get one corrective
  /// re-request each with the length rescaled by the measured ratio (same
  /// seed → the loop grows/shrinks in place instead of jumping direction).
  /// Every candidate still has to clear `_enclosesRealArea` — a sparse
  /// network can force even a round trip into an out-and-back (a single
  /// dead-end valley road, say).
  ///
  /// Worst-case ORS calls: `_loopSeedCount` + 2 corrective re-requests
  /// = 6, versus the old guesser's 6 bearings × 3 legs + 2 × 3 = 24.
  /// If every round-trip call fails outright *without* being rate-limited
  /// — the one realistic case being an `orsRoute` deployment that predates
  /// the `round_trip` mode — `_generateLegacyLoopSegments` (the old
  /// guesser, slimmed) runs as a safety net so the feature degrades
  /// instead of dying during a functions/app version skew.
  Future<List<_FoundRoute>> _generateAutoLoopRoutes(
      LatLng start, double targetDistM, int laps) async {
    // Random base seed: repeating the same search explores different
    // loops instead of deterministically re-serving the same few.
    final baseSeed = math.Random().nextInt(1 << 16);

    Future<({RouteSegment? seg, bool rateLimited, int seed})> tryRoundTrip(
        int seed, double lengthM) async {
      try {
        final seg = await RoutingService.fetchRoundTrip(
          start,
          lengthMeters: lengthM,
          points: _loopRoundness,
          seed: seed,
          throwOnRateLimit: true,
        );
        return (seg: seg, rateLimited: false, seed: seed);
      } on RoutingRateLimitedException {
        return (seg: null, rateLimited: true, seed: seed);
      }
    }

    final firstPass = await Future.wait([
      for (var i = 0; i < _loopSeedCount; i++)
        tryRoundTrip(baseSeed + i, targetDistM),
    ]);

    var rateLimited = firstPass.any((c) => c.rateLimited);
    final usable = [
      for (final c in firstPass)
        if (c.seg != null) (seg: c.seg!, seed: c.seed),
    ];

    bool matchesDistance(RouteSegment seg) =>
        _withinMatchTolerance(seg.distanceMeters, targetDistM);

    final matched = <RouteSegment>[
      for (final c in usable)
        if (matchesDistance(c.seg) && _enclosesRealArea(c.seg)) c.seg,
    ];
    var sawDegenerateMatch =
        usable.any((c) => matchesDistance(c.seg) && !_enclosesRealArea(c.seg));

    // Correct the closest misses — a round trip's measured length responds
    // roughly linearly to the requested length for a fixed seed.
    if (!rateLimited) {
      final misses = [
        for (final c in usable)
          if (!matchesDistance(c.seg)) c,
      ]..sort((a, b) => _toleranceMiss(a.seg.distanceMeters, targetDistM)
          .compareTo(_toleranceMiss(b.seg.distanceMeters, targetDistM)));
      for (final miss in misses.take(2)) {
        if (matched.length >= 3) break;
        final ratio = miss.seg.distanceMeters / targetDistM;
        // Wildly-off candidates aren't worth another call — the network
        // doesn't support this direction at this size.
        if (ratio <= 0.55 || ratio >= 1.8) continue;
        final corrected = await tryRoundTrip(miss.seed, targetDistM / ratio);
        if (corrected.rateLimited) {
          rateLimited = true;
          break;
        }
        final seg = corrected.seg;
        if (seg == null || !matchesDistance(seg)) continue;
        if (_enclosesRealArea(seg)) {
          matched.add(seg);
        } else {
          sawDegenerateMatch = true;
        }
      }
    }

    var segments = _dedupeSimilarRoutes(matched
      ..sort((a, b) => _toleranceMiss(a.distanceMeters, targetDistM)
          .compareTo(_toleranceMiss(b.distanceMeters, targetDistM))));

    // Safety net: every round-trip call failed with an ordinary error (not
    // a 429). Most plausibly an `orsRoute` deployment without the
    // round_trip mode yet — fall back to the old geometric guesser so the
    // feature still works during the skew.
    var legacyDegenerate = false;
    if (segments.isEmpty && usable.isEmpty && !rateLimited) {
      final legacy = await _generateLegacyLoopSegments(start, targetDistM);
      rateLimited = legacy.rateLimited;
      legacyDegenerate = legacy.sawDegenerate;
      segments = legacy.segments;
    }

    _lastSearchRateLimited = rateLimited && segments.isEmpty;
    _lastSearchOnlyDegenerateLoops = segments.isEmpty &&
        (sawDegenerateMatch || legacyDegenerate) &&
        !_lastSearchRateLimited;

    final results = <_FoundRoute>[];
    for (final seg in segments.take(5)) {
      results.add(_toFoundRoute(seg, results.length, laps: laps));
    }
    return results;
  }

  /// The pre-round-trip geometric loop guesser, kept only as
  /// `_generateAutoLoopRoutes`'s safety net (see there): places two
  /// synthetic waypoints at radius = target × 0.25 from the start, 90°
  /// apart, per candidate bearing, routes start → wp1 → wp2 → start, and
  /// refines the single closest miss by rescaling the radius by the
  /// measured ratio. Slimmed to 3 bearings (120° apart) from the original
  /// 6 — as a fallback it only needs to produce *something*, and its calls
  /// stack on top of the round-trip attempts that already failed.
  /// Worst case 3 × 3 + 2 × 3 = 15 ORS calls.
  Future<({List<RouteSegment> segments, bool rateLimited, bool sawDegenerate})>
      _generateLegacyLoopSegments(LatLng start, double targetDistM) async {
    final radius = targetDistM * 0.25;
    const bearingCount = 3;

    final firstPass = await Future.wait(
      List.generate(bearingCount, (i) async {
        final theta = i * (360 / bearingCount);
        final wp1 = _offset(start, radius, theta);
        final wp2 = _offset(start, radius, theta + 90.0);
        final chain = await _routeChain([start, wp1, wp2, start]);
        return (theta: theta, chain: chain);
      }),
    );

    var rateLimited = firstPass.any((c) => c.chain.rateLimited);
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
    var sawDegenerate = usable.any(
        (c) => matchesDistance(c.chain.seg) && !_enclosesRealArea(c.chain.seg));

    if (segments.isEmpty && usable.isNotEmpty && !rateLimited) {
      final best = usable.first;
      var currentRadius = radius;
      var currentDist = best.chain.seg.distanceMeters;
      const maxRefinements = 2;
      for (var attempt = 0; attempt < maxRefinements; attempt++) {
        final ratio = currentDist / targetDistM;
        if (ratio <= 0.55 || ratio >= 1.8) break;
        currentRadius = currentRadius / ratio;
        final wp1 = _offset(start, currentRadius, best.theta);
        final wp2 = _offset(start, currentRadius, best.theta + 90.0);
        final refined = await _routeChain([start, wp1, wp2, start]);
        if (!refined.ok) {
          rateLimited = rateLimited || refined.rateLimited;
          break;
        }
        currentDist = refined.seg.distanceMeters;
        if (matchesDistance(refined.seg)) {
          if (_enclosesRealArea(refined.seg)) {
            segments.add(refined.seg);
          } else {
            sawDegenerate = true;
          }
          break;
        }
      }
    }

    return (
      segments: segments,
      rateLimited: rateLimited,
      sawDegenerate: sawDegenerate,
    );
  }

  /// Detour candidates from [from] to [to] whose measured road distance
  /// aims at [legTargetM] — the shared primitive behind every "make this
  /// leg longer" case: a direct A→B whose target exceeds the natural trip,
  /// and a loop's closing/return leg absorbing whatever its fixed part
  /// didn't cover. One synthetic via-point, offset perpendicular from the
  /// midpoint of the from–to line; both sides are probed in parallel (one
  /// may be blocked by water or rails the other isn't), and *each* side
  /// refines its own misses — the old padded generator only ever refined
  /// one side, so a blocked best side wasted the whole round while the
  /// other side's near-miss was thrown away.
  ///
  /// Two accuracy fixes over the old estimate. (1) The first offset guess
  /// divides the target by `_roadWindingFactor` before the Pythagoras
  /// solve: aiming the *straight-line* path at the target guaranteed the
  /// measured road result overshot by roughly the winding factor — always
  /// outside ±5%, always burning a refinement round. (2) Refinement uses
  /// an affine model when [naturalLegM] is known: road distance ≈ natural
  /// + (detour ∝ offset), so only the detour part gets rescaled, which
  /// converges in one round far more often than rescaling the whole
  /// distance did.
  ///
  /// Returns only candidates within `_matchTolerance` of [legTargetM] —
  /// never a straight line, never a quietly-short route. Worst-case ORS
  /// calls: 2 sides × 3 rounds × 2 hops = 12; typically 4–8.
  Future<({List<RouteSegment> segments, bool rateLimited})>
      _paddedLegCandidates(
    LatLng from,
    LatLng to,
    double legTargetM, {
    double? naturalLegM,
  }) async {
    final straightM = const Distance().as(LengthUnit.Meter, from, to);
    // No detour can make a leg shorter than its straight line — nothing to
    // search for unless the target actually requires lengthening it.
    if (legTargetM <= straightM * (1 + _matchTolerance)) {
      return (segments: const <RouteSegment>[], rateLimited: false);
    }

    final halfBase = straightM / 2;
    final chordTargetM =
        math.max(legTargetM / _roadWindingFactor, straightM * 1.05);
    final halfChord = chordTargetM / 2;
    final estOffset = math.sqrt(math.max(
      halfChord * halfChord - halfBase * halfBase,
      (straightM * 0.05) * (straightM * 0.05),
    ));

    final bearing = GeometryUtils.bearingDegrees(from, to);
    final mid = LatLng(
      (from.latitude + to.latitude) / 2,
      (from.longitude + to.longitude) / 2,
    );

    Future<({RouteSegment seg, bool ok, bool rateLimited})> tryOffset(
        double offset, double side) {
      final w = _offset(mid, offset, bearing + 90 * side);
      return _routeChain([from, w, to]);
    }

    double nextOffset(double offset, double measuredM) {
      double scale;
      if (naturalLegM != null && measuredM > naturalLegM) {
        // Affine model — see the doc comment.
        scale = (legTargetM - naturalLegM) / (measuredM - naturalLegM);
      } else {
        scale = legTargetM / measuredM;
      }
      return offset * scale.clamp(0.35, 3.0).toDouble();
    }

    final matched = <RouteSegment>[];
    var rateLimited = false;

    Future<void> probeSide(double side) async {
      var offset = estOffset;
      const maxRounds = 3; // first probe + up to 2 refinements
      for (var round = 0; round < maxRounds; round++) {
        if (rateLimited) return;
        final attempt = await tryOffset(offset, side);
        if (attempt.rateLimited) {
          rateLimited = true;
          return;
        }
        if (!attempt.ok) return;
        final measured = attempt.seg.distanceMeters;
        if (_withinMatchTolerance(measured, legTargetM)) {
          matched.add(attempt.seg);
          return;
        }
        final ratio = measured / legTargetM;
        // A side this far off is fighting an obstacle a linear correction
        // won't fix — stop spending calls on it.
        if (ratio <= 0.5 || ratio >= 2.0) return;
        offset = nextOffset(offset, measured);
      }
    }

    // Both sides in parallel, each refining its own misses.
    await Future.wait([probeSide(1), probeSide(-1)]);

    return (segments: matched, rateLimited: rateLimited);
  }

  // ── Direct (A → B) route generation ───────────────────────────────────────

  Future<List<_FoundRoute>> _generateDirectRoutes(
    LatLng start,
    List<LatLng> stops, // empty → no intermediate stops
    LatLng end,
    double? targetDistM, // null → no constraint
  ) async {
    // When stops are specified, route through them sequentially. The
    // user-pinned part (start → … → last stop) stays fixed; when a target
    // asks for more distance than the natural trip provides, the *final*
    // leg absorbs the difference through a padded detour — exactly like a
    // loop's closing leg. The natural route is never dropped for missing
    // the target (standing rule for user-shaped routes): padding failing
    // just means the natural trip is shown as-is.
    if (stops.isNotEmpty) {
      final through = await _routeChain([start, ...stops]);
      if (!through.ok) {
        _lastSearchRateLimited = through.rateLimited;
        return [];
      }
      final lastLeg = await _routeHop(stops.last, end);
      if (!lastLeg.ok) {
        _lastSearchRateLimited = lastLeg.rateLimited;
        return [];
      }
      final natural = _stitch(through.seg, lastLeg.seg);

      final candidates = <RouteSegment>[natural];
      if (targetDistM != null) {
        final legTargetM = targetDistM - through.seg.distanceMeters;
        if (legTargetM > lastLeg.seg.distanceMeters * (1 + _matchTolerance)) {
          final padded = await _paddedLegCandidates(
            stops.last,
            end,
            legTargetM,
            naturalLegM: lastLeg.seg.distanceMeters,
          );
          candidates.addAll(
              [for (final leg in padded.segments) _stitch(through.seg, leg)]);
        }
      }

      List<RouteSegment> chosen;
      if (targetDistM != null) {
        final onTarget = candidates
            .where((s) => _withinMatchTolerance(s.distanceMeters, targetDistM))
            .toList()
          ..sort((a, b) => _toleranceMiss(a.distanceMeters, targetDistM)
              .compareTo(_toleranceMiss(b.distanceMeters, targetDistM)));
        chosen = onTarget.isNotEmpty ? onTarget : [natural];
      } else {
        chosen = [natural];
      }

      final results = <_FoundRoute>[];
      for (final seg in _dedupeSimilarRoutes(chosen).take(3)) {
        results.add(_toFoundRoute(seg, results.length));
      }
      return results;
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
    // *lengthening* the trip, build a real detour that reaches it instead
    // of just accepting whatever's naturally there (the reported bug: a
    // request for "4 km" between two points 1.3 km apart just returned
    // that 1.3 km trip, silently ignoring the target entirely). The
    // shortest natural alternative feeds the padding's affine refinement
    // model — see `_paddedLegCandidates`.
    final naturalDistM =
        alternatives.map((s) => s.distanceMeters).reduce(math.min);
    final padded = await _generatePaddedDirectRoutes(start, end, targetDistM,
        naturalDistM: naturalDistM);
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

  /// Builds detours from [start] to [end] that actually reach a target
  /// *longer* than the trip's natural distance — no plain ORS alternative
  /// varies how far out of the way it goes, only which road it takes, so
  /// this is the only way to honour such a target. Thin wrapper over
  /// `_paddedLegCandidates` (shared with the loop generators' closing-leg
  /// padding); returns empty — never a straight line or a quietly-short
  /// route — if the road network genuinely won't support it.
  Future<List<_FoundRoute>> _generatePaddedDirectRoutes(
      LatLng start, LatLng end, double targetDistM,
      {double? naturalDistM}) async {
    final padded = await _paddedLegCandidates(
      start,
      end,
      targetDistM,
      naturalLegM: naturalDistM,
    );
    if (padded.segments.isEmpty) {
      if (padded.rateLimited) _lastSearchRateLimited = true;
      return [];
    }

    final ranked = _dedupeSimilarRoutes([...padded.segments]
      ..sort((a, b) => _toleranceMiss(a.distanceMeters, targetDistM)
          .compareTo(_toleranceMiss(b.distanceMeters, targetDistM))));

    final results = <_FoundRoute>[];
    for (final seg in ranked.take(3)) {
      results.add(_toFoundRoute(seg, results.length));
    }
    return results;
  }

  // ── Map helpers ───────────────────────────────────────────────────────────

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
      _sheetController.animateTo(_sheetDefaultSize,
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
      _sheetController.animateTo(_sheetDefaultSize,
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
  //
  // `initialChildSize` == `_sheetDefaultSize`, tuned to sit right at the
  // bottom of the step's own content (the Next/Search button) with no drag
  // needed and no dead space trailing below it — unlike `RouteCreatePage`'s
  // sheet, this page's content is too variable (two steps of very different
  // height, plus a variable number of stops) for `initialChildSize` to just
  // equal `maxChildSize` the way that page's fixed-height sheet does: that
  // was tried and left a large empty gap below the button on the shorter
  // step. `_sheetMaxSize` stays as a separate, taller drag ceiling — reached
  // by dragging up, not the default — for when a lot of stops are added and
  // the form genuinely needs more room. Dragging *down* instead collapses to
  // `_sheetMinSize` — just the handle/header, map fully visible below — used
  // for pin-picking and to preview results on the map.
  static const double _sheetMinSize = 0.12;
  static const double _sheetDefaultSize = 0.68;
  static const double _sheetMaxSize = 0.90;
  static const List<double> _sheetSnapSizes = [
    _sheetMinSize,
    _sheetDefaultSize,
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

  Future<void> _selectRoute(int index) async {
    setState(() => _selectedRouteIndex = index);
    final route = _foundRoutes[index];
    final action = await showModalBottomSheet<_RouteSheetAction>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => _RouteDetailsSheet(
        route: route,
        routeNumber: index + 1,
      ),
    );
    if (!mounted || action == null) return;

    switch (action) {
      case _RouteSheetAction.save:
        await _saveRoute(route);
      case _RouteSheetAction.runNow:
        // Mirrors route creation's "Save route and Run": pop this whole page
        // with the chosen route's polyline so the caller (HomeScreen) pushes
        // RunTrackingPage with it as a guide line — same navigation shape,
        // so finishing/discarding the run returns straight to the home
        // screen rather than back into these search results.
        Navigator.of(context).pop(route.polyline);
    }
  }

  /// Publishes [route] to the signed-in user's saved routes (the `routes`
  /// Firestore collection via `RouteRepository`, the same one route creation
  /// writes to) — already shown (view/delete only, no run action yet) by
  /// `TempProfilePage`'s "My Routes" list. A found route has no user-placed
  /// waypoints of its own (it's generated, not tapped out by hand), so —
  /// same convention `FavoriteRouteRepository` already uses for a
  /// favourited run's whole path — [waypoints] is just the polyline again
  /// rather than a separate, smaller point list.
  Future<void> _saveRoute(_FoundRoute route) async {
    final name = '${Units.current.distanceMajor(route.distanceKm * 1000, decimals: 1)} '
        '${_isClosedCircuit ? 'loop' : 'route'}';
    try {
      await RouteRepository.instance.publishRoute(
        name: name,
        waypoints: route.polyline,
        routePolyline: route.polyline,
        distanceMeters: route.distanceKm * 1000,
        estimatedTimeMin: route.estimatedTimeMin,
        estimatedCalories: route.estimatedCalories,
        isLoop: _isClosedCircuit,
        loopAreaM2:
            _isClosedCircuit ? GeometryUtils.polygonAreaM2(route.polyline) : 0,
      );

      if (mounted) context.showSuccessSnackBar("Route saved!");
    } catch (e) {
      if (mounted) context.showErrorSnackBar("Failed to save route");
    }
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

  /// The system/gesture back action, distinct from the always-exit on-screen
  /// arrow (`_buildBackButton`) — mirrors whichever on-screen affordance
  /// already does the equivalent step-back: results mode has no "step 0"
  /// of its own to fall back to, so it gets the same reset "Edit search"
  /// does; the parameters step (1) gets the same `_formStep = 0` its own
  /// "Back" button does; only the shape step (0), with nowhere further back
  /// to go within the page, actually exits it.
  void _handleSystemBack() {
    if (_isResultsMode) {
      _enterEditMode();
    } else if (_formStep == 1) {
      setState(() => _formStep = 0);
    } else {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _formStep == 0 && !_isResultsMode,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _handleSystemBack();
      },
      child: Scaffold(
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
      initialChildSize: _sheetDefaultSize,
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
      // Stops sit between start and destination — they're waypoints along
      // the way, so this reads more naturally than destination-then-stops.
      const SizedBox(height: 16),
      _buildIntermediateStopSection(),
      if (!_isClosedCircuit) ...[
        const SizedBox(height: 16),
        _buildDestinationSection(),
      ],
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
      // Advancing to the parameters step is gated on this (see
      // `_buildShapeStepFooter`) — flag it here too, same treatment as the
      // closed-circuit target's own "(required...)" note below.
      note: _hasDestinationEntered ? null : '(required)',
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
                  'above is the total across all laps (e.g. 6 '
                  '${Units.of(context).distanceUnitLabel} over 3 laps looks '
                  'for a ~2 ${Units.of(context).distanceUnitLabel} loop).',
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

  /// The two estimation constants, restated in the user's units.
  ///
  /// Always expressed *per distance* even when the user has chosen to see
  /// speeds elsewhere — these describe how the target is derived, and
  /// "70 kcal per km" has no speed-shaped equivalent to pair a "12 km/h"
  /// with.
  String _defaultsHint(UnitFormatter units) {
    // One major unit of the user's distance, in km — the factor both
    // per-km constants scale by.
    final perMajor = units.majorToMeters(1) / 1000.0;
    final pace = units.pace(_paceMinPerKm);
    final energy = units.kcalToDisplay(_calPerKm * perMajor).round();
    final d = units.distanceUnitLabel;
    return 'Defaults: $pace min/$d · $energy ${units.energyUnitLabel}/$d';
  }

  Widget _buildParametersSection() {
    final units = Units.of(context);
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
        Text(
          _defaultsHint(units),
          style: const TextStyle(fontSize: 11, color: Colors.grey),
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
                    unit: units.distanceUnitLabel,
                    enabled: !_isResultsMode)),
            const SizedBox(width: 8),
            Expanded(
                child: _ParamField(
                    controller: _calCtrl,
                    hint: 'Calories',
                    unit: units.energyUnitLabel,
                    enabled: !_isResultsMode)),
          ],
        ),
      ],
    );
  }

  /// Step 1 (shape) footer — advances to step 2. Full address/pin
  /// resolution is async, so the real checks (start resolvable, destination
  /// resolvable, etc.) still stay on the final Search button in step 2 —
  /// but a direct A→B search is meaningless with no destination at all, so
  /// that much is checked synchronously here via `_hasDestinationEntered`
  /// (a closed circuit has no destination field, so it's exempt).
  Widget _buildShapeStepFooter() {
    final canAdvance = _isClosedCircuit || _hasDestinationEntered;
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: (_isResultsMode || !canAdvance)
            ? null
            : () => setState(() => _formStep = 1),
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
  /// Small orange annotation next to [label] (e.g. "(required)") — same
  /// treatment as the closed-circuit target's own inline hint in
  /// `_buildParametersSection`. Null shows nothing.
  final String? note;
  const _FormSection({required this.label, required this.child, this.note});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(label,
                style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF5E655C))),
            if (note != null) ...[
              const SizedBox(width: 6),
              Text(note!,
                  style:
                      const TextStyle(fontSize: 11, color: Color(0xFFE65100))),
            ],
          ],
        ),
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
    final units = Units.of(context);
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
              '${units.distanceMajor(route.distanceKm * 1000 / route.laps)}',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
          const SizedBox(height: 20),
          Row(
            children: [
              _StatCard(
                icon: Icons.straighten_rounded,
                label: 'Distance',
                value: units.distanceMajor(route.distanceKm * 1000),
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
                value: units.energy(route.estimatedCalories),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () =>
                      Navigator.pop(context, _RouteSheetAction.save),
                  icon: const Icon(Icons.bookmark_border_rounded),
                  label: const Text('Save route'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF2E7D32),
                    side: const BorderSide(color: Color(0xFFCAF0B8), width: 1.5),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                    textStyle: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 15),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () =>
                      Navigator.pop(context, _RouteSheetAction.runNow),
                  icon: const Icon(Icons.directions_run_rounded),
                  label: const Text('Run now'),
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
