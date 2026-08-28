import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../utils/geometry_utils.dart';
import 'location_service.dart';
import 'run_foreground_service.dart';
import 'run_session_repository.dart';
import '../widgets/units_scope.dart';

/// A single accepted GPS fix, kept alongside its timestamp so pace can be
/// computed over a real time window rather than a fixed number of points.
class TrackPoint {
  final LatLng point;
  final DateTime time;

  const TrackPoint(this.point, this.time);
}

/// Owns everything about a live run: the clock, the GPS stream, the breadcrumb
/// trail, distance/pace/altitude, closed-loop detection and planned-route
/// guidance. Extracted from `RunTrackingPage`, which is now purely the UI on
/// top of this.
///
/// **Singleton** ([instance]), matching `LocationService.instance` and
/// `WaterFountainService.instance`. A run therefore *can* outlive the screen
/// showing it — which is what background tracking and a smartwatch companion
/// both need, since neither can assume a `RunTrackingPage` is alive. Nothing
/// exercises that yet: `RunTrackingPage.dispose` still calls [reset], so
/// today leaving the screen still ends the run exactly as it always did.
/// Removing that one call is what will enable minimize-and-keep-running.
///
/// Because it is a singleton it is never disposed — do not call `dispose()` on
/// it. Call [reset] between runs instead; skipping that is the single most
/// likely way to break this class, since a second run would inherit the
/// first's breadcrumbs and go on to claim territory nobody ran.
class RunSessionController extends ChangeNotifier {
  RunSessionController._();

  static final RunSessionController instance = RunSessionController._();

  // ── Tuning ────────────────────────────────────────────────────────────────

  /// Metres of movement required before the GPS callback fires — the main
  /// lever trading animation smoothness against battery drain, since it's a
  /// distance filter rather than a timer poll. Currently tuned for a
  /// smooth-looking dot. 5m was the original, more battery-conservative value;
  /// once a Settings page exists, wire a "Battery saver" toggle to switch
  /// between the two instead of hardcoding one.
  static const int _distanceFilterMeters = 2;

  /// Fixes worse than this are dropped entirely — a bad fix would otherwise
  /// corrupt distance, pace and loop detection.
  static const double _accuracyThresholdMeters = 20.0;

  /// A jump implying a faster-than-humanly-possible pace is treated as a GPS
  /// spike and discarded rather than added to the trail. This is also what
  /// makes the dot appear to freeze when riding in a car — a car easily
  /// exceeds running speed, so every fix gets rejected as a "spike" rather
  /// than tracked. That's intentional (it stops someone driving to rack up
  /// distance/claim areas), but nothing currently tells the user *why*
  /// tracking has stalled — flag if that should surface a message.
  static const double _maxPlausibleSpeedMs = 8.0; // ~28.8 km/h

  /// Pace is averaged over this trailing window rather than the whole run, so
  /// it reflects how fast the runner is going *now*.
  static const double _paceWindowSeconds = 20.0;

  /// Course-over-ground is only meaningful — and not just sensor noise — once
  /// actually moving at more than a slow walk.
  static const double _minSpeedForHeadingMs = 0.6; // ~2.2 km/h
  static const int _headingSmoothingWindow = 3;

  /// Loops smaller than this are GPS noise doubling back on itself, not a
  /// deliberately-run circuit.
  static const double _minLoopAreaM2 = 50.0;

  /// How far from the planned route counts as off route. Generous enough to
  /// absorb ordinary GPS error plus running on the far pavement of a wide
  /// road, while still catching an actual wrong turn.
  static const double _offRouteThresholdMeters = 25.0;

  static const double _fixIntervalEmaAlpha = 0.35;
  static const double _fixIntervalSeed = 0.8;
  static const int _countdownFrom = 5;

  // ── Lifecycle flags ───────────────────────────────────────────────────────

  bool _isLoadingLocation = true;
  bool _permissionDenied = false;
  bool _isCountingDown = false;
  bool _countdownPaused = false;
  int _countdownValue = _countdownFrom;
  Timer? _countdownTimer;
  bool _hasStarted = false;
  bool _isPaused = false;

  /// Set by [stopClock] — the run is over and awaiting save or discard.
  /// Distinct from `!hasStarted`: the stats are all still here to be reviewed.
  /// Exists mainly so companions (the watch) can tell "finished" from "running"
  /// and stop their own clocks, which they cannot infer from a stopped
  /// stopwatch alone.
  bool _isFinished = false;

