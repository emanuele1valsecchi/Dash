import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/run_session_repository.dart';
import '../utils/geometry_utils.dart';
import 'test_run_creator_page.dart';

// ── Track point ──────────────────────────────────────────────────────────────

/// A single accepted GPS fix, kept alongside its timestamp so pace can be
/// computed over a rolling time window rather than raw instantaneous speed.
class _TrackPoint {
  final LatLng point;
  final DateTime time;
  const _TrackPoint(this.point, this.time);
}

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
  const RunTrackingPage({super.key});

  @override
  State<RunTrackingPage> createState() => _RunTrackingPageState();
}

class _RunTrackingPageState extends State<RunTrackingPage> with TickerProviderStateMixin {
  // ── Map ───────────────────────────────────────────────────────────────────
  final MapController _mapController = MapController();
  static const double _defaultZoom = 18.0;
  bool _isMapExpanded = false;

  /// Whether the map is auto-recentering on the runner. Turned off by the
  /// "see whole path" button so the overview it animates to doesn't get
  /// immediately overridden by the next GPS fix; the same button switches to
  /// a "follow me" action to turn it back on.
  bool _isFollowingUser = true;
  bool _isCameraAnimating = false;

  /// Most recent (smoothed) valid GPS course-over-ground, used to keep the
  /// expanded map oriented in the runner's direction of travel instead of
  /// north-up.
  double? _lastHeading;

  /// Recent raw headings feeding [_lastHeading]'s circular mean — see
  /// [_circularMeanDegrees].
  final List<double> _recentHeadings = [];
  static const int _headingSmoothingWindow = 3;

  /// Course-over-ground is only meaningful — and not just sensor noise —
  /// once actually moving at more than a slow walk.
  static const double _minSpeedForHeadingMs = 0.6; // ~2.2 km/h

  // ── Location ──────────────────────────────────────────────────────────────
  StreamSubscription<Position>? _positionSub;
  LatLng? _currentPosition;
  bool _isLoadingLocation = true;
  bool _permissionDenied = false;

  // ── Dot smoothing ─────────────────────────────────────────────────────────
  //
  // GPS fixes arrive in discrete jumps, which makes the marker teleport
  // instead of glide. This is a single exponential "chase": a perpetual
  // per-frame ticker nudges [_displayedPosition] a fraction of the remaining
  // gap toward [_currentPosition] (the raw latest fix) every frame, scaled
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
  // [_fixIntervalEstimateSeconds], with enough headroom that the chase
  // structurally cannot finish converging before the next fix retargets it.
  // It only actually reaches "settled" once fixes genuinely stop arriving —
  // i.e. the runner has actually stopped — which is exactly when the dot
  // should stop moving.
  LatLng? _displayedPosition;
  double? _displayedHeading;
  late final Ticker _dotTicker;
  Duration _dotTickerLastElapsed = Duration.zero;

  /// Rolling estimate (EMA) of the real time between accepted GPS fixes,
  /// updated every fix from the same delta already computed for the
  /// GPS-spike check. Seeded with a plausible default before any fixes
  /// have arrived.
  double _fixIntervalEstimateSeconds = 0.8;
  static const double _fixIntervalEmaAlpha = 0.35;

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

  /// Fixes worse than this are dropped entirely — a bad fix would otherwise
  /// corrupt distance, pace and loop detection.
  static const double _accuracyThresholdMeters = 20.0;

  /// A jump implying a faster-than-humanly-possible pace is treated as a GPS
  /// spike and discarded rather than added to the trail. This is also what
  /// makes the dot appear to freeze when riding in a car — a car easily
  /// exceeds running speed, so every fix gets rejected as a "spike" rather
  /// than tracked. That's intentional (it stops someone from driving to
  /// rack up distance/claim areas), but nothing currently tells the user
  /// *why* tracking has stalled — flag if that should surface a message.
  static const double _maxPlausibleSpeedMs = 8.0; // ~28.8 km/h

  // ── Pre-run countdown ─────────────────────────────────────────────────────
  bool _isCountingDown = false;
  bool _countdownPaused = false;
  int _countdownValue = 5;
  Timer? _countdownTimer;
  bool _hasStarted = false;

  // ── Run state ─────────────────────────────────────────────────────────────
  final Stopwatch _stopwatch = Stopwatch();
  Timer? _uiTicker;
  bool _isPaused = false;
  bool _isFinishing = false;

