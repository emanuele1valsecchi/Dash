import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:dash/utils/dash_snackbar.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:permission_handler/permission_handler.dart';

import '../config/map_style.dart';
import '../models/water_fountain.dart';
import '../services/cached_tile_provider.dart';
import '../services/claimed_area_repository.dart';
import 'package:dash_watch_protocol/dash_watch_protocol.dart';

import '../services/location_service.dart';
import '../services/run_foreground_service.dart';
import '../services/run_session_controller.dart';
import '../services/wear_bridge.dart';
import '../services/water_fountain_service.dart';
import '../utils/geometry_utils.dart';
import '../utils/unit_formatter.dart';
import '../widgets/units_scope.dart';
import '../widgets/map/area_visibility_toggle.dart';
import '../widgets/map/claimed_areas_layer.dart';
import '../widgets/map/enhanced_map_gestures.dart';
import '../widgets/map/water_fountain_marker_layer.dart';
import '../widgets/run_results_dialog.dart';
import 'test_run_creator_page.dart';

// ── Run summary (returned to the caller on finish) ─────────────────────────

class RunSummary {
  final double distanceMeters;
  final Duration elapsed;
  final int loopsCompleted;
  final bool saved;

  const RunSummary({
    required this.distanceMeters,
    required this.elapsed,
    required this.loopsCompleted,
    required this.saved,
  });
}

// ── Page ─────────────────────────────────────────────────────────────────────

class RunTrackingPage extends StatefulWidget {
  const RunTrackingPage({super.key, this.plannedRoute});

  /// Optional route to display as a thin static guide line, when the user
  /// chose "Save route and Run" from route creation. Purely visual — this
  /// screen doesn't track on/off-route state or reroute if the user strays.
  final List<LatLng>? plannedRoute;

  @override
  State<RunTrackingPage> createState() => _RunTrackingPageState();
}

class _RunTrackingPageState extends State<RunTrackingPage> with TickerProviderStateMixin {
  // ── Map ───────────────────────────────────────────────────────────────────
  final MapController _mapController = MapController();
  static const double _defaultZoom = 18.0;
  bool _isMapExpanded = false;

  /// Separate controller for the small live map preview shown in
  /// [_buildStatsView] (see [_buildMapPreviewCard]) — a distinct [FlutterMap]
  /// from the expanded one, so it needs its own controller; recentered from
  /// [_onDotTick] whenever the expanded map isn't the one on screen.
  final MapController _previewMapController = MapController();
  static const double _previewZoom = 16.0;

  /// Whether the map is auto-recentering on the runner. The map is freely
  /// pannable/zoomable during a run (see [_buildMap]'s interactionOptions),
  /// so any user-driven pan/zoom/rotate ([_handleMapPositionChanged]'s
  /// `hasGesture`) turns this off — otherwise the next GPS fix would yank
  /// the camera straight back. The "my location" round button
  /// ([_centerOnUser]) turns it back on and animates back to the runner.
  bool _isFollowingUser = true;
  bool _isCameraAnimating = false;

  // ── Run session ───────────────────────────────────────────────────────────

  /// Everything about the run itself — clock, GPS stream, breadcrumb trail,
  /// distance/pace/altitude, loop detection, route guidance — lives here. This
  /// screen is the UI on top of it and owns none of that state.
  ///
  /// A singleton, so the session can outlive this screen (what background
  /// tracking and a smartwatch companion will need). Nothing relies on that
  /// yet: [dispose] still calls `reset()`, so leaving the screen ends the run
  /// exactly as it always has.
  final RunSessionController _controller = RunSessionController.instance;

  /// Length of the controller's breadcrumb trail as of the last notification,
  /// so [_onSessionChanged] can tell "a new fix landed" (advance the map trail)
  /// from any other state change. The controller notifies for many reasons.
  int _lastBreadcrumbLength = 0;

  // ── Water fountains (OpenStreetMap) ─────────────────────────────────────────
  // Fetched once at the runner's starting position — not refreshed as the
  // run progresses (even though the map is freely pannable, unlike the old
  // pan-disabled version of this screen), to avoid extra network/battery use
  // mid-workout — only the zoom-visibility half of the fountain UX applies.
  final WaterFountainService _waterFountainService = WaterFountainService.instance;
  List<WaterFountain> _waterFountains = [];
  // Starts true since _defaultZoom (18.0) is always well above
  // WaterFountainMarkerLayer.minZoomToShow; kept in sync by
  // _handleMapPositionChanged as the user pinch-zooms.
  bool _fountainsVisible = true;

  // ── Claimed areas (display only — no tap-to-view while running) ─────────
  // Fetched once when the screen opens — like fountains above, kept at
  // whatever the world looked like when the run started rather than
  // refreshed live, to save battery/network mid-workout.
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

  // ── Dot smoothing ─────────────────────────────────────────────────────────
  //
  // GPS fixes arrive in discrete jumps, which makes the marker teleport
  // instead of glide. This is a single exponential "chase": a perpetual
  // per-frame ticker nudges [_displayedPosition] a fraction of the remaining
  // gap toward [_controller.currentPosition] (the raw latest fix) every frame, scaled
  // by real elapsed time. Two things this is deliberately NOT, because both
  // were tried and both still visibly stalled:
  //
  //  1. A bounded Tween whose duration is guessed from the *previous*
  //     fix-to-fix gap and then played back after the fix arrives. Our
  //     position stream is triggered by a distance filter, not a fixed timer
  //     (unlike e.g. Google's FusedLocationProvider), so fixes never arrive
  //     on a predictable beat — any guessed duration can still finish before
  //     the next fix shows up, leaving the dot idle in between.
  //  2. A *fixed*-time-constant chase. This still has the same problem in
  //     disguise: with a short constant (what shipped originally, 0.35s) the
  //     chase converges and snaps to the target well within a typical
  //     0.5–1s fix interval, so it's sitting "settled" — not incrementally
  //     approaching anything — for whatever time is left until the next fix.
  //     That idle window is indistinguishable from a stall.
  //
  // The fix for both: the chase's time constant (computed fresh each tick in
  // [_onDotTick]) is *adaptive*, tracking the recently observed real gap
  // between fixes (any pace, any GPS cadence) via
  // [_controller.fixIntervalEstimateSeconds], with enough headroom that the chase
  // structurally cannot finish converging before the next fix retargets it.
  // It only actually reaches "settled" once fixes genuinely stop arriving —
  // i.e. the runner has actually stopped — which is exactly when the dot
  // should stop moving.
  LatLng? _displayedPosition;
  double? _displayedHeading;
  late final Ticker _dotTicker;
  Duration _dotTickerLastElapsed = Duration.zero;

  /// The chase's time constant is this multiple of the observed fix
  /// interval — comfortably longer than the gap it needs to survive, so a
  /// fix arriving right on schedule (or even a bit late) still finds the
  /// chase mid-glide rather than idle. Clamped so unusually fast bursts
  /// don't make it snappy/jittery, and unusually long GPS gaps (tunnels,
  /// poor signal) don't leave it crawling forever.
  static const double _dotChaseTauMultiplier = 1.5;
  static const double _dotChaseTauMin = 0.3;
  static const double _dotChaseTauMax = 2.5;

  /// How close the chase needs to get before snapping the rest of the way —
  /// otherwise it's asymptotic and technically never *exactly* arrives,
  /// which would mean pointless per-frame work forever once the runner
  /// actually stops.
  static const double _dotChaseSnapThresholdMeters = 0.25;