  bool get isLoadingLocation => _isLoadingLocation;
  bool get permissionDenied => _permissionDenied;
  bool get isCountingDown => _isCountingDown;
  bool get countdownPaused => _countdownPaused;
  int get countdownValue => _countdownValue;
  bool get hasStarted => _hasStarted;
  bool get isPaused => _isPaused;
  bool get isFinished => _isFinished;

  // ── Run state ─────────────────────────────────────────────────────────────

  final Stopwatch _stopwatch = Stopwatch();
  StreamSubscription<Position>? _positionSub;
  List<LatLng>? _plannedRoute;

  final List<TrackPoint> _breadcrumb = [];
  double _distanceMeters = 0;
  double? _currentPaceMinPerKm;
  double? _bestPaceMinPerKm;
  LatLng? _currentPosition;

  double _minAltitude = double.infinity;
  double _maxAltitude = double.negativeInfinity;
  bool _hasAltitudeSample = false;

  /// Rolling estimate (EMA) of the real time between accepted GPS fixes,
  /// updated every fix from the same delta already computed for the GPS-spike
  /// check. Consumed by the screen's dot-chase animation, which needs to know
  /// how long its glide has to survive before the next fix retargets it.
  double _fixIntervalEstimateSeconds = _fixIntervalSeed;

  Duration get elapsed => _stopwatch.elapsed;
  double get distanceMeters => _distanceMeters;
  double? get currentPaceMinPerKm => _currentPaceMinPerKm;
  double? get bestPaceMinPerKm => _bestPaceMinPerKm;
  LatLng? get currentPosition => _currentPosition;
  double get fixIntervalEstimateSeconds => _fixIntervalEstimateSeconds;
  List<LatLng>? get plannedRoute => _plannedRoute;
  List<TrackPoint> get breadcrumb => List.unmodifiable(_breadcrumb);

  /// The breadcrumb trail as bare points — what `runningSessions.path` stores.
  List<LatLng> get path =>
      _breadcrumb.map((t) => t.point).toList(growable: false);

  // ── Heading ───────────────────────────────────────────────────────────────

  /// Most recent (smoothed) valid GPS course-over-ground. Consumed both by the
  /// map's direction-of-travel rotation and by the route-guidance arrow.
  double? _lastHeading;
  final List<double> _recentHeadings = [];

  double? get lastHeading => _lastHeading;

  // ── Heart rate (measured on a companion watch) ────────────────────────────

  /// Reported by the watch, which is the only device that can measure it, and
  /// which accumulates the average and maximum itself — it sees every sample,
  /// whereas the phone sees roughly one message every few seconds and none
  /// while the link is down. The phone stores what it is told rather than
  /// re-deriving it from a partial view.
  ///
  /// All null when no watch is connected, or the watch has no sensor. Null is
  /// not zero: 0 bpm is not a measurement, and the difference is what lets the
  /// UI show "--" instead of a number.
  int? _heartRateBpm;
  int? _avgHeartRateBpm;
  int? _maxHeartRateBpm;

  int? get heartRateBpm => _heartRateBpm;
  int? get avgHeartRateBpm => _avgHeartRateBpm;
  int? get maxHeartRateBpm => _maxHeartRateBpm;

  void reportHeartRate({int? current, int? average, int? max}) {
    _heartRateBpm = current;
    _avgHeartRateBpm = average;
    _maxHeartRateBpm = max;
    notifyListeners();
  }

  // ── Loop detection ───────────────────────────────────────────────────────

  final List<List<LatLng>> _closedLoops = [];

  /// The [_breadcrumb] index range each entry in [_closedLoops] was built
  /// from — used only to detect when a newly-closed loop supersedes an earlier
  /// one; `GeometryUtils.findLoopClosureIndex` itself always searches the
  /// whole trail, so re-crossing ground from an already-closed loop (e.g. a
  /// bigger loop run around a smaller one) is always caught, however far back
  /// it reaches.
  final List<int> _loopRangeStart = [];
  final List<int> _loopRangeEnd = [];

  List<List<LatLng>> get closedLoops => List.unmodifiable(_closedLoops);
  int get loopsCompleted => _closedLoops.length;

  /// Total area of the loops closed so far, in square metres.
  ///
  /// The raw sum of each loop's own polygon, which is not the same as the
  /// ground the server will finally credit: overlapping loops are merged, and
  /// ground already owned is absorbed rather than added (see the claim Cloud
  /// Function). Good enough for a live "area so far" readout, and deliberately
  /// never used for anything score-affecting — that stays server-side.
  double get claimedAreaM2 => _closedLoops.fold(
        0.0,
        (sum, loop) => sum + GeometryUtils.polygonAreaM2(loop),
      );

  // ── Route guidance ────────────────────────────────────────────────────────

  RouteGuidance? _guidance;
  int? _guidanceSegmentIndex;
  bool _wasOffRoute = false;

  RouteGuidance? get guidance => _guidance;

  // ── Derived stats ─────────────────────────────────────────────────────────

  double get avgPaceMinPerKm {
    final km = _distanceMeters / 1000.0;
    if (km <= 0) return 0;
    final minutes = _stopwatch.elapsed.inMilliseconds / 1000.0 / 60.0;
    return minutes / km;
  }

  double get caloriesBurned => (_distanceMeters / 1000.0) * 70.0;

  double get elevationDifferenceMeters =>
      _hasAltitudeSample ? (_maxAltitude - _minAltitude) : 0.0;

  // ── Preparation ───────────────────────────────────────────────────────────

  /// Routes permission through the app-wide [LocationService] rather than
  /// requesting it fresh — by the time a run starts, `HomeScreen` has usually
  /// already requested it and kept GPS warm, so this resolves immediately
  /// instead of prompting again. Deliberately still takes its own precise fix
  /// (not [LocationService.current]): that fix becomes the run's first
  /// breadcrumb point, with the altitude/timestamp `LocationService` doesn't
  /// expose. Callers must await this before [startCountdown], or the run's own
  /// continuous stream could record breadcrumbs before the authoritative
  /// starting point exists.
  Future<void> prepare({List<LatLng>? plannedRoute}) async {
    _plannedRoute = plannedRoute;

    await LocationService.instance.start();
    if (!LocationService.instance.permissionGranted) {
      _isLoadingLocation = false;
      _permissionDenied = true;
      notifyListeners();
      return;
    }

    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings:
            const LocationSettings(accuracy: LocationAccuracy.high),
      );
      final ll = LatLng(pos.latitude, pos.longitude);
      _breadcrumb.add(TrackPoint(ll, pos.timestamp));
      _recordAltitude(pos.altitude);
      _currentPosition = ll;
    } catch (_) {
      // Leave [currentPosition] null — the caller decides what to show.
    }

    _isLoadingLocation = false;
    notifyListeners();
  }

  // ── Countdown ─────────────────────────────────────────────────────────────

  void startCountdown() {
    _isCountingDown = true;
    _countdownPaused = false;
    _countdownValue = _countdownFrom;
    notifyListeners();

    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_countdownValue <= 1) {
        timer.cancel();
        _isCountingDown = false;
        _countdownValue = 0;
        notifyListeners();
        _beginRun();
        return;
      }
      _countdownValue--;
      notifyListeners();
    });
  }

  void toggleCountdownPause() {
    if (_countdownPaused) {
      startCountdown(); // resuming restarts the countdown from 5
    } else {
      pauseCountdown();
    }
  }

  /// Stops the countdown without restarting it. Also used before navigating
  /// away from the countdown screen — timers keep firing even while a route
  /// isn't on top, so without this a real run could silently start while the
  /// user is away on another screen.
  void pauseCountdown() {
    _countdownTimer?.cancel();
    _countdownTimer = null;
    _countdownPaused = true;
    notifyListeners();
  }

  void _beginRun() {
    _hasStarted = true;
    _stopwatch.start();
    _startPositionStream();

    // Started here, not from the screen: this is the moment a run genuinely
    // begins, and Android 12+ only permits starting a foreground service while
    // the app is visible — which it is, since the countdown just finished on
    // screen. Starting it later, on backgrounding, would be refused.
    RunForegroundService.start(
      title: 'Recording run',
      body: _notificationBody(),
    );
    _startNotificationTicker();

    notifyListeners();
  }

  /// Refreshes the notification about once every 5 s.
  ///
  /// Deliberately not on every GPS fix: the text only shows distance and
  /// elapsed time to a resolution that changes slowly, and the channel is
  /// IMPORTANCE_LOW with `setOnlyAlertOnce`, so more frequent updates would buy
  /// nothing but wakeups.
  void _startNotificationTicker() {
    _notificationTimer?.cancel();
    _notificationTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!_hasStarted || _isFinished) return;
      RunForegroundService.update(
        title: _isPaused ? 'Run paused' : 'Recording run',
        body: _notificationBody(),
      );
    });
  }

  /*String _notificationBody() {
    final km = (_distanceMeters / 1000).toStringAsFixed(2);
    final elapsed = _stopwatch.elapsed;
    String two(int v) => v.toString().padLeft(2, '0');
    final clock = elapsed.inHours > 0
        ? '${elapsed.inHours}:${two(elapsed.inMinutes % 60)}:${two(elapsed.inSeconds % 60)}'
        : '${two(elapsed.inMinutes % 60)}:${two(elapsed.inSeconds % 60)}';
    return '$km km · $clock';
  }*/

  String _getNotificationDirection() {
    final guidance = _guidance;
    if (guidance == null) return '';
    if (guidance.isOffRoute) return ' · Off route';

    final distance = guidance.distanceToTurnMeters;
    final angle = guidance.turnAngleDegrees;

    if (distance == null || angle == null) return ' · Continue straight';

    final side = angle < 0 ? 'left' : 'right';
    final verb = angle.abs() >= 70.0 ? 'Turn' : 'Bear';

    if (distance < 15.0) return ' · $verb $side now';
    
    return ' · $verb $side in ${Units.current.shortDistance(distance, roundTo: 10)}';
  }

  String _notificationBody() {
    final elapsed = _stopwatch.elapsed;
    String two(int v) => v.toString().padLeft(2, '0');
    final clock = elapsed.inHours > 0
        ? '${elapsed.inHours}:${two(elapsed.inMinutes % 60)}:${two(elapsed.inSeconds % 60)}'
        : '${two(elapsed.inMinutes % 60)}:${two(elapsed.inSeconds % 60)}';
    
    final distanceStr = Units.current.distanceMajor(_distanceMeters);
    final directionText = _getNotificationDirection();
    
    return '$distanceStr · $clock$directionText';
  }

  Timer? _notificationTimer;

  // ── Tracking ──────────────────────────────────────────────────────────────

  void _startPositionStream() {
    _positionSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: _distanceFilterMeters,
      ),
    ).listen(onPosition);
  }

  /// Visible for testing — normally driven by the Geolocator stream. Fakes can
  /// feed synthetic fixes through this to exercise distance/pace/loop logic
  /// without a device.
  @visibleForTesting
  void onPosition(Position pos) {
    if (_isPaused) return;
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
        _fixIntervalEstimateSeconds = _fixIntervalEmaAlpha * segSeconds +
            (1 - _fixIntervalEmaAlpha) * _fixIntervalEstimateSeconds;
      }
    }

    _breadcrumb.add(TrackPoint(newPoint, newTime));
    _recordAltitude(pos.altitude);
    _updatePace();
    _checkLoopClosure();

    _currentPosition = newPoint;
    _updateGuidance(newPoint);

    if (pos.speed >= _minSpeedForHeadingMs &&
        pos.heading.isFinite &&
        pos.heading >= 0) {
      // Averaged over the last few fixes (circular mean, since heading wraps
      // at 360°) rather than trusted per-fix — a single noisy course reading
      // mid-turn was making the map's rotation visibly twitchy.
      _recentHeadings.add(pos.heading);
      if (_recentHeadings.length > _headingSmoothingWindow) {
        _recentHeadings.removeAt(0);
      }
      _lastHeading = _circularMeanDegrees(_recentHeadings);
    }

    notifyListeners();
  }

  void _recordAltitude(double altitude) {
    if (!altitude.isFinite) return;
    _hasAltitudeSample = true;
    if (altitude < _minAltitude) _minAltitude = altitude;
    if (altitude > _maxAltitude) _maxAltitude = altitude;
  }

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
      if (tip.time.difference(a.time).inMilliseconds / 1000.0 >=
          _paceWindowSeconds) {
        windowStart = a.time;
        break;
      }
    }

    final double elapsedSeconds;
    final double distanceForPace;
    if (windowStart != null) {
      elapsedSeconds =
          tip.time.difference(windowStart).inMilliseconds / 1000.0;
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
    final idx = GeometryUtils.findLoopClosureIndex(points);
    if (idx == null) return;

    final polygon = points.sublist(idx);
    final area = GeometryUtils.polygonAreaM2(polygon);
    if (area < _minLoopAreaM2) return;

    // A bigger loop supersedes any already-closed loop it overlaps with —
    // `findLoopClosureIndex` always walks as far back along the trail as still
    // closes a loop, so it's always at least as large as anything sharing its
    // ground (e.g. a bigger loop run around one already closed).
    final rangeStart = idx;
    final rangeEnd = points.length - 1;
    for (int i = _closedLoops.length - 1; i >= 0; i--) {
      final overlaps =
          _loopRangeStart[i] <= rangeEnd && rangeStart <= _loopRangeEnd[i];
      if (!overlaps) continue;
      _closedLoops.removeAt(i);
      _loopRangeStart.removeAt(i);
      _loopRangeEnd.removeAt(i);
    }

    _closedLoops.add(polygon);
    _loopRangeStart.add(rangeStart);
    _loopRangeEnd.add(rangeEnd);
  }

  /// Recomputes [guidance] for [position], and buzzes once when the runner
  /// first strays off the planned route.
  void _updateGuidance(LatLng position) {
    final route = _plannedRoute;
    if (route == null || route.length < 2) return;

    final guidance = GeometryUtils.routeGuidance(
      route,
      position,
      previousSegmentIndex: _guidanceSegmentIndex,
      offRouteThresholdMeters: _offRouteThresholdMeters,
    );
    if (guidance == null) return;

    _guidance = guidance;
    _guidanceSegmentIndex = guidance.segmentIndex;

    if (guidance.isOffRoute && !_wasOffRoute) {
      // Felt, not read — the whole point of the arrow is that a runner
      // shouldn't have to be looking at the screen to stay on route.
      HapticFeedback.heavyImpact();
    }
    _wasOffRoute = guidance.isOffRoute;
  }

  /// Circular mean of [degreesList] — averaging angles by summing their unit
  /// vectors and taking the resulting direction, rather than averaging the raw
  /// degree values, which breaks near the 0°/360° wrap (e.g. naively averaging
  /// 350° and 10° gives 180°, the exact opposite of the true ~0° average).
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

  // ── Controls ──────────────────────────────────────────────────────────────

  void togglePause() {
    _isPaused = !_isPaused;
    if (_isPaused) {
      _stopwatch.stop();
      _positionSub?.cancel();
      _positionSub = null;
      _recentHeadings.clear(); // don't blend pre-pause direction into the resume
    } else {
      _stopwatch.start();
      _startPositionStream();
    }
    notifyListeners();
  }

  /// Stops the clock and the GPS stream, leaving all accumulated stats intact
  /// so the finish summary can read them. Call [reset] once the run is
  /// genuinely over.
  void stopClock() {
    _stopwatch.stop();
    _positionSub?.cancel();
    _positionSub = null;
    _isFinished = true;
    // The run is over; the notification would otherwise sit there claiming
    // otherwise until reset() eventually ran.
    _notificationTimer?.cancel();
    _notificationTimer = null;
    RunForegroundService.stop();
    notifyListeners();
  }

  Future<String> save({required String name}) {
    return RunSessionRepository.instance.saveSession(
      name: name,
      distanceMeters: _distanceMeters,
      duration: _stopwatch.elapsed,
      avgPaceMinPerKm: avgPaceMinPerKm,
      maxPaceMinPerKm: _bestPaceMinPerKm,
      caloriesBurned: caloriesBurned,
      elevationDifferenceMeters: elevationDifferenceMeters,
      loopsCompleted: loopsCompleted,
      path: path,
      closedLoops: _closedLoops,
      avgHeartRateBpm: _avgHeartRateBpm,
      maxHeartRateBpm: _maxHeartRateBpm,
    );
  }

  /// Returns every field to its pre-run state. **Must** be called between
  /// runs — see the class doc; a missed reset means the next run inherits this
  /// one's breadcrumbs and claims ground nobody ran.
  void reset() {
    _countdownTimer?.cancel();
    _countdownTimer = null;
    // Belt and braces: discard exits without ever calling stopClock(), so this
    // is the only guaranteed teardown of the service.
    _notificationTimer?.cancel();
    _notificationTimer = null;
    RunForegroundService.stop();
    _positionSub?.cancel();
    _positionSub = null;
    _stopwatch
      ..stop()
      ..reset();

    _isLoadingLocation = true;
    _permissionDenied = false;
    _isCountingDown = false;
    _countdownPaused = false;
    _countdownValue = _countdownFrom;
    _hasStarted = false;
    _isPaused = false;
    _isFinished = false;

    _plannedRoute = null;
    _breadcrumb.clear();
    _distanceMeters = 0;
    _currentPaceMinPerKm = null;
    _bestPaceMinPerKm = null;
    _currentPosition = null;
    _fixIntervalEstimateSeconds = _fixIntervalSeed;

    _minAltitude = double.infinity;
    _maxAltitude = double.negativeInfinity;
    _hasAltitudeSample = false;

    _closedLoops.clear();
    _loopRangeStart.clear();
    _loopRangeEnd.clear();

    _lastHeading = null;
    _recentHeadings.clear();

    _heartRateBpm = null;
    _avgHeartRateBpm = null;
    _maxHeartRateBpm = null;

    _guidance = null;
    _guidanceSegmentIndex = null;
    _wasOffRoute = false;

    notifyListeners();
  }
}