  final List<_TrackPoint> _breadcrumb = [];
  double _distanceMeters = 0;
  double? _currentPaceMinPerKm;
  double? _bestPaceMinPerKm;

  double _minAltitude = double.infinity;
  double _maxAltitude = double.negativeInfinity;
  bool _hasAltitudeSample = false;

  // ── Loop detection ───────────────────────────────────────────────────────
  int _activeLoopStart = 0;
  final List<List<LatLng>> _closedLoops = [];
  int _loopsCompleted = 0;
  static const double _minLoopAreaM2 = 50.0;

  // ── Derived stats (used both live and in the finish summary) ────────────
  double get _avgPaceMinPerKm {
    final km = _distanceMeters / 1000.0;
    if (km <= 0) return 0;
    final minutes = _stopwatch.elapsed.inMilliseconds / 1000.0 / 60.0;
    return minutes / km;
  }

  double get _caloriesBurned => (_distanceMeters / 1000.0) * 70.0;

  double get _elevationDifferenceMeters =>
      _hasAltitudeSample ? (_maxAltitude - _minAltitude) : 0.0;

  /// The trail as painted on the map: every confirmed fix, plus a final
  /// "live" vertex that the dot-chase ([_onDotTick]) mutates in place each
  /// frame rather than rebuilding this whole list from [_breadcrumb] every
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
  /// needed. [_breadcrumb] stays the raw, unsmoothed source of truth for
  /// distance/pace/loop-closure — none of that math is affected by this.
  final List<LatLng> _trailPoints = [];

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _dotTicker = createTicker(_onDotTick)..start();
    _initLocation();
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    _uiTicker?.cancel();
    _countdownTimer?.cancel();
    _dotTicker.dispose();
    _mapController.dispose();
    super.dispose();
  }

  // ── Location & tracking ──────────────────────────────────────────────────

  Future<void> _initLocation() async {
    final status = await Permission.locationWhenInUse.request();
    if (!status.isGranted) {
      setState(() {
        _isLoadingLocation = false;
        _permissionDenied = true;
      });
      return;
    }

    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      );
      final ll = LatLng(pos.latitude, pos.longitude);
      _breadcrumb.add(_TrackPoint(ll, pos.timestamp));
      _recordAltitude(pos.altitude);
      _trailPoints.add(ll);
      setState(() {
        _currentPosition = ll;
        _displayedPosition = ll; // nothing to chase from yet — show it directly
        _isLoadingLocation = false;
      });
    } catch (_) {
      setState(() => _isLoadingLocation = false);
    }

    _startCountdown();
  }

  void _recordAltitude(double altitude) {
    if (!altitude.isFinite) return;
    _hasAltitudeSample = true;
    if (altitude < _minAltitude) _minAltitude = altitude;
    if (altitude > _maxAltitude) _maxAltitude = altitude;
  }

  // ── Pre-run countdown ─────────────────────────────────────────────────────

  void _startCountdown() {
    setState(() {
      _isCountingDown = true;
      _countdownPaused = false;
      _countdownValue = 5;
    });
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_countdownValue <= 1) {
        timer.cancel();
        setState(() {
          _isCountingDown = false;
          _countdownValue = 0;
        });
        _beginRun();
        return;
      }
      setState(() => _countdownValue--);
    });
  }

  void _toggleCountdownPause() {
    if (_countdownPaused) {
      _startCountdown(); // resuming restarts the countdown from 5
    } else {
      _countdownTimer?.cancel();
      setState(() => _countdownPaused = true);
    }
  }

  /// Dev-only shortcut for generating `runningSessions` docs without
  /// physically running, to test the area-claiming logic.
  Future<void> _openTestRunCreator() async {
    // Pause the countdown before leaving — timers keep firing even while
    // this route isn't on top, so without this a real run could silently
    // start while the user is away on the testing screen.
    if (!_countdownPaused) {
      _countdownTimer?.cancel();
      setState(() => _countdownPaused = true);
    }

    final created = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const TestRunCreatorPage()),
    );

    // A test run was published in place of a real one — close this screen too.
    if (created == true && mounted) {
      Navigator.of(context).pop();
    }
  }

  void _beginRun() {
    _hasStarted = true;
    _stopwatch.start();
    _startPositionStream();

    // Drives the HH:MM:SS:DD display; independent of GPS so the clock stays
    // smooth even between location fixes.
    _uiTicker = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (mounted) setState(() {});
    });
  }

  // Metres of movement required before the GPS callback fires — the main
  // lever trading animation smoothness against battery drain, since it's
  // a distance filter rather than a timer poll. Currently tuned for a
  // smooth-looking dot. 5m was the original, more battery-conservative
  // value; once a Settings page exists, wire a "Battery saver" toggle to
  // switch between the two instead of hardcoding one.
  static const int _distanceFilterMeters = 2;

  void _startPositionStream() {
    _positionSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: _distanceFilterMeters,
      ),
    ).listen(_onPosition);
  }

  void _onPosition(Position pos) {
    if (_isPaused || !mounted) return;
    if (pos.accuracy > _accuracyThresholdMeters) return;

    final newPoint = LatLng(pos.latitude, pos.longitude);
    final newTime = pos.timestamp;

    if (_breadcrumb.isNotEmpty) {
      final prev = _breadcrumb.last;
      final segMeters = const Distance()(prev.point, newPoint);
      final segSeconds = newTime.difference(prev.time).inMilliseconds / 1000.0;
      if (segSeconds > 0 && segMeters / segSeconds > _maxPlausibleSpeedMs) {
        return; // GPS spike — ignore this fix entirely.
      }
      _distanceMeters += segMeters;
      if (segSeconds > 0) {
        _fixIntervalEstimateSeconds =
            _fixIntervalEmaAlpha * segSeconds + (1 - _fixIntervalEmaAlpha) * _fixIntervalEstimateSeconds;
      }
    }

    _breadcrumb.add(_TrackPoint(newPoint, newTime));
    _recordAltitude(pos.altitude);
    _updatePace();
    _checkLoopClosure();

    _currentPosition = newPoint;

    if (pos.speed >= _minSpeedForHeadingMs && pos.heading.isFinite && pos.heading >= 0) {
      // Averaged over the last few fixes (circular mean, since heading wraps
      // at 360°) rather than trusted per-fix — a single noisy course reading
      // mid-turn was making the map's rotation visibly twitchy.
      _recentHeadings.add(pos.heading);
      if (_recentHeadings.length > _headingSmoothingWindow) {
        _recentHeadings.removeAt(0);
      }
      _lastHeading = _circularMeanDegrees(_recentHeadings);
    }

    _advanceTrail(newPoint);
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
  /// nudging [_displayedPosition]/[_displayedHeading] toward [_currentPosition]
  /// / [_lastHeading]. See the "Dot smoothing" field comments for why this is
  /// a perpetual, adaptively-paced chase rather than a bounded per-fix
  /// animation or a fixed time constant.
  void _onDotTick(Duration elapsed) {
    if (!mounted) return;
    final dtMs = (elapsed - _dotTickerLastElapsed).inMilliseconds;
    _dotTickerLastElapsed = elapsed;
    if (dtMs <= 0) return;
    final dt = dtMs / 1000.0;

    final target = _currentPosition;
    final current = _displayedPosition;
    if (target == null || current == null) return;

    final tau =
        (_fixIntervalEstimateSeconds * _dotChaseTauMultiplier).clamp(_dotChaseTauMin, _dotChaseTauMax);
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
    final headingTarget = _lastHeading;
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
        _mapController.moveAndRotate(newDisplayed, _mapController.camera.zoom, -(newHeading ?? 0));
      } catch (_) {
        // Map not attached yet — next tick will re-attempt.
      }
    }
  }

  /// Interpolates from angle [a] to [b] (degrees) along whichever direction
  /// is shorter, so e.g. 350°→10° sweeps forward through 360° instead of
  /// spinning the long way back through 180°.
  double _lerpAngleDegrees(double a, double b, double t) {
    var diff = (b - a + 180) % 360 - 180;
    if (diff < -180) diff += 360;
    return a + diff * t;
  }

  /// Circular mean of [degreesList] — averaging angles by summing their unit
  /// vectors and taking the resulting direction, rather than averaging the
  /// raw degree values, which breaks near the 0°/360° wrap (e.g. naively
  /// averaging 350° and 10° gives 180°, the exact opposite of the true ~0°
  /// average).
  double _circularMeanDegrees(List<double> degreesList) {
    double sumSin = 0, sumCos = 0;
    for (final d in degreesList) {
      final rad = d * math.pi / 180;
      sumSin += math.sin(rad);
      sumCos += math.cos(rad);
    }
    var meanDeg = math.atan2(sumSin, sumCos) * 180 / math.pi;
    if (meanDeg < 0) meanDeg += 360;
    return meanDeg;
  }

  // ── Camera animation ─────────────────────────────────────────────────────

  /// Animates the camera to [targetCenter]/[targetZoom] over a short tween
  /// instead of jumping instantly. flutter_map has no built-in animated
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

  /// Zooms/pans out just far enough to fit the whole run trail on screen.
  Future<void> _fitPathInView() async {
    if (_breadcrumb.length < 2) return;
    try {
      final targetCamera = CameraFit.coordinates(
        coordinates: _breadcrumb.map((t) => t.point).toList(growable: false),
        // Leaves room for the stats bar (top) and the button/controls row (bottom).
        padding: const EdgeInsets.fromLTRB(40, 110, 40, 170),
        // Never zoom in past the normal follow zoom — early in a run the
        // whole trail can fit in a tiny area, and without this cap "see
        // whole path" would zoom in tighter than the default view instead
        // of only ever zooming out.
        maxZoom: _defaultZoom,
      ).fit(_mapController.camera);
      await _animateCameraTo(targetCamera.center, targetCamera.zoom);
    } catch (_) {
      // Map not attached yet.
    }
  }

  Future<void> _handleFitPathTap() async {
    if (_isFollowingUser) {
      setState(() => _isFollowingUser = false);
      await _fitPathInView();
    } else {
      setState(() => _isFollowingUser = true);
      final target = _displayedPosition ?? _currentPosition;
      if (target != null) {
        await _animateCameraTo(target, _defaultZoom);
      }
    }
  }

  /// Average pace over the trailing [_paceWindowSeconds]; falls back to the
  /// whole-run average until enough history has built up.
  static const double _paceWindowSeconds = 20.0;

  void _updatePace() {
    if (_breadcrumb.length < 2) {
      _currentPaceMinPerKm = null;
      return;
    }

    final tip = _breadcrumb.last;
    double windowDistance = 0;
    DateTime? windowStart;

    for (int i = _breadcrumb.length - 1; i > 0; i--) {
      final a = _breadcrumb[i - 1];
      final b = _breadcrumb[i];
      windowDistance += const Distance()(a.point, b.point);
      if (tip.time.difference(a.time).inMilliseconds / 1000.0 >= _paceWindowSeconds) {
        windowStart = a.time;
        break;
      }
    }

    final double elapsedSeconds;
    final double distanceForPace;
    if (windowStart != null) {
      elapsedSeconds = tip.time.difference(windowStart).inMilliseconds / 1000.0;
      distanceForPace = windowDistance;
    } else {
      elapsedSeconds = _stopwatch.elapsed.inMilliseconds / 1000.0;
      distanceForPace = _distanceMeters;
    }

    if (distanceForPace < 3 || elapsedSeconds <= 0) {
      _currentPaceMinPerKm = null;
      return;
    }
    final pace = (elapsedSeconds / 60.0) / (distanceForPace / 1000.0);
    _currentPaceMinPerKm = pace;
    if (_bestPaceMinPerKm == null || pace < _bestPaceMinPerKm!) {
      _bestPaceMinPerKm = pace;
    }
  }

  void _checkLoopClosure() {
    final points = _breadcrumb.map((t) => t.point).toList(growable: false);
    final idx = GeometryUtils.findLoopClosureIndex(points, activeStart: _activeLoopStart);
    if (idx == null) return;

    final polygon = points.sublist(idx);
    final area = GeometryUtils.polygonAreaM2(polygon);
    if (area < _minLoopAreaM2) return;

    _closedLoops.add(polygon);
    _loopsCompleted++;
    _activeLoopStart = points.length - 1;
  }

  // ── Controls ──────────────────────────────────────────────────────────────

  void _togglePause() {
    setState(() => _isPaused = !_isPaused);
    if (_isPaused) {
      _stopwatch.stop();
      _positionSub?.cancel();
      _positionSub = null;
      _recentHeadings.clear(); // don't blend pre-pause direction into the resumed run
    } else {
      _stopwatch.start();
      _startPositionStream();
    }
  }

  void _toggleMapExpanded() {
    setState(() {
      _isMapExpanded = !_isMapExpanded;
      _isFollowingUser = true; // always reopen the map in follow mode
    });
    final target = _displayedPosition ?? _currentPosition;
    if (_isMapExpanded && target != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        try {
          _mapController.moveAndRotate(target, _defaultZoom, -(_lastHeading ?? 0));
        } catch (_) {}
      });
    }
  }

  Future<void> _confirmDiscard() async {
    if (!_hasStarted) {
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

  Future<void> _confirmFinish() async {
    if (_distanceMeters < 20) {
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
    _stopwatch.stop();
    _positionSub?.cancel();
    _positionSub = null;
    _uiTicker?.cancel();
  }

  void _finishRun({required bool saved}) {
    if (_isFinishing) return;
    _isFinishing = true;
    if (!mounted) return;
    Navigator.of(context).pop(
      RunSummary(
        distanceMeters: _distanceMeters,
        elapsed: _stopwatch.elapsed,
        loopsCompleted: _loopsCompleted,
        saved: saved,
      ),
    );
  }

  // ── Finish summary: name the run, review stats, save or discard ─────────

  Future<void> _showRunSummarySheet() async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _RunSummaryDialog(
        time: _formatElapsed(),
        distance: _formatDistanceKm(),
        avgPace: _formatPaceValue(_avgPaceMinPerKm),
        maxPace: _formatPaceValue(_bestPaceMinPerKm),
        calories: '${_caloriesBurned.round()} kcal',
        elevation: '${_elevationDifferenceMeters.round()} m',
        onSave: (name) => RunSessionRepository.instance.saveSession(
          name: name,
          distanceMeters: _distanceMeters,
          duration: _stopwatch.elapsed,
          avgPaceMinPerKm: _avgPaceMinPerKm,
          maxPaceMinPerKm: _bestPaceMinPerKm,
          caloriesBurned: _caloriesBurned,
          elevationDifferenceMeters: _elevationDifferenceMeters,
          loopsCompleted: _loopsCompleted,
          path: _breadcrumb.map((t) => t.point).toList(growable: false),
          closedLoops: _closedLoops,
        ),
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

  void _handleSummarySaved() {
    Navigator.of(context).pop(); // close the summary dialog
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
    final e = _stopwatch.elapsed;
    String two(int v) => v.toString().padLeft(2, '0');
    final hh = two(e.inHours);
    final mm = two(e.inMinutes % 60);
    final ss = two(e.inSeconds % 60);
    final dd = two((e.inMilliseconds % 1000) ~/ 10);
    return '$hh:$mm:$ss:$dd';
  }

  String _formatDistanceKm() => '${(_distanceMeters / 1000).toStringAsFixed(2)} km';

  String _formatPaceValue(double? pace) {
    if (pace == null || !pace.isFinite || pace <= 0) return '--:--';
    final minutes = pace.floor();
    final seconds = ((pace - minutes) * 60).round();
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF3F5EE),
      body: SafeArea(
        child: _isLoadingLocation
            ? _buildLoadingView()
            : _permissionDenied
                ? _buildPermissionDeniedView()
                : _isCountingDown
                    ? _buildCountdownView()
                    : _isMapExpanded
                        ? _buildExpandedMapView()
                        : _buildStatsView(),
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
                  setState(() {
                    _permissionDenied = false;
                    _isLoadingLocation = true;
                  });
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
                  '$_countdownValue',
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
                    onPressed: _toggleCountdownPause,
                    style: ElevatedButton.styleFrom(
                      backgroundColor:
                          _countdownPaused ? const Color(0xFFCAF0B8) : const Color(0xFFF4C7C3),
                      foregroundColor:
                          _countdownPaused ? const Color(0xFF2E7D32) : const Color(0xFF8A3B34),
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    ),
                    child: Text(
                      _countdownPaused ? 'RESUME' : 'STOP',
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
                const SizedBox(height: 22),
                Row(
                  children: [
                    Expanded(
                      child: _StatBlock(
                        icon: Icons.straighten_rounded,
                        label: 'Distance',
                        value: _formatDistanceKm(),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: _StatBlock(
                        icon: Icons.speed_rounded,
                        label: 'Pace (min/km)',
                        value: _formatPaceValue(_currentPaceMinPerKm),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                _LoopIndicator(loopsCompleted: _loopsCompleted),
                const SizedBox(height: 18),
                _MapPreviewButton(onTap: _toggleMapExpanded),
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
          if (_isPaused)
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
              onPressed: _togglePause,
              icon: Icon(_isPaused ? Icons.play_arrow_rounded : Icons.pause_rounded, size: 20),
              label: Text(_isPaused ? 'Resume' : 'Pause'),
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
    return Stack(
      children: [
        _buildMap(),
        Positioned(
          top: 8,
          left: 12,
          right: 12,
          child: _ExpandedStatsBar(
            time: _formatElapsed(),
            distance: _formatDistanceKm(),
            pace: _formatPaceValue(_currentPaceMinPerKm),
            loopsCompleted: _loopsCompleted,
            onCollapse: _toggleMapExpanded,
          ),
        ),
        Positioned(
          right: 16,
          bottom: 108,
          child: _RoundMapButton(
            icon: _isFollowingUser ? Icons.zoom_out_map_rounded : Icons.my_location_rounded,
            tooltip: _isFollowingUser ? 'See whole path' : 'Follow me',
            onTap: (_isFollowingUser && _breadcrumb.length < 2) ? null : _handleFitPathTap,
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

  Widget _buildMap() {
    return FlutterMap(
      mapController: _mapController,
      options: MapOptions(
        initialCenter: _displayedPosition ?? _currentPosition ?? const LatLng(45.4642, 9.1900),
        initialZoom: _defaultZoom,
        interactionOptions: const InteractionOptions(
          flags: InteractiveFlag.pinchZoom | InteractiveFlag.doubleTapZoom,
        ),
      ),
      children: [
        TileLayer(
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: 'com.dash',
        ),

        // ── Claimed loop fills ───────────────────────────────────────────
        if (_closedLoops.isNotEmpty)
          PolygonLayer(
            polygons: _closedLoops
                .map((poly) => Polygon(
                      points: poly,
                      color: const Color(0xFF4A8C52).withValues(alpha: 0.18),
                      borderColor: const Color(0xFF4A8C52).withValues(alpha: 0.6),
                      borderStrokeWidth: 2.2,
                    ))
                .toList(),
          ),

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

        // ── Runner position ────────────────────────────────────────────
        if ((_displayedPosition ?? _currentPosition) != null)
          MarkerLayer(
            markers: [
              Marker(
                point: _displayedPosition ?? _currentPosition!,
                width: 60,
                height: 60,
                child: const _RunnerLocationDot(),
              ),
            ],
          ),
      ],
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

// ── Map preview button ───────────────────────────────────────────────────────

class _MapPreviewButton extends StatelessWidget {
  final VoidCallback onTap;

  const _MapPreviewButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(18),
      elevation: 1,
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: const Padding(
          padding: EdgeInsets.symmetric(vertical: 14, horizontal: 18),
          child: Row(
            children: [
              Icon(Icons.map_rounded, color: Color(0xFF4A8C52), size: 22),
              SizedBox(width: 12),
              Expanded(
                child: Text(
                  'View live map',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFF425143)),
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: Color(0xFF9AA294)),
            ],
          ),
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
  final int loopsCompleted;
  final VoidCallback onCollapse;

  const _ExpandedStatsBar({
    required this.time,
    required this.distance,
    required this.pace,
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
                        '$distance  ·  $pace /km',
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
  final String time;
  final String distance;
  final String avgPace;
  final String maxPace;
  final String calories;
  final String elevation;
  final Future<void> Function(String name) onSave;
  final Future<bool?> Function() onRequestDiscardConfirm;
  final VoidCallback onDiscarded;
  final VoidCallback onSaved;

  const _RunSummaryDialog({
    required this.time,
    required this.distance,
    required this.avgPace,
    required this.maxPace,
    required this.calories,
    required this.elevation,
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
      await widget.onSave(_nameController.text);
      widget.onSaved();
    } catch (e) {
      if (!mounted) return;
      setState(() => _isSaving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save run: $e')),
      );
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
                        icon: Icons.speed_rounded, label: 'Avg pace', value: '${widget.avgPace} /km'),
                    _SummaryStat(
                        icon: Icons.bolt_rounded, label: 'Max pace', value: '${widget.maxPace} /km'),
                    _SummaryStat(
                        icon: Icons.local_fire_department_outlined,
                        label: 'Calories',
                        value: widget.calories),
                    _SummaryStat(icon: Icons.terrain_rounded, label: 'Elevation', value: widget.elevation),
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
