import 'dart:async';
import 'dart:math' as math;

import 'package:dash/extensions/dash_snackbar.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_tts/flutter_tts.dart';

import '../config/map_style.dart';
import '../models/water_fountain.dart';
import '../services/cached_tile_provider.dart';
import '../services/claimed_area_repository.dart';
import 'package:dash_watch_protocol/dash_watch_protocol.dart';

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
import '../widgets/run/expanded_stats_bar.dart';
import '../widgets/run/loop_indicator.dart';
import '../widgets/run/route_guidance_card.dart';
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

/// Pushes [RunTrackingPage] and reports how the run ended.
///
/// Lives here, next to the page and the [RunSummary] it returns, because
/// "what a finished run should say to the user" is one convention rather than
/// per-caller taste: every entry point into a run — the home screen's three
/// buttons, and a route opened from a profile — must report a discarded run
/// and a saved one the same way.
Future<void> pushRunTracking(
  BuildContext context, {
  List<LatLng>? plannedRoute,
}) async {
  final navigator = Navigator.of(context);
  final summary = await navigator.push<RunSummary>(
    MaterialPageRoute(
      builder: (_) => RunTrackingPage(plannedRoute: plannedRoute),
    ),
  );
  if (summary == null) return;

  // Reported through the *navigator's* context, not the caller's.
  //
  // A run takes minutes, and some callers do not survive it: the badge
  // overlay pops its own dialog before starting the run, so by the time this
  // resumes, `context` is unmounted and a `context.mounted` guard would
  // silently swallow the result. The Navigator outlives every route it
  // pushes, and `ScaffoldMessenger`/`Theme` resolve from there just as well.
  final reportContext = navigator.context;
  if (!reportContext.mounted) return;

  if (!summary.saved) {
    reportContext.showWarningSnackBar("Run discarded");
    return;
  }

  final distance = Units.current.distanceMajor(summary.distanceMeters);
  final minutes = summary.elapsed.inMinutes;
  final loopsText = summary.loopsCompleted > 0
      ? ', ${summary.loopsCompleted} loop${summary.loopsCompleted == 1 ? '' : 's'} closed'
      : '';
  reportContext
      .showSuccessSnackBar('Run saved — $distance in $minutes min$loopsText');
}

// ── Page ─────────────────────────────────────────────────────────────────────

class RunTrackingPage extends StatefulWidget {
  const RunTrackingPage({
    super.key,
    this.plannedRoute,
    this.auth,
    this.areaRepository,
  });

  /// Optional route to display as a thin static guide line, when the user
  /// chose "Save route and Run" from route creation. Purely visual — this
  /// screen doesn't track on/off-route state or reroute if the user strays.
  final List<LatLng>? plannedRoute;

  /// Test seams. Production leaves both null and the state resolves the
  /// singleton/`.instance` lazily — an eager field initializer would throw
  /// `[core/no-app]` when the widget is *constructed*, before `runApp`.
  @visibleForTesting
  final FirebaseAuth? auth;
  @visibleForTesting
  final ClaimedAreaRepository? areaRepository;

  @override
  State<RunTrackingPage> createState() => _RunTrackingPageState();
}