  // ── UI-only run bookkeeping ───────────────────────────────────────────────

  /// Drives the HH:MM:SS:DD display at 10 Hz, independent of GPS, so the clock
  /// stays smooth between location fixes. Purely a repaint pulse — the elapsed
  /// time itself comes from the controller's stopwatch.
  Timer? _uiTicker;

  /// Re-entrancy guard on [_finishRun]'s `Navigator.pop`. Stays here rather
  /// than moving to the controller: it guards a navigation call, not run state.
  bool _isFinishing = false;

  /// The watch's stop button, forwarded by [WearBridge]. Only this screen can
  /// action it, since finishing shows the save/discard summary.
  StreamSubscription<WatchCommand>? _watchCommands;

  void _onWatchCommand(WatchCommand command) {
    if (command != WatchCommand.finish) return;
    // Guard against a duplicate stop arriving mid-teardown, which would try to
    // show a second summary over the first.
    if (!mounted || _isFinishing) return;
    _confirmFinish(alreadyConfirmed: true);
  }

  /// The trail as painted on the map: every confirmed fix, plus a final
  /// "live" vertex that the dot-chase ([_onDotTick]) mutates in place each
  /// frame rather than rebuilding this whole list from [_controller.breadcrumb] every
  /// tick — for a long run with thousands of points, re-copying the entire
  /// trail 60 times a second for every glide would be needless GC pressure.
  /// flutter_map's polyline painter already repaints every frame regardless
  /// (it compares the outer `Polyline`/`List<Polyline>` wrapper objects,
  /// which are freshly built on every `build()` call anyway), so mutating
  /// this list's last element in place is safe — it doesn't skip a repaint
  /// that would otherwise happen. Since the chase is itself a low-pass
  /// filter on the raw fixes, this also smooths out the jagged look of
  /// connecting noisy raw GPS points with straight segments (most visible on
  /// turns/roundabouts) as a side effect, with no separate smoothing pass
  /// needed. [_controller.breadcrumb] stays the raw, unsmoothed source of truth for
  /// distance/pace/loop-closure — none of that math is affected by this.
  final List<LatLng> _trailPoints = [];

  /// [RunTrackingPage.plannedRoute] run through [GeometryUtils.smoothPolyline]
  /// once at startup — purely a rendering concern, so the raw
  /// `widget.plannedRoute` (same start/end points either way) is still what
  /// distance/proximity checks use.
  List<LatLng>? _smoothedPlannedRoute;

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    // The controller is a singleton, so a previous run's state could still be
    // sitting in it — clear before anything else touches it.
    _controller.reset();
    _controller.addListener(_onSessionChanged);

    // Finishing needs the save/discard summary, which only this screen can
    // show — so the bridge forwards the watch's stop button here rather than
    // acting on it itself. Pause/resume it handles directly.
    _watchCommands = WearBridge.instance.commands.listen(_onWatchCommand);

