import 'dart:async';
import 'dart:math' as math;

import 'package:dash_watch_protocol/dash_watch_protocol.dart';

/// Where the watch's live numbers come from.
///
/// An interface rather than wiring the phone relay straight into the widgets,
/// because three different sources are expected over this app's life and the UI
/// must not care which is active:
///
///  * [FakeRunStatsSource] — synthetic data. Lets the real screens be built and
///    judged on a real wrist with no pairing, no Bluetooth and no phone in the
///    room.
///  * a phone-relay source (companion mode) reading the Wearable Data Layer.
///  * a local-GPS source for standalone "leave the phone at home" recording.
///
/// The last two produce identical `RunStats`, so every screen written against
/// this interface works unchanged in both modes.
abstract class RunStatsSource {
  /// Live snapshots. Emits on every meaningful change, not on a fixed clock.
  Stream<RunStats> get stats;

  /// The most recent snapshot, for building before the first event arrives.
  RunStats get current;

  /// Asks the session to change state. Named `send` rather than `start`/`pause`
  /// because in companion mode the watch never *performs* the action — the
  /// phone owns the session and may refuse or ignore the request.
  Future<void> send(WatchCommand command);

  /// Clears a finished run's summary and returns the watch to idle.
  ///
  /// Only meaningful for a run the watch recorded itself: a phone-owned run's
  /// summary clears when the phone says so. Defaults to doing nothing so
  /// sources that never show a lingering summary need not implement it.
  void dismissSummary() {}

  void dispose();
}

/// A plausible run, synthesised on the watch.
///
/// Deliberately not a smooth ramp: pace drifts, heart rate wanders and lags
/// effort, and loops close at irregular intervals — a perfectly linear fake
/// makes layouts look good that fall apart on real data (a pace of "12:07"
/// is wider than "5:31", four-digit heart rates never happen but three-digit
/// ones do, and area readings gain digits as a run goes on).
class FakeRunStatsSource implements RunStatsSource {
  static const Duration _tick = Duration(milliseconds: 500);

  final _controller = StreamController<RunStats>.broadcast();
  final _random = math.Random(7); // fixed seed: reproducible demos
  Timer? _timer;

  RunStats _current = RunStats.idle;
  double _paceTarget = 5.4;
  double _heartRate = 96;
  int _ticksSinceLoop = 0;

  @override
  Stream<RunStats> get stats => _controller.stream;

  @override
  RunStats get current => _current;

  @override
  Future<void> send(WatchCommand command) async {
    switch (command) {
      case WatchCommand.start:
        _current = const RunStats(phase: RunPhase.countdown, countdownValue: 5);
        _startTicking();
      case WatchCommand.pause:
        _current = _current.copyWith(phase: RunPhase.paused);
      case WatchCommand.resume:
        _current = _current.copyWith(phase: RunPhase.running);
      case WatchCommand.finish:
        _timer?.cancel();
        _timer = null;
        _current = _current.copyWith(phase: RunPhase.finished);
    }
    _emit();
  }

  void _startTicking() {
    _timer?.cancel();
    _timer = Timer.periodic(_tick, (_) => _advance());
  }

  void _advance() {
    switch (_current.phase) {
      case RunPhase.countdown:
        // Two ticks per second, so only count down on alternate ones.
        final next = _current.countdownValue - 1;
        if (next <= 0) {
          _current = const RunStats(phase: RunPhase.running);
        } else {
          _current = _current.copyWith(countdownValue: next);
        }
      case RunPhase.running:
        _advanceRun();
      case RunPhase.idle:
      case RunPhase.paused:
      case RunPhase.finished:
        return; // clock stopped; nothing moves
    }
    _emit();
  }

  void _advanceRun() {
    final elapsed = _current.elapsed + _tick;

    // Pace wanders around a slowly-moving target rather than sitting still.
    _paceTarget += (_random.nextDouble() - 0.5) * 0.06;
    _paceTarget = _paceTarget.clamp(4.2, 7.5);
    final pace = _paceTarget + (_random.nextDouble() - 0.5) * 0.15;

    // Distance from pace, so the two can never disagree on screen.
    final metresThisTick = (_tick.inMilliseconds / 1000) / (pace * 60) * 1000;

    // Heart rate chases effort with a lag, the way a real sensor does.
    _heartRate += ((190 - pace * 18) - _heartRate) * 0.04 +
        (_random.nextDouble() - 0.5) * 1.5;
    _heartRate = _heartRate.clamp(70, 195);

    _ticksSinceLoop++;
    var loops = _current.loopsCompleted;
    var area = _current.claimedAreaM2;
    // A loop every ~40-70s, which is unrealistically often for a real run but
    // exercises the territory screen without waiting around.
    if (_ticksSinceLoop > 80 + _random.nextInt(60)) {
      _ticksSinceLoop = 0;
      loops += 1;
      area += 12000 + _random.nextDouble() * 90000;
    }

    _current = _current.copyWith(
      elapsed: elapsed,
      distanceMeters: _current.distanceMeters + metresThisTick,
      paceMinPerKm: pace,
      heartRateBpm: _heartRate.round(),
      loopsCompleted: loops,
      claimedAreaM2: area,
      guidance: _fakeGuidance(elapsed),
    );
  }

  /// A route that turns every so often and briefly strays off course, so the
  /// arrow, the turn countdown and the off-route state all get exercised
  /// without needing a real planned route.
  WatchGuidance _fakeGuidance(Duration elapsed) {
    final seconds = elapsed.inMilliseconds / 1000;
    final bearing = (seconds * 2.5) % 360;
    final cycle = seconds % 90;

    return WatchGuidance(
      targetBearingDegrees: bearing,
      headingDegrees: (bearing - 18 + math.sin(seconds / 3) * 12) % 360,
      // Off route for a 6-second window each cycle.
      isOffRoute: cycle > 62 && cycle < 68,
      distanceToTurnMeters: cycle < 45 ? 220 - cycle * 4.5 : null,
      turnAngleDegrees: cycle < 45 ? -82 : null,
      distanceRemainingMeters:
          math.max(0, 5200 - _current.distanceMeters).toDouble(),
    );
  }

  void _emit() {
    if (!_controller.isClosed) _controller.add(_current);
  }

  /// Nothing to dismiss: this source never shows a summary the watch
  /// itself owns.
  @override
  void dismissSummary() {}

  @override
  void dispose() {
    _timer?.cancel();
    _controller.close();
  }
}