class _RunTrackingPageState extends State<RunTrackingPage> with TickerProviderStateMixin {
  late final FirebaseAuth _auth = widget.auth ?? FirebaseAuth.instance;
  late final ClaimedAreaRepository _areaRepository =
      widget.areaRepository ?? ClaimedAreaRepository.instance;

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
    final uid = _auth.currentUser?.uid;
    return _allAreas.where((area) {
      final isMine = area.userId == uid;
      return isMine ? _showMyAreas : _showOtherAreas;
    }).toList();
  }

  // ── Dot smoothing ─────────────────────────────────────────────────────────
  LatLng? _displayedPosition;
  double? _displayedHeading;
  late final Ticker _dotTicker;
  Duration _dotTickerLastElapsed = Duration.zero;

  static const double _dotChaseTauMultiplier = 1.5;
  static const double _dotChaseTauMin = 0.3;
  static const double _dotChaseTauMax = 2.5;
  static const double _dotChaseSnapThresholdMeters = 0.25;

  // ── UI-only run bookkeeping ───────────────────────────────────────────────

  Timer? _uiTicker;
  bool _isFinishing = false;
  StreamSubscription<WatchCommand>? _watchCommands;

  // ── TTS State ─────────────────────────────────────────────────────────────
  final FlutterTts _flutterTts = FlutterTts();
  bool _isVoiceEnabled = true;
  String _lastSpokenMilestone = '';

  void _onWatchCommand(WatchCommand command) {
    if (command != WatchCommand.finish) return;
    if (!mounted || _isFinishing) return;
    _confirmFinish(alreadyConfirmed: true);
  }

  final List<LatLng> _trailPoints = [];
  List<LatLng>? _smoothedPlannedRoute;

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _controller.reset();
    _controller.addListener(_onSessionChanged);
    _watchCommands = WearBridge.instance.commands.listen(_onWatchCommand);

    _dotTicker = createTicker(_onDotTick)..start();
    final route = widget.plannedRoute;
    _smoothedPlannedRoute =
        (route != null && route.length >= 3) ? GeometryUtils.smoothPolyline(route) : route;
    
    _initTts();
    _initLocation();
    _loadClaimedAreas();
  }

  Future<void> _initTts() async {
    await _flutterTts.setLanguage("en-US"); 
    await _flutterTts.setSpeechRate(0.5);
    await _flutterTts.setVolume(1.0);
  }

  void _onSessionChanged() {
    if (!mounted) return;

    if (_controller.hasStarted && _uiTicker == null) _startUiTicker();

    final length = _controller.breadcrumb.length;
    if (length > _lastBreadcrumbLength) {
      _lastBreadcrumbLength = length;
      final position = _controller.currentPosition;
      if (position != null) {
        _advanceTrail(position);
        _handleTtsGuidance();
      }
    }
    setState(() {});
  }

  void _handleTtsGuidance() {
    if (!_isVoiceEnabled) return;
    
    final guidance = _controller.guidance;
    if (guidance == null) return;

    // 1. Off route warning
    if (guidance.isOffRoute) {
      if (_lastSpokenMilestone != 'off_route') {
        _flutterTts.speak("You are off route.");
        _lastSpokenMilestone = 'off_route';
      }
      return;
    }

    // 2. Back on route
    if (_lastSpokenMilestone == 'off_route' && !guidance.isOffRoute) {
      _flutterTts.speak("Back on route.");
      _lastSpokenMilestone = '';
      return;
    }

    final distance = guidance.distanceToTurnMeters;
    final angle = guidance.turnAngleDegrees;

    if (distance == null || angle == null) return;

    final side = angle < 0 ? 'left' : 'right';
    final verb = angle.abs() >= 70.0 ? 'Turn' : 'Bear';

    String milestoneKey = '';
    String phraseToSpeak = '';

    if (distance <= 15.0) {
      milestoneKey = 'now';
      phraseToSpeak = '$verb $side now';
    } else if (distance <= 50.0) {
      milestoneKey = '50';
      phraseToSpeak = 'In 50 meters, $verb $side';
    } else if (distance <= 100.0) {
      milestoneKey = '100';
      phraseToSpeak = 'In 100 meters, $verb $side';
    }

    if (milestoneKey.isNotEmpty) {
      final uniqueTurnKey = '${guidance.segmentIndex}_$milestoneKey';

      if (_lastSpokenMilestone != uniqueTurnKey) {
        _flutterTts.speak(phraseToSpeak);
        _lastSpokenMilestone = uniqueTurnKey;
      }
    }
  }

  Future<void> _loadClaimedAreas() async {
    final areas = await _areaRepository.areasStream().first;
    if (!mounted) return;
    setState(() => _allAreas = areas);
  }

  @override
  void dispose() {
    _flutterTts.stop();
    _watchCommands?.cancel();
    _controller.removeListener(_onSessionChanged);
    _controller.reset();

    _uiTicker?.cancel();
    _dotTicker.dispose();
    _mapController.dispose();
    _previewMapController.dispose();
    super.dispose();
  }

  // ── Location & tracking ──────────────────────────────────────────────────

  Future<void> _initLocation() async {
    await RunForegroundService.ensureNotificationPermission();
    if (!mounted) return;

    await _controller.prepare(plannedRoute: widget.plannedRoute);
    if (!mounted) return;
    if (_controller.permissionDenied) return;

    final start = _controller.currentPosition;
    if (start != null) {
      _lastBreadcrumbLength = _controller.breadcrumb.length;
      _trailPoints.add(start);
      setState(() => _displayedPosition = start);

      _waterFountainService.fetchNearby(start).then((fountains) {
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

  static const double _startConnectorMinDistanceMeters = 15.0;

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

  Future<void> _openTestRunCreator() async {
    if (!_controller.countdownPaused) _controller.pauseCountdown();

    final created = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const TestRunCreatorPage()),
    );

    if (created == true && mounted) {
      Navigator.of(context).pop();
    }
  }

  static const double _maxStartDistanceMeters = 150.0;

  void _startUiTicker() {
    _uiTicker?.cancel();
    _uiTicker = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (mounted) setState(() {});
    });
  }

  void _advanceTrail(LatLng newPoint) {
    if (_displayedPosition == null) {
      _displayedPosition = newPoint;
      _trailPoints.add(newPoint);
      return;
    }
    _trailPoints.add(_displayedPosition!);
  }

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
    if (positionSettled && headingSettled) return;

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
      } catch (_) {}
    } else if (!_isMapExpanded) {
      try {
        _previewMapController.move(newDisplayed, _previewZoom);
      } catch (_) {}
    }
  }

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

  double _lerpAngleDegrees(double a, double b, double t) {
    var diff = (b - a + 180) % 360 - 180;
    if (diff < -180) diff += 360;
    return a + diff * t;
  }

  // ── Camera animation ─────────────────────────────────────────────────────

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
      return;
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
      _isFollowingUser = true;
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
    Navigator.of(context).pop();
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
    Navigator.of(context).pop();
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

  String _formatDistance(UnitFormatter units) =>
      units.distanceMajor(_controller.distanceMeters);

  String _formatBpm(int? bpm) => bpm == null ? '--' : '$bpm bpm';

  String _formatRateValue(UnitFormatter units, double? paceMinPerKm) =>
      units.rateValueFromPace(paceMinPerKm);

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return PopScope(
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
              children: <Widget>[
                const SizedBox(height: 12),
                _buildTimeDisplay(),
                if (_controller.guidance != null) ...[
                  const SizedBox(height: 18),
                  RouteGuidanceCard(
                    guidance: _controller.guidance!,
                    progress: _controller.routeProgress,
                    heading: _displayedHeading,
                    isVoiceEnabled: _isVoiceEnabled,
                    onToggleVoice: () {
                      setState(() {
                        _isVoiceEnabled = !_isVoiceEnabled;
                        if (!_isVoiceEnabled) _flutterTts.stop();
                      });
                    },
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
                LoopIndicator(loopsCompleted: _controller.loopsCompleted),
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
          child: ExpandedStatsBar(
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
          child: _RoundMapButton(
            icon: _isVoiceEnabled ? Icons.volume_up_rounded : Icons.volume_off_rounded,
            tooltip: 'Toggle Voice Guidance',
            onTap: () {
              setState(() {
                _isVoiceEnabled = !_isVoiceEnabled;
                if (!_isVoiceEnabled) _flutterTts.stop();
              });
            },
          ),
        ),
        Positioned(
          right: 16,
          bottom: 220,
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
          ClaimedAreasLayer(areas: _visibleAreas),
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
          if (_startConnectorLine case final connector?)
            PolylineLayer(polylines: [connector]),
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
          WaterFountainMarkerLayer(fountains: _waterFountains, visible: _fountainsVisible),
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

// ── Finish summary dialog ────────────────────────────────────────────────────

class _RunSummaryDialog extends StatefulWidget {
  final UnitFormatter units;

  final String time;
  final String distance;
  final String avgPace;
  final String maxPace;
  final String calories;
  final String elevation;

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