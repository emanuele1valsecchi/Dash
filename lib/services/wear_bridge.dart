import 'dart:async';

import 'package:dash_watch_protocol/dash_watch_protocol.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'run_session_controller.dart';

/// Publishes the live run to the Wear OS companion, and applies the commands it
/// sends back.
///
/// A singleton started once from `HomeScreen`, alongside `LocationService` and
/// `WaterFountainService`. It is deliberately **not** owned by
/// `RunTrackingPage`: the watch must be able to start a run when the phone is
/// in someone's pocket on the home screen, which is exactly why
/// `RunSessionController` was extracted from that page in the first place.
///
/// Everything here degrades to a no-op when no watch is connected. That is the
/// normal case, not an error — most runs will have no watch in range.
class WearBridge {
  WearBridge._();

  static final WearBridge instance = WearBridge._();

  static const MethodChannel _channel = MethodChannel('dash/wear_bridge');
  static const EventChannel _messages =
      EventChannel('dash/wear_bridge/messages');

  /// Stats are pushed on a timer rather than on every `notifyListeners()`.
  /// The controller notifies on each GPS fix *and* on every state change, which
  /// is far more often than a watch face can usefully redraw — and every
  /// message costs Bluetooth radio time, which costs battery on both devices.
  static const Duration _publishInterval = Duration(seconds: 1);

  final RunSessionController _controller = RunSessionController.instance;

  StreamSubscription<dynamic>? _incoming;
  Timer? _publishTimer;
  bool _started = false;

  /// The last phase actually sent, so [_onControllerChanged] can publish on a
  /// transition without spamming a message for every GPS fix — the controller
  /// notifies far more often than the phase changes.
  RunPhase? _lastPublishedPhase;

  /// Commands the service cannot action itself, forwarded to the UI layer —
  /// starting a run needs navigation, finishing needs the save/discard summary.
  ///
  /// A broadcast stream rather than a single callback because two screens
  /// listen for different commands (`HomeScreen` for start, `RunTrackingPage`
  /// for finish), and one callback slot would have them silently overwrite
  /// each other.
  Stream<WatchCommand> get commands => _commands.stream;
  final _commands = StreamController<WatchCommand>.broadcast();

  /// Whether a watch was reachable at the last check. Best-effort only — the
  /// Data Layer reports connected *nodes*, not whether the app is running on
  /// them.
  bool get hasWatch => _hasWatch;
  bool _hasWatch = false;

  Future<void> start() async {
    if (_started) return;
    _started = true;

    _incoming = _messages.receiveBroadcastStream().listen(
          _onMessage,
          onError: (Object error) =>
              debugPrint('WearBridge: message stream error — $error'),
        );

    _publishTimer =
        Timer.periodic(_publishInterval, (_) => _publishIfRunning());

    // Phase transitions (started, paused, finished, reset to idle) go out
    // immediately instead of waiting for the next tick — see
    // [_onControllerChanged].
    _controller.addListener(_onControllerChanged);

    await refreshWatchPresence();
  }

  Future<void> refreshWatchPresence() async {
    try {
      final nodes = await _channel.invokeMethod<List<Object?>>('nodes');
      _hasWatch = (nodes?.isNotEmpty) ?? false;
    } on PlatformException catch (e) {
      // Play Services missing or unavailable — not fatal, just no watch.
      debugPrint('WearBridge: node lookup failed — ${e.message}');
      _hasWatch = false;
    }
  }

  void _onMessage(dynamic raw) {
    if (raw is! Map) return;
    final path = raw['path'] as String?;
    final payload = raw['payload'] as String? ?? '';

    switch (path) {
      case WearPaths.command:
        final command = WatchCommand.parse(payload);
        if (command == null) {
          debugPrint('WearBridge: unknown command "$payload"');
          return;
        }
        _applyCommand(command);
      case WearPaths.requestSync:
        // The watch just connected or was just opened; it has no idea what is
        // going on until we tell it.
        _publish();
      default:
        debugPrint('WearBridge: message on unhandled path "$path"');
    }
  }

  void _applyCommand(WatchCommand command) {
    switch (command) {
      case WatchCommand.pause:
        if (!_controller.isPaused && _controller.hasStarted) {
          _controller.togglePause();
        }
      case WatchCommand.resume:
        if (_controller.isPaused) _controller.togglePause();
      case WatchCommand.start:
      case WatchCommand.finish:
        // Both need the UI: starting requires navigating to the run screen,
        // finishing requires the save/discard summary. The service cannot do
        // either, so it hands them to whoever registered [onCommand].
        if (!_commands.isClosed) _commands.add(command);
    }
    // Reflect the change back immediately rather than waiting for the next
    // tick, so the watch's own button feels responsive.
    _publish();
  }

  /// Flattens the controller's lifecycle booleans into the single value the
  /// watch renders. Order matters: a finished run still has `hasStarted` set,
  /// so [RunSessionController.isFinished] must be checked before it.
  RunPhase _phase() {
    final controller = _controller;
    if (controller.isCountingDown) return RunPhase.countdown;
    if (controller.isFinished) return RunPhase.finished;
    if (!controller.hasStarted) return RunPhase.idle;
    if (controller.isPaused) return RunPhase.paused;
    return RunPhase.running;
  }

  /// Publishes the moment the run changes phase, rather than waiting up to a
  /// second for the next tick.
  ///
  /// This is what stops a watch carrying on after a run ends. The periodic
  /// publish only fires while a run is live, so ending one used to simply stop
  /// the messages — leaving the watch showing its last snapshot, and (since it
  /// extrapolates the clock locally) still counting up. Terminal states have to
  /// be *told*, not inferred from silence.
  void _onControllerChanged() {
    final phase = _phase();
    if (phase == _lastPublishedPhase) return;
    _lastPublishedPhase = phase;
    _publish();
  }

  void _publishIfRunning() {
    if (_controller.hasStarted || _controller.isCountingDown) _publish();
  }

  Future<void> _publish() async {
    final stats = _snapshot();
    try {
      await _channel.invokeMethod<int>('send', {
        'path': WearPaths.stats,
        'payload': stats.encode(),
      });
    } on PlatformException catch (e) {
      debugPrint('WearBridge: publish failed — ${e.message}');
    }
  }

  /// Projects the controller's state onto the wire format.
  ///
  /// `claimedAreaM2` is the sum of the loops closed so far, computed the same
  /// way the phone's own display does. Heart rate is deliberately absent: it
  /// only ever travels watch → phone, since no phone can measure it.
  RunStats _snapshot() {
    final controller = _controller;

    final phase = _phase();
    final guidance = controller.guidance;

    return RunStats(
      phase: phase,
      countdownValue: controller.countdownValue,
      elapsed: controller.elapsed,
      distanceMeters: controller.distanceMeters,
      paceMinPerKm: controller.currentPaceMinPerKm,
      loopsCompleted: controller.loopsCompleted,
      claimedAreaM2: controller.claimedAreaM2,
      guidance: guidance == null
          ? null
          : WatchGuidance(
              targetBearingDegrees: guidance.targetBearingDegrees,
              headingDegrees: controller.lastHeading,
              isOffRoute: guidance.isOffRoute,
              distanceToTurnMeters: guidance.distanceToTurnMeters,
              turnAngleDegrees: guidance.turnAngleDegrees,
              distanceRemainingMeters: guidance.distanceRemainingMeters,
            ),
    );
  }

  /// Pushes one snapshot immediately. Called at moments the timer would
  /// otherwise blur over — a loop closing, a run finishing.
  Future<void> publishNow() => _publish();

  void dispose() {
    _controller.removeListener(_onControllerChanged);
    _incoming?.cancel();
    _publishTimer?.cancel();
    _commands.close();
    _started = false;
  }
}