    _dotTicker = createTicker(_onDotTick)..start();
    final route = widget.plannedRoute;
    _smoothedPlannedRoute =
        (route != null && route.length >= 3) ? GeometryUtils.smoothPolyline(route) : route;
    _initLocation();
    _loadClaimedAreas();
  }

  /// Repaints on any controller change, and advances the map trail whenever
  /// that change was a newly-accepted GPS fix.
  void _onSessionChanged() {
    if (!mounted) return;

    // The countdown handing over to a live run is the controller's decision,
    // so the screen picks it up here rather than being told directly.
    if (_controller.hasStarted && _uiTicker == null) _startUiTicker();

    final length = _controller.breadcrumb.length;
    if (length > _lastBreadcrumbLength) {
      _lastBreadcrumbLength = length;
      final position = _controller.currentPosition;
      if (position != null) _advanceTrail(position);
    }
    setState(() {});
  }

  Future<void> _loadClaimedAreas() async {
    final areas = await ClaimedAreaRepository.instance.fetchAllAreas();
    if (!mounted) return;
    setState(() => _allAreas = areas);
  }

  @override
  void dispose() {
    _watchCommands?.cancel();
    _controller.removeListener(_onSessionChanged);
    // Leaving this screen still ends the run, exactly as it always has. The
    // controller being a singleton means it *could* keep recording instead —
    // removing this one call is what will enable minimize-and-keep-running
    // once there's a foreground service to keep GPS alive. Never call
    // `_controller.dispose()`: it is app-lifetime, not screen-lifetime.
    _controller.reset();

    _uiTicker?.cancel();
    _dotTicker.dispose();
    _mapController.dispose();
    _previewMapController.dispose();
    super.dispose();
  }

  // ── Location & tracking ──────────────────────────────────────────────────

  /// Routes permission through the app-wide [LocationService] rather than
  /// requesting it fresh — by the time a run starts, `HomeScreen` has
  /// usually already requested it and kept GPS warm, so this resolves
  /// immediately instead of prompting again. Deliberately still takes its
  /// own precise fix below (not [LocationService.current]) and gates
  /// [_startCountdown] on it: that fix becomes the run's first breadcrumb
  /// point (with altitude/timestamp `LocationService` doesn't expose), and
  /// starting the countdown before it lands would risk the run's own
  /// continuous stream ([_startPositionStream], via [_beginRun]) recording
  /// breadcrumbs before the authoritative starting point exists.
  Future<void> _initLocation() async {
    // Asked before the run starts, not when backgrounding: on Android 13+ a
    // foreground service cannot run without a visible notification, so a
    // refusal here silently costs background tracking. Prompting mid-run, with
    // the phone already in a pocket, would be worse than useless.
    await RunForegroundService.ensureNotificationPermission();
    if (!mounted) return;

    await _controller.prepare(plannedRoute: widget.plannedRoute);
    if (!mounted) return;
    if (_controller.permissionDenied) return;

    final start = _controller.currentPosition;
    if (start != null) {
      // Seed the map's own display state from the controller's first fix —
      // nothing to chase from yet, so show it directly.
      _lastBreadcrumbLength = _controller.breadcrumb.length;
      _trailPoints.add(start);
      setState(() => _displayedPosition = start);

      _waterFountainService.fetchNearby(start).then((fountains) {
        // null means the fetch failed (e.g. rate-limited) — leave whatever
        // was already showing rather than clearing it to empty.
        if (!mounted || fountains == null) return;
        setState(() => _waterFountains = fountains);
      });
    }

    if (!await _confirmStartProximity()) {
      if (mounted) Navigator.of(context).pop();
      return;
    }

    _controller.startCountdown();
  }

  /// If a [RunTrackingPage.plannedRoute] is set and the runner's current fix
  /// is far from its start, ask before proceeding rather than silently
  /// starting a run far from where it was planned. Returns true when it's
  /// fine to proceed (no planned route, already close enough, or the user
  /// chose to continue anyway).
  Future<bool> _confirmStartProximity() async {
    final route = widget.plannedRoute;
    final position = _controller.currentPosition;
    if (route == null || route.isEmpty || position == null) {
      return true;
    }
    const dist = Distance();
    final startDistance = dist(position, route.first);
    if (startDistance <= _maxStartDistanceMeters) return true;

    final proceed = await _showConfirmDialog(
      title: 'Far from route start',
      message: "You're about ${startDistance.round()}m from the start of "
          'this route. Continue anyway?',
      confirmLabel: 'Continue',
      destructive: false,
    );
    return proceed == true;
  }

  /// Beyond this distance from the route's start, draw [_startConnectorLine]
  /// so the runner can see which way to head — much smaller than
  /// [_maxStartDistanceMeters] (which only gates the one-time warning
  /// dialog), so the line stays a lightweight visual aid at everyday
  /// distances and only disappears once the runner has actually arrived.
  static const double _startConnectorMinDistanceMeters = 15.0;

  /// A thin dashed straight line from the runner to the planned route's
  /// start, shown whenever they're not already there. Deliberately just a
  /// straight "as the crow flies" line, not a routed path — no live
  /// rerouting/navigation is built for this, per the off-route decision (see
  /// RunTrackingPage.plannedRoute doc).
  Polyline? get _startConnectorLine {
    final route = widget.plannedRoute;
    final pos = _displayedPosition ?? _controller.currentPosition;
    if (route == null || route.isEmpty || pos == null) return null;
    final startDistance = const Distance()(pos, route.first);
    if (startDistance < _startConnectorMinDistanceMeters) return null;

    return Polyline(
      points: [pos, route.first],
      color: Colors.blue.withValues(alpha: 0.6),
      strokeWidth: 2.0,
      pattern: StrokePattern.dashed(segments: const [8, 6]),
    );
  }

  /// Wired to `MapOptions.onPositionChanged`. Keeps [_fountainsVisible] in
  /// sync with the zoom threshold as the user zooms; only `setState`s on an
  /// actual threshold crossing, not every zoom frame. Also drops
  /// [_isFollowingUser] the moment the user drags/pinches the map themselves
  /// (`hasGesture`) — every other camera move on this screen (the follow
  /// tick in [_onDotTick], [_animateCameraTo]) goes through [MapController]
  /// directly and reports `hasGesture: false`, so this only ever fires for a
  /// real touch. No re-fetch on pan (unlike explore/route create/search):
  /// fountains/areas are deliberately fetched once at run start to save
  /// battery/network mid-workout — see the fields above.
  void _handleMapPositionChanged(MapCamera camera, bool hasGesture) {
    final visible = camera.zoom >= WaterFountainMarkerLayer.minZoomToShow;
    if (visible != _fountainsVisible) {
      setState(() => _fountainsVisible = visible);
    }
    if (hasGesture && _isFollowingUser) {
      setState(() => _isFollowingUser = false);
    }
  }

  // ── Pre-run countdown ─────────────────────────────────────────────────────

  /// Dev-only shortcut for generating `runningSessions` docs without
  /// physically running, to test the area-claiming logic.
  Future<void> _openTestRunCreator() async {
    // Pause the countdown before leaving — timers keep firing even while
    // this route isn't on top, so without this a real run could silently
    // start while the user is away on the testing screen.
    if (!_controller.countdownPaused) _controller.pauseCountdown();

    final created = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const TestRunCreatorPage()),
    );

    // A test run was published in place of a real one — close this screen too.
    if (created == true && mounted) {
      Navigator.of(context).pop();
    }
  }

  /// Beyond this distance from a [RunTrackingPage.plannedRoute]'s start, warn
  /// the user before starting the run instead of silently proceeding.
  static const double _maxStartDistanceMeters = 150.0;

  /// Starts the 10 Hz repaint pulse that keeps the HH:MM:SS:DD display smooth
  /// between GPS fixes. Called once the countdown hands over to a live run.
  void _startUiTicker() {
    _uiTicker?.cancel();
    _uiTicker = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (mounted) setState(() {});
    });
  }

  /// Hands the chase ticker ([_onDotTick]) a new point to head toward.
  void _advanceTrail(LatLng newPoint) {
    if (_displayedPosition == null) {
      // Bootstrap: no prior position at all (the initial fetch in
      // _initLocation must have failed) — show this fix directly, there's
      // nothing to chase from yet.
      _displayedPosition = newPoint;
      _trailPoints.add(newPoint);
      return;
    }

    // The trail's current last vertex is already wherever the dot is
    // displayed (kept in sync every frame by `_onDotTick`), so leaving it in
    // place freezes it. Appending a duplicate opens a new live vertex for
    // the chase to update in place toward the new fix.
    _trailPoints.add(_displayedPosition!);
  }

  /// Runs every frame for the lifetime of the page (started in [initState]),
  /// nudging [_displayedPosition]/[_displayedHeading] toward [_controller.currentPosition]
  /// / [_controller.lastHeading]. See the "Dot smoothing" field comments for why this is
  /// a perpetual, adaptively-paced chase rather than a bounded per-fix
  /// animation or a fixed time constant.
  void _onDotTick(Duration elapsed) {
    if (!mounted) return;
    final dtMs = (elapsed - _dotTickerLastElapsed).inMilliseconds;
    _dotTickerLastElapsed = elapsed;
    if (dtMs <= 0) return;
    final dt = dtMs / 1000.0;

    final target = _controller.currentPosition;
    final current = _displayedPosition;
    if (target == null || current == null) return;

    final tau =
        (_controller.fixIntervalEstimateSeconds * _dotChaseTauMultiplier).clamp(_dotChaseTauMin, _dotChaseTauMax);
    final factor = 1 - math.exp(-dt / tau);

    var newDisplayed = LatLng(
      current.latitude + (target.latitude - current.latitude) * factor,
      current.longitude + (target.longitude - current.longitude) * factor,
    );

    // Snap once close enough — otherwise the chase asymptotically approaches
    // but never *exactly* reaches the target, which would mean pointless
    // per-frame work (and endless imperceptible drift) forever once the
    // runner stops moving.
    if (const Distance()(newDisplayed, target) < _dotChaseSnapThresholdMeters) {
      newDisplayed = target;
    }

    double? newHeading = _displayedHeading;
    final headingTarget = _controller.lastHeading;
    if (headingTarget != null) {
      newHeading =
          newHeading == null ? headingTarget : _lerpAngleDegrees(newHeading, headingTarget, factor);
    }

    final positionSettled =
        newDisplayed.latitude == current.latitude && newDisplayed.longitude == current.longitude;
    final headingSettled = newHeading == _displayedHeading;
    if (positionSettled && headingSettled) return; // nothing changed — skip the rebuild.

    if (_trailPoints.isNotEmpty) {
      _trailPoints[_trailPoints.length - 1] = newDisplayed;
    }

    setState(() {
      _displayedPosition = newDisplayed;
      _displayedHeading = newHeading;
    });

    if (_isMapExpanded && _isFollowingUser && !_isCameraAnimating) {
      try {
        _mapController.moveAndRotate(
          newDisplayed,
          _mapController.camera.zoom,
          _followRotationDegrees(newHeading),
        );
      } catch (_) {
        // Map not attached yet — next tick will re-attempt.
      }
    } else if (!_isMapExpanded) {
      try {
        _previewMapController.move(newDisplayed, _previewZoom);
      } catch (_) {
        // Preview map not mounted (e.g. during countdown) — next tick retries.
      }
    }
  }

  /// The map rotation to show while following the runner, given whichever
  /// course-over-ground [heading] the caller currently has on hand (the
  /// smoothed [_displayedHeading] for the continuous per-frame follow in
  /// [_onDotTick], the raw [_controller.lastHeading] for a one-off snap like
  /// [_toggleMapExpanded] or the "my location" button's [_centerOnUser]) —
  /// negated to flutter_map's rotation convention, same as this app's other
  /// heading-follow code. Null (not moving fast enough yet for a real course
  /// — see [_minSpeedForHeadingMs]) falls back to the direction of
  /// [RunTrackingPage.plannedRoute]'s very first leg, if one is set, so the
  /// map still points the way the runner needs to go before they've taken a
  /// single step; with neither, plain north-up (rotation 0). Shared by every
  /// rotation call site so a recenter's chosen rotation is never immediately
  /// undone by the next follow tick disagreeing on the fallback.
  double _followRotationDegrees(double? heading) {
    if (heading != null) return -heading;

    final route = widget.plannedRoute;
    if (route != null && route.length >= 2) {
      const dist = Distance();
      for (final p in route.skip(1)) {
        if (dist(route.first, p) > 1.0) {
          return -GeometryUtils.bearingDegrees(route.first, p);
        }
      }
    }
    return 0;
  }

  /// Interpolates from angle [a] to [b] (degrees) along whichever direction
  /// is shorter, so e.g. 350°→10° sweeps forward through 360° instead of
  /// spinning the long way back through 180°.
  double _lerpAngleDegrees(double a, double b, double t) {
    var diff = (b - a + 180) % 360 - 180;
    if (diff < -180) diff += 360;
    return a + diff * t;
  }

  // ── Camera animation ─────────────────────────────────────────────────────

  /// Animates the camera to [targetCenter]/[targetZoom] over a short tween
  /// instead of jumping instantly. flutter_map has no built-in animated
  /// move, so this drives one manually: an [AnimationController] ticks a
  /// lat/lng/zoom [Tween] (plus a rotation tween via [_lerpAngleDegrees],
  /// along whichever direction is shorter, when [targetRotationDegrees] is
  /// given) and calls [MapController.move]/[MapController.moveAndRotate]
  /// each frame, then disposes itself once the animation finishes.
  Future<void> _animateCameraTo(
    LatLng targetCenter,
    double targetZoom, {
    double? targetRotationDegrees,
  }) async {
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
    final startRotation = camera.rotation;

    final controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 650));
    final curved = CurvedAnimation(parent: controller, curve: Curves.easeInOutCubic);

    void tick() {
      try {
        final center = LatLng(latTween.transform(curved.value), lngTween.transform(curved.value));
        final zoom = zoomTween.transform(curved.value);
        if (targetRotationDegrees == null) {
          _mapController.move(center, zoom);
        } else {
          _mapController.moveAndRotate(
            center,
            zoom,
            _lerpAngleDegrees(startRotation, targetRotationDegrees, curved.value),
          );
        }
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

  /// The round map button's action: re-centers on the runner's live
  /// position (whatever the user panned/zoomed to in the meantime), rotates
  /// to face [_followRotationDegrees] (heading, planned-route direction, or
  /// north — see that method), and turns [_isFollowingUser] back on so
  /// [_onDotTick] resumes auto-following from there.
  Future<void> _centerOnUser() async {
    setState(() => _isFollowingUser = true);
    final target = _displayedPosition ?? _controller.currentPosition;
    if (target != null) {
      await _animateCameraTo(
        target,
        _defaultZoom,
        targetRotationDegrees: _followRotationDegrees(_controller.lastHeading),
      );
    }
  }

  // ── Controls ──────────────────────────────────────────────────────────────

  void _toggleMapExpanded() {
    setState(() {
      _isMapExpanded = !_isMapExpanded;
      _isFollowingUser = true; // always reopen the map in follow mode
    });
    final target = _displayedPosition ?? _controller.currentPosition;
    if (_isMapExpanded && target != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        try {
          _mapController.moveAndRotate(target, _defaultZoom, _followRotationDegrees(_controller.lastHeading));
        } catch (_) {}
      });
    }
  }

  Future<void> _confirmDiscard() async {
    if (!_controller.hasStarted) {
      Navigator.of(context).pop();
      return;
    }
    final confirmed = await _showConfirmDialog(
      title: 'Discard this run?',
      message: 'Your progress so far will be lost and no area will be claimed.',
      confirmLabel: 'Discard',
      destructive: true,
    );
    if (confirmed == true && mounted) Navigator.of(context).pop();
  }

  /// [alreadyConfirmed] skips the "barely moved" prompt. Set when the finish
  /// came from the watch's stop button, which already required a deliberate
  /// press-and-hold — asking again on the phone would be a second confirmation
  /// for one decision, on a device the runner may not even be looking at.
  Future<void> _confirmFinish({bool alreadyConfirmed = false}) async {
    if (!alreadyConfirmed && _controller.distanceMeters < 20) {
      final confirmed = await _showConfirmDialog(
        title: 'Finish already?',
        message: "You've barely moved — finish the run anyway?",
        confirmLabel: 'Finish',
        destructive: false,
      );
      if (confirmed != true) return;
    }
    _stopRunClock();
    if (!mounted) return;
    await _showRunSummarySheet();
  }

  void _stopRunClock() {
    _controller.stopClock();
    _uiTicker?.cancel();
  }

  void _finishRun({required bool saved}) {
    if (_isFinishing) return;
    _isFinishing = true;
    if (!mounted) return;
    Navigator.of(context).pop(
      RunSummary(
        distanceMeters: _controller.distanceMeters,
        elapsed: _controller.elapsed,
        loopsCompleted: _controller.loopsCompleted,
        saved: saved,
      ),
    );
  }

  // ── Finish summary: name the run, review stats, save or discard ─────────

  Future<void> _showRunSummarySheet() async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => _RunSummaryDialog(
        units: Units.of(dialogContext),
        time: _formatElapsed(),
        distance: _formatDistance(Units.of(dialogContext)),
        avgPace: _formatRateValue(
            Units.of(dialogContext), _controller.avgPaceMinPerKm),
        maxPace: _formatRateValue(
            Units.of(dialogContext), _controller.bestPaceMinPerKm),
        calories: Units.of(dialogContext).energy(_controller.caloriesBurned),
        elevation: Units.of(dialogContext)
            .elevation(_controller.elevationDifferenceMeters),
        avgHeartRate: _formatBpm(_controller.avgHeartRateBpm),
        maxHeartRate: _formatBpm(_controller.maxHeartRateBpm),
        onSave: (name) => _controller.save(name: name),
        onRequestDiscardConfirm: () => _showConfirmDialog(
          title: 'Discard this run?',
          message: 'This run will not be saved and no area will be claimed.',
          confirmLabel: 'Discard',
          destructive: true,
        ),
        onDiscarded: _handleSummaryDiscarded,
        onSaved: _handleSummarySaved,
      ),
    );
  }

  Future<void> _handleSummarySaved(String sessionId) async {
    Navigator.of(context).pop(); // close the summary dialog
    if (!mounted) return;
    await showRunResultsDialog(
      context: context,
      sessionId: sessionId,
      path: _controller.path,
      distanceMeters: _controller.distanceMeters,
      duration: _controller.elapsed,
      caloriesBurned: _controller.caloriesBurned,
      elevationDifferenceMeters: _controller.elevationDifferenceMeters,
    );
    if (!mounted) return;
    _finishRun(saved: true);
  }

  void _handleSummaryDiscarded() {
    Navigator.of(context).pop(); // close the summary dialog
    _finishRun(saved: false);
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
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      child: const Text('Cancel', style: TextStyle(fontWeight: FontWeight.w600)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () => Navigator.of(ctx).pop(true),
                      style: ElevatedButton.styleFrom(
                        backgroundColor:
                            destructive ? const Color(0xFFF4C7C3) : const Color(0xFFCAF0B8),
                        foregroundColor:
                            destructive ? const Color(0xFF8A3B34) : const Color(0xFF2E7D32),
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      child: Text(confirmLabel, style: const TextStyle(fontWeight: FontWeight.w600)),
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

  // ── Formatting ────────────────────────────────────────────────────────────

  String _formatElapsed() {
    final e = _controller.elapsed;
    String two(int v) => v.toString().padLeft(2, '0');
    final hh = two(e.inHours);
    final mm = two(e.inMinutes % 60);
    final ss = two(e.inSeconds % 60);
    final dd = two((e.inMilliseconds % 1000) ~/ 10);
    return '$hh:$mm:$ss:$dd';
  }

  /// Always the major unit (km/mi), never switching to metres for a short
  /// run — a live readout that changed unit mid-run would be jarring.
  String _formatDistance(UnitFormatter units) =>
      units.distanceMajor(_controller.distanceMeters);

  /// Null means no watch reported a reading — not a reading of zero, which is
  /// why this can't just print the number.
  String _formatBpm(int? bpm) => bpm == null ? '--' : '$bpm bpm';

  /// The bare rate figure — pace or speed, per the user's preference. The
  /// unit is rendered separately by each caller, in its own caption.
  String _formatRateValue(UnitFormatter units, double? paceMinPerKm) =>
      units.rateValueFromPace(paceMinPerKm);

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Once a run is actually in progress (`_controller.hasStarted` — set in
      // `_beginRun`, after the pre-run countdown), the system/gesture back
      // button must not silently exit — it should behave exactly like
      // tapping "Finish" (`_confirmFinish`), not like the X button's
      // `_confirmDiscard` (which abandons the run with no summary). Before
      // that (loading, permission-denied, countdown), there's nothing to
      // protect yet, so back pops normally — matching `_confirmDiscard`'s
      // own `!_controller.hasStarted` fast-path. `canPop: false` only blocks the
      // system back gesture/`maybePop`; every explicit `Navigator.pop()`
      // call elsewhere in this file (discard, finish, summary
      // save/discard) is unaffected and still pops immediately.
      canPop: !_controller.hasStarted,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _confirmFinish();
      },
      child: Scaffold(
        backgroundColor: const Color(0xFFF3F5EE),
        body: SafeArea(
          child: _controller.isLoadingLocation
              ? _buildLoadingView()
              : _controller.permissionDenied
                  ? _buildPermissionDeniedView()
                  : _controller.isCountingDown
                      ? _buildCountdownView()
                      : _isMapExpanded
                          ? _buildExpandedMapView()
                          : _buildStatsView(),
        ),
      ),
    );
  }

  Widget _buildLoadingView() {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(color: Color(0xFF4A8C52)),
          SizedBox(height: 14),
          Text(
            'Finding your position…',
            style: TextStyle(color: Color(0xFF5E655C), fontSize: 15),
          ),
        ],
      ),
    );
  }

  Widget _buildPermissionDeniedView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.location_off_rounded, size: 44, color: Color(0xFF9AA294)),
            const SizedBox(height: 14),
            const Text(
              'Dash needs location access to track your run.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 15, color: Color(0xFF5E655C)),
            ),
            const SizedBox(height: 18),
            ElevatedButton(
              onPressed: () async {
                final status = await Permission.locationWhenInUse.request();
                if (status.isPermanentlyDenied) {
                  await openAppSettings();
                  return;
                }
                if (status.isGranted) {
                  // reset() restores exactly the loading/not-denied state
                  // _initLocation expects to start from.
                  _controller.reset();
                  _lastBreadcrumbLength = 0;
                  _initLocation();
                }
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFCAF0B8),
                foregroundColor: const Color(0xFF2E7D32),
                elevation: 0,
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 13),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text('Enable location', style: TextStyle(fontWeight: FontWeight.w600)),
            ),
            const SizedBox(height: 10),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Back', style: TextStyle(color: Color(0xFF5E655C))),
            ),
          ],
        ),
      ),
    );
  }

  // ── Countdown view ───────────────────────────────────────────────────────

  Widget _buildCountdownView() {
    return Column(
      children: [
        _buildCloseBar(),
        Expanded(
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Get ready…',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: Color(0xFF5E655C)),
                ),
                const SizedBox(height: 8),
                Text(
                  '${_controller.countdownValue}',
                  style: const TextStyle(
                    fontSize: 132,
                    fontWeight: FontWeight.w800,
                    height: 1.0,
                    color: Color(0xFF4A8C52),
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(height: 32),
                SizedBox(
                  width: 200,
                  child: ElevatedButton(
                    onPressed: _controller.toggleCountdownPause,
                    style: ElevatedButton.styleFrom(
                      backgroundColor:
                          _controller.countdownPaused ? const Color(0xFFCAF0B8) : const Color(0xFFF4C7C3),
                      foregroundColor:
                          _controller.countdownPaused ? const Color(0xFF2E7D32) : const Color(0xFF8A3B34),
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    ),
                    child: Text(
                      _controller.countdownPaused ? 'RESUME' : 'STOP',
                      style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16, letterSpacing: 1.0),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                SizedBox(
                  width: 200,
                  child: OutlinedButton(
                    onPressed: _openTestRunCreator,
                    style: OutlinedButton.styleFrom(
                      backgroundColor: const Color(0xFFF6D651),
                      foregroundColor: const Color(0xFF4A3B00),
                      side: BorderSide.none,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    ),
                    child: const Text(
                      'TESTING RUN CREATOR',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12, letterSpacing: 0.6),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ── Stats (default) view ─────────────────────────────────────────────────

  Widget _buildStatsView() {
    final units = Units.of(context);
    return Column(
      children: [
        _buildCloseBar(),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
            child: Column(
              children: [
                const SizedBox(height: 12),
                _buildTimeDisplay(),
                if (_controller.guidance != null) ...[
                  const SizedBox(height: 18),
                  _RouteGuidanceCard(
                    guidance: _controller.guidance!,
                    // The smoothed heading the map dot uses, not the raw one —
                    // an arrow twitching on every noisy course reading is far
                    // more distracting than a dot doing the same.
                    heading: _displayedHeading,
                  ),
                ],
                const SizedBox(height: 22),
                Row(
                  children: [
                    Expanded(
                      child: _StatBlock(
                        icon: Icons.straighten_rounded,
                        label: 'Distance',
                        value: _formatDistance(units),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: _StatBlock(
                        icon: Icons.speed_rounded,
                        label: '${units.rateLabel} (${units.rateUnitLabel})',
                        value:
                            _formatRateValue(units, _controller.currentPaceMinPerKm),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                _LoopIndicator(loopsCompleted: _controller.loopsCompleted),
                const SizedBox(height: 18),
                _buildMapPreviewCard(),
              ],
            ),
          ),
        ),
        _buildControls(),
      ],
    );
  }

  Widget _buildCloseBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Row(
        children: [
          Material(
            color: Colors.white,
            shape: const CircleBorder(),
            elevation: 2,
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: _confirmDiscard,
              child: const Padding(
                padding: EdgeInsets.all(10),
                child: Icon(Icons.close, color: Color(0xFF425143), size: 22),
              ),
            ),
          ),
          const Spacer(),
          if (_controller.isPaused)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFFF4E3B2),
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Text(
                'Paused',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF7A5B12),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildTimeDisplay() {
    return Text(
      _formatElapsed(),
      style: const TextStyle(
        fontSize: 46,
        fontWeight: FontWeight.w800,
        color: Color(0xFF1F3020),
        fontFeatures: [FontFeature.tabularFigures()],
      ),
    );
  }

  Widget _buildControls({bool overMap = false}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _controller.togglePause,
              icon: Icon(_controller.isPaused ? Icons.play_arrow_rounded : Icons.pause_rounded, size: 20),
              label: Text(_controller.isPaused ? 'Resume' : 'Pause'),
              style: OutlinedButton.styleFrom(
                backgroundColor: overMap ? Colors.white : null,
                foregroundColor: const Color(0xFF425143),
                side: const BorderSide(color: Color(0xFFCFCFCF)),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: ElevatedButton.icon(
              onPressed: _confirmFinish,
              icon: const Icon(Icons.flag_rounded, size: 20),
              label: const Text('Finish'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFCAF0B8),
                foregroundColor: const Color(0xFF2E7D32),
                elevation: 0,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Expanded map view ─────────────────────────────────────────────────────

  Widget _buildExpandedMapView() {
    final units = Units.of(context);
    return Stack(
      children: [
        _buildMap(),
        Positioned(
          top: 8,
          left: 12,
          right: 12,
          child: _ExpandedStatsBar(
            time: _formatElapsed(),
            distance: _formatDistance(units),
            pace: _formatRateValue(units, _controller.currentPaceMinPerKm),
            rateUnitLabel: units.rateUnitLabel,
            loopsCompleted: _controller.loopsCompleted,
            onCollapse: _toggleMapExpanded,
          ),
        ),
        Positioned(
          right: 16,
          bottom: 108,
          child: _RoundMapButton(
            icon: Icons.my_location_rounded,
            tooltip: 'My location',
            onTap: (_displayedPosition ?? _controller.currentPosition) == null ? null : _centerOnUser,
          ),
        ),
        Positioned(
          right: 16,
          bottom: 164,
          child: AreaVisibilityToggle(
            showOtherAreas: _showOtherAreas,
            showMyAreas: _showMyAreas,
            onShowOtherAreasChanged: (v) => setState(() => _showOtherAreas = v),
            onShowMyAreasChanged: (v) => setState(() => _showMyAreas = v),
          ),
        ),
        Positioned(
          left: 24,
          right: 24,
          bottom: 16,
          child: _buildControls(overMap: true),
        ),
      ],
    );
  }

  /// Small live map card shown in [_buildStatsView] in place of a static
  /// "view map" button — a separate, non-interactive [FlutterMap] (its own
  /// [_previewMapController], recentered from [_onDotTick]) that mirrors the
  /// runner's live position and route so there's something to actually see
  /// before tapping through to [_buildExpandedMapView].
  Widget _buildMapPreviewCard() {
    final center = _displayedPosition ?? _controller.currentPosition;
    if (center == null) return const SizedBox.shrink();
    final connector = _startConnectorLine;

    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: SizedBox(
        height: 160,
        child: Stack(
          fit: StackFit.expand,
          children: [
            FlutterMap(
              mapController: _previewMapController,
              options: MapOptions(
                initialCenter: center,
                initialZoom: _previewZoom,
                minZoom: MapStyle.minZoom,
                interactionOptions: const InteractionOptions(flags: InteractiveFlag.none),
                // Tap detection is independent of the pan/zoom flags above,
                // so this fires even with interactions fully disabled —
                // matches the existing onTap pattern used for map taps
                // elsewhere (e.g. RouteCreatePage's pin-drop handler).
                onTap: (_, _) => _toggleMapExpanded(),
              ),
              children: [
                TileLayer(
                  urlTemplate: MapStyle.terrainTileUrl,
                  userAgentPackageName: 'com.dash',
                  retinaMode: RetinaMode.isHighDensity(context),
                  tileProvider: CachedTileProvider.instance,
                ),
                if (_smoothedPlannedRoute != null && _smoothedPlannedRoute!.length >= 2)
                  PolylineLayer(
                    polylines: [
                      Polyline(
                        points: _smoothedPlannedRoute!,
                        color: const Color(0xFF2E7D32).withValues(alpha: 0.55),
                        strokeWidth: 2.5,
                      ),
                    ],
                  ),
                if (connector != null) PolylineLayer(polylines: [connector]),
                if (_trailPoints.length >= 2)
                  PolylineLayer(
                    polylines: [
                      Polyline(points: _trailPoints, color: const Color(0xFF4A8C52), strokeWidth: 4.0),
                    ],
                  ),
                MarkerLayer(
                  markers: [
                    Marker(
                      point: center,
                      width: 36,
                      height: 36,
                      child: Transform.scale(scale: 0.6, child: const _RunnerLocationDot()),
                    ),
                  ],
                ),
              ],
            ),
            Positioned(
              right: 10,
              bottom: 10,
              child: IgnorePointer(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4)],
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.open_in_full_rounded, size: 14, color: Color(0xFF4A8C52)),
                      SizedBox(width: 6),
                      Text(
                        'Expand',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF425143)),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMap() {
    // Rotate isn't in the flags below (never was) and the wrapping
    // EnhancedMapGestures doesn't change that — it only adds a dead-zoned
    // two-finger rotate (plus a little zoom inertia) on top of whatever
    // flutter_map flags a screen already allows, shared with every other
    // map screen; see that widget. Pan is now allowed, same as every other
    // wrapped screen (`InteractiveFlag.all & ~InteractiveFlag.rotate`) — a
    // runner can freely look around mid-workout; [_handleMapPositionChanged]
    // drops [_isFollowingUser] the moment a real drag/pinch happens so the
    // next GPS fix doesn't immediately yank the camera back, and the "my
    // location" round button ([_centerOnUser]) snaps back to live tracking.
    return EnhancedMapGestures(
      mapController: _mapController,
      child: FlutterMap(
        mapController: _mapController,
        options: MapOptions(
          initialCenter:
              _displayedPosition ?? _controller.currentPosition ?? const LatLng(45.4642, 9.1900),
          initialZoom: _defaultZoom,
          minZoom: MapStyle.minZoom,
          cameraConstraint: CameraConstraint.contain(bounds: MapStyle.safeCameraBounds),
          interactionOptions: const InteractionOptions(
            flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
          ),
          onPositionChanged: _handleMapPositionChanged,
        ),
        children: [
          TileLayer(
            urlTemplate: MapStyle.terrainTileUrl,
            userAgentPackageName: 'com.dash',
            retinaMode: RetinaMode.isHighDensity(context),
            tileProvider: CachedTileProvider.instance,
          ),

          // ── Claimed areas (as of when this run started — not refreshed
          // live, to save battery/network mid-workout; display only, no
          // tap-to-view while running) ────────────────────────────────────
          ClaimedAreasLayer(areas: _visibleAreas),

          // ── Claimed loop fills (this run's own in-progress loops) ────────
          if (_controller.closedLoops.isNotEmpty)
            PolygonLayer(
              polygons: _controller.closedLoops
                  .map((poly) => Polygon(
                        points: poly,
                        color: const Color(0xFF4A8C52).withValues(alpha: 0.18),
                        borderColor: const Color(0xFF4A8C52).withValues(alpha: 0.6),
                        borderStrokeWidth: 2.2,
                      ))
                  .toList(),
            ),

          // ── Planned-route guide line (static — no on/off-route tracking or
          // rerouting, see RunTrackingPage.plannedRoute) ──────────────────
          if (_smoothedPlannedRoute != null && _smoothedPlannedRoute!.length >= 2)
            PolylineLayer(
              polylines: [
                Polyline(
                  points: _smoothedPlannedRoute!,
                  color: const Color(0xFF2E7D32).withValues(alpha: 0.55),
                  strokeWidth: 3.0,
                ),
              ],
            ),

          // ── Dashed connector from the runner to the route's start, while
          // they're still far enough from it to be useful ─────────────────
          if (_startConnectorLine case final connector?)
            PolylineLayer(polylines: [connector]),

          // ── Breadcrumb trail (paint left behind the runner) ──────────────
          if (_trailPoints.length >= 2)
            PolylineLayer(
              polylines: [
                Polyline(
                  points: _trailPoints,
                  color: const Color(0xFF4A8C52),
                  strokeWidth: 6.0,
                ),
              ],
            ),

          // ── Water fountains ────────────────────────────────────────────
          WaterFountainMarkerLayer(fountains: _waterFountains, visible: _fountainsVisible),

          // ── Runner position ────────────────────────────────────────────
          if ((_displayedPosition ?? _controller.currentPosition) != null)
            MarkerLayer(
              markers: [
                Marker(
                  point: _displayedPosition ?? _controller.currentPosition!,
                  width: 60,
                  height: 60,
                  child: const _RunnerLocationDot(),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

// ── Stat block ───────────────────────────────────────────────────────────────

class _StatBlock extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _StatBlock({required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFF0F2EB),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        children: [
          Icon(icon, size: 22, color: const Color(0xFF4A8C52)),
          const SizedBox(height: 8),
          Text(
            value,
            style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w800,
              color: Color(0xFF1F3020),
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: const TextStyle(fontSize: 12, color: Color(0xFF6B7266), fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }
}

// ── Route guidance (direction arrow) ─────────────────────────────────────────

/// Compass-style direction arrow, shown only while a planned route is active.
///
/// Rotates to [RouteGuidance.targetBearingDegrees] *relative to* [heading], so
/// it points where the runner should go from where they are actually facing —
/// the same read as a handheld compass, legible at a glance and needing no
/// street names (which the app doesn't have; see [GeometryUtils.routeGuidance]
/// for why this is a bearing guide rather than turn-by-turn navigation).
///
/// [heading] is null whenever the runner is stationary or slower than
/// `_minSpeedForHeadingMs`, since GPS course-over-ground is meaningless there.
/// A *relative* arrow would then be pointing confidently in a direction that
/// means nothing, so the card drops to a neutral "no bearing yet" state and
/// keeps showing distance remaining instead of guessing.
class _RouteGuidanceCard extends StatelessWidget {
  final RouteGuidance guidance;
  final double? heading;

  const _RouteGuidanceCard({required this.guidance, required this.heading});

  /// Close enough to the route's final point to call it done.
  static const double _arrivalRadiusMeters = 20.0;

  /// At or above this many degrees a change of direction reads as a junction
  /// ("Turn left"); below it, as a curve in the road ("Bear left"). Turns are
  /// only detected at all past `turnThresholdDegrees` (35°), so everything
  /// between the two is a genuine bend rather than polyline noise.
  static const double _sharpTurnDegrees = 70.0;

  /// Inside this distance the turn is announced as "now" rather than counted
  /// down — a runner covers the last few metres before it lands anyway.
  static const double _imminentTurnMeters = 15.0;

  @override
  Widget build(BuildContext context) {
    final offRoute = guidance.isOffRoute;
    final arrived =
        !offRoute && guidance.distanceRemainingMeters < _arrivalRadiusMeters;
    // Without a heading there is no way to say "turn left" — only "the route
    // continues north", which is worse than saying nothing.
    final canPoint = heading != null && !arrived;

    final (Color bg, Color fg) = switch ((offRoute, arrived)) {
      (true, _) => (const Color(0xFFF4E3B2), const Color(0xFF7A5B12)),
      (_, true) => (const Color(0xFFCAF0B8), const Color(0xFF2E7D32)),
      _ => (const Color(0xFFF0F2EB), const Color(0xFF4A8C52)),
    };

    final units = Units.of(context);

    final String title;
    final String subtitle;
    if (offRoute) {
      title = 'Off route';
      subtitle = '${units.shortDistance(guidance.offRouteMeters)} away '
          '— follow the arrow back';
    } else if (arrived) {
      title = 'Route complete';
      subtitle = 'You have reached the end of the planned route';
    } else if (canPoint) {
      title = _turnLabel(units);
      subtitle = _formatRemaining(units, guidance.distanceRemainingMeters);
    } else {
      title = 'Getting your bearing';
      subtitle =
          '${_formatRemaining(units, guidance.distanceRemainingMeters)} '
          '— start moving';
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.7),
              shape: BoxShape.circle,
            ),
            child: Center(child: _buildArrow(fg, canPoint, arrived)),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: fg,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: fg.withValues(alpha: 0.75),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildArrow(Color fg, bool canPoint, bool arrived) {
    if (arrived) {
      return Icon(Icons.flag_rounded, size: 26, color: fg);
    }
    if (!canPoint) {
      return Icon(Icons.explore_outlined, size: 26, color: fg);
    }
    // Plain Transform rather than AnimatedRotation: [heading] is already the
    // per-frame smoothed [_RunTrackingPageState._displayedHeading] (which
    // interpolates the short way around 360°), so animating again here would
    // only add lag — and AnimatedRotation would spin the long way round on
    // every wrap past north.
    final relative = (guidance.targetBearingDegrees - heading!) * math.pi / 180;
    return Transform.rotate(
      angle: relative,
      child: Icon(Icons.navigation_rounded, size: 28, color: fg),
    );
  }

  /// Headline text — the next change of direction if there is one within
  /// range, otherwise an explicit "carry on", which is more reassuring
  /// mid-run than a bare distance.
  String _turnLabel(UnitFormatter units) {
    final distance = guidance.distanceToTurnMeters;
    final angle = guidance.turnAngleDegrees;
    if (distance == null || angle == null) return 'Continue straight';

    final side = angle < 0 ? 'left' : 'right';
    final verb = angle.abs() >= _sharpTurnDegrees ? 'Turn' : 'Bear';
    if (distance < _imminentTurnMeters) return '$verb $side now';

    // Rounded to 10 of whatever unit is being shown: the underlying figure is
    // a threshold crossing on a sampled polyline, so "in 80 m" is honest
    // where "in 83 m" implies a precision this doesn't have. Rounding after
    // the conversion (rather than converting a rounded metric figure) keeps
    // the imperial reading a round number too.
    return '$verb $side in ${units.shortDistance(distance, roundTo: 10)}';
  }

  String _formatRemaining(UnitFormatter units, double meters) =>
      '${units.distance(meters)} to go';
}

// ── Loop indicator ─────────────────────────────────────────────────────────

class _LoopIndicator extends StatelessWidget {
  final int loopsCompleted;

  const _LoopIndicator({required this.loopsCompleted});

  @override
  Widget build(BuildContext context) {
    final isActive = loopsCompleted > 0;
    final bg = isActive ? const Color(0xFFCAF0B8) : const Color(0xFFECEFE6);
    final fg = isActive ? const Color(0xFF2E7D32) : const Color(0xFF9AA294);

    return TweenAnimationBuilder<double>(
      key: ValueKey(loopsCompleted),
      tween: Tween(begin: isActive ? 0.85 : 1.0, end: 1.0),
      duration: const Duration(milliseconds: 320),
      curve: Curves.elasticOut,
      builder: (context, scale, child) => Transform.scale(scale: scale, child: child),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              isActive ? Icons.crop_free_rounded : Icons.crop_free_outlined,
              size: 20,
              color: fg,
            ),
            const SizedBox(width: 10),
            Text(
              isActive ? 'Loop closed — area claimed × $loopsCompleted' : 'No loop closed yet',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: fg),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Expanded-map compact stats bar ───────────────────────────────────────────

class _ExpandedStatsBar extends StatelessWidget {
  final String time;
  final String distance;
  final String pace;

  /// Passed in rather than read here so the caption can never disagree with
  /// the already-formatted [pace] beside it — `'/mi'` under a figure computed
  /// in km/h would be worse than no caption at all.
  final String rateUnitLabel;

  final int loopsCompleted;
  final VoidCallback onCollapse;

  const _ExpandedStatsBar({
    required this.time,
    required this.distance,
    required this.pace,
    required this.rateUnitLabel,
    required this.loopsCompleted,
    required this.onCollapse,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      elevation: 4,
      shadowColor: Colors.black45,
      borderRadius: BorderRadius.circular(24),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: InkWell(
            onTap: onCollapse,
            child: Container(
              color: Colors.white.withValues(alpha: 0.92),
              padding: const EdgeInsets.fromLTRB(22, 18, 16, 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    time,
                    style: const TextStyle(
                      fontSize: 32,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF1F3020),
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Text(
                        '$distance  ·  $pace $rateUnitLabel',
                        style: const TextStyle(
                          fontSize: 16,
                          color: Color(0xFF425143),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (loopsCompleted > 0) ...[
                        const SizedBox(width: 10),
                        const Icon(Icons.crop_free_rounded, size: 17, color: Color(0xFF2E7D32)),
                        const SizedBox(width: 3),
                        Text(
                          '$loopsCompleted',
                          style: const TextStyle(
                              fontSize: 16, color: Color(0xFF2E7D32), fontWeight: FontWeight.w800),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Finish summary dialog ────────────────────────────────────────────────────

/// Owns its own [TextEditingController] and saving state so disposal happens
/// through the normal State lifecycle. Disposing a controller manually right
/// after `await showDialog(...)` returns is unsafe: that Future resolves the
/// instant `Navigator.pop()` is called, while the dialog's `TextField` is
/// still mounted and animating out — disposing the controller out from
/// under it trips a framework assertion.
class _RunSummaryDialog extends StatefulWidget {
  /// The formatter the caller already used for [distance]/[avgPace]/etc.,
  /// carried through so this dialog's own unit captions are guaranteed to
  /// describe those exact strings.
  final UnitFormatter units;

  final String time;
  final String distance;
  final String avgPace;
  final String maxPace;
  final String calories;
  final String elevation;

  /// "--" when no watch reported a reading, which is most runs. Shown rather
  /// than hidden so the row's absence never reads as a value of zero.
  final String avgHeartRate;
  final String maxHeartRate;

  final Future<String> Function(String name) onSave;
  final Future<bool?> Function() onRequestDiscardConfirm;
  final VoidCallback onDiscarded;
  final ValueChanged<String> onSaved;

  const _RunSummaryDialog({
    required this.units,
    required this.time,
    required this.distance,
    required this.avgPace,
    required this.maxPace,
    required this.calories,
    required this.elevation,
    required this.avgHeartRate,
    required this.maxHeartRate,
    required this.onSave,
    required this.onRequestDiscardConfirm,
    required this.onDiscarded,
    required this.onSaved,
  });

  @override
  State<_RunSummaryDialog> createState() => _RunSummaryDialogState();
}

class _RunSummaryDialogState extends State<_RunSummaryDialog> {
  late final TextEditingController _nameController;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController();
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _handleDiscard() async {
    final confirmed = await widget.onRequestDiscardConfirm();
    if (confirmed == true && mounted) {
      widget.onDiscarded();
    }
  }

  Future<void> _handleSave() async {
    setState(() => _isSaving = true);
    try {
      final sessionId = await widget.onSave(_nameController.text);
      widget.onSaved(sessionId);
    } catch (e) {
      if (!mounted) return;
      setState(() => _isSaving = false);
      context.showErrorSnackBar("Could not save run");
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Dialog(
        backgroundColor: const Color(0xFFF5F6EF),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(22, 24, 22, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Run complete!',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: Color(0xFF1F3020)),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Give it a name and review your stats.',
                  style: TextStyle(fontSize: 13, color: Color(0xFF6B7266)),
                ),
                const SizedBox(height: 18),
                TextField(
                  controller: _nameController,
                  enabled: !_isSaving,
                  style: const TextStyle(fontSize: 15),
                  decoration: InputDecoration(
                    hintText: 'Run name (e.g. Morning loop)',
                    hintStyle: const TextStyle(color: Colors.grey, fontSize: 14),
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
                const SizedBox(height: 18),
                GridView.count(
                  crossAxisCount: 2,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                  childAspectRatio: 2.4,
                  children: [
                    _SummaryStat(icon: Icons.timer_outlined, label: 'Time', value: widget.time),
                    _SummaryStat(icon: Icons.straighten_rounded, label: 'Distance', value: widget.distance),
                    _SummaryStat(
                        icon: Icons.speed_rounded,
                        label: 'Avg ${widget.units.rateLabel.toLowerCase()}',
                        value: '${widget.avgPace} ${widget.units.rateUnitLabel}'),
                    _SummaryStat(
                        icon: Icons.bolt_rounded,
                        label: 'Best ${widget.units.rateLabel.toLowerCase()}',
                        value: '${widget.maxPace} ${widget.units.rateUnitLabel}'),
                    _SummaryStat(
                        icon: Icons.local_fire_department_outlined,
                        label: 'Calories',
                        value: widget.calories),
                    _SummaryStat(icon: Icons.terrain_rounded, label: 'Elevation', value: widget.elevation),
                    _SummaryStat(
                        icon: Icons.favorite_outline,
                        label: 'Avg HR',
                        value: widget.avgHeartRate),
                    _SummaryStat(
                        icon: Icons.favorite_rounded,
                        label: 'Max HR',
                        value: widget.maxHeartRate),
                  ],
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _isSaving ? null : _handleDiscard,
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
                        onPressed: _isSaving ? null : _handleSave,
                        icon: _isSaving
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF2E7D32)),
                              )
                            : const Icon(Icons.check_circle_outline_rounded, size: 18),
                        label: const Text('Save'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFCAF0B8),
                          foregroundColor: const Color(0xFF2E7D32),
                          disabledBackgroundColor: const Color(0xFFCAF0B8),
                          disabledForegroundColor: const Color(0xFF2E7D32),
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
        ),
      ),
    );
  }
}

class _SummaryStat extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _SummaryStat({required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(color: const Color(0xFFF0F2EB), borderRadius: BorderRadius.circular(14)),
      child: Row(
        children: [
          Icon(icon, size: 18, color: const Color(0xFF4A8C52)),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  value,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: Color(0xFF1F3020)),
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  label,
                  style: const TextStyle(fontSize: 10, color: Color(0xFF6B7266), fontWeight: FontWeight.w500),
                ),
              ],
            ),
          ),
        ],
      ),
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
    final disabled = onTap == null;
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
            padding: const EdgeInsets.all(12),
            child: Icon(icon, color: disabled ? Colors.grey[400] : const Color(0xFF425143), size: 24),
          ),
        ),
      ),
    );
  }
}

// ── Runner location dot ──────────────────────────────────────────────────────

class _RunnerLocationDot extends StatelessWidget {
  const _RunnerLocationDot();

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
