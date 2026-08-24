import 'dart:async';
import 'dart:convert';

import 'package:dash_watch_protocol/dash_watch_protocol.dart';
import 'package:flutter/foundation.dart';

import 'phone_relay_stats_source.dart';
import 'run_foreground_service.dart';
import 'run_stats_source.dart';
import 'standalone_recorder.dart';

/// Decides, once per run, whether the phone or the watch is recording — and
/// presents either as the same [RunStatsSource] so no screen has to know which.
///
/// The mode is fixed at START and never changes mid-run. A run that switched
/// owner halfway would have two partial breadcrumb trails and no honest way to
/// stitch them, so the decision is made once, on whether a phone answers.
///
/// | Started on | Records | Watch role |
/// |---|---|---|
/// | Phone | Phone | Display |
/// | Watch, phone reachable | Phone | Display |
/// | Watch, no phone | **Watch** | Records, syncs later |
/// Where a finished standalone run has got to on its way to the phone.
enum RunSendState { idle, sending, sent, failed }

class WatchRunCoordinator implements RunStatsSource {
  WatchRunCoordinator({
    required PhoneRelayStatsSource relay,
    StandaloneRecorder? recorder,
  })  : _relay = relay,
        _recorder = recorder ?? StandaloneRecorder();

  final PhoneRelayStatsSource _relay;
  final StandaloneRecorder _recorder;

  final _controller = StreamController<RunStats>.broadcast();
  StreamSubscription<RunStats>? _relaySub;
  StreamSubscription<void>? _ackSub;
  Timer? _localTicker;
  Timer? _countdownTimer;

  bool _standalone = false;
  RunStats _local = RunStats.idle;

  /// True while this watch is recording the run itself.
  bool get isStandalone => _standalone;

  @override
  Stream<RunStats> get stats => _controller.stream;

  @override
  RunStats get current => _standalone ? _local : _relay.current;

  Future<void> start() async {
    await _relay.start();
    // While the phone owns the run its snapshots pass straight through.
    // Only once the phone says it has the run does the watch's copy go.
    _ackSub = _relay.runAcks.listen((_) async {
      debugPrint('WatchRunCoordinator: phone stored the run — clearing local copy');
      await StandaloneRecorder.clearPending();
    });

    // Retries only a run that was already sent and never acknowledged — the
    // phone was out of range, or died mid-import. A run the runner has not
    // chosen to send yet is left alone.
    unawaited(_retryUnacknowledgedRun());

    _relaySub = _relay.stats.listen((stats) {
      if (_standalone) {
        final phoneIsBusy = stats.phase == RunPhase.running ||
            stats.phase == RunPhase.countdown ||
            stats.phase == RunPhase.paused;
        if (!phoneIsBusy) return;

        // The phone outranks the watch whenever it is actually running a
        // session, in two situations:
        //
        //  * the local run is over and its summary is still up — otherwise the
        //    watch sits on an old recap and never shows the new run at all;
        //  * the local run only just began, because both devices were asked to
        //    start and the phone won the race. Recording the same run twice
        //    would claim the same ground twice.
        //
        // A local run past [_yieldWindow] is left alone: by then it is a real
        // run of its own, not a duplicate of what the phone is doing.
        final justStarted = _recorder.elapsed < _yieldWindow;
        if (_local.phase == RunPhase.finished) {
          // Display-only handover. The finished run is real, recorded, and not
          // yet delivered — the phone starting something unrelated must never
          // destroy it. Deleting here lost a completed run outright.
          _standalone = false;
          _local = RunStats.idle;
        } else if (justStarted) {
          unawaited(_yieldToPhone());
        } else {
          return;
        }
      }
      if (!_controller.isClosed) _controller.add(stats);
    });
  }

  /// Heart rate has to reach *both* paths.
  ///
  /// The relay forwards it to the phone during a companion run. But a
  /// standalone run has no phone to echo it back, so the coordinator also keeps
  /// its own copy — without this the watch showed "--" for an entire phone-free
  /// run even though the sensor was reading perfectly well, and the imported
  /// run carried no heart rate at all.
  void attachHeartRate(Stream<HeartRateReading> readings) {
    _relay.attachHeartRate(readings);
    _heartRateSub = readings.listen((reading) {
      _heartRate = reading;
      // Carried into the recorded file so the phone stores avg/max on import.
      _recorder.setHeartRate(
        average: reading.averageBpm,
        max: reading.maxBpm,
      );
      if (_standalone && _local.phase == RunPhase.running) {
        _emitLocal(phase: _local.phase);
      }
    });
  }

  HeartRateReading _heartRate = const HeartRateReading();
  StreamSubscription<HeartRateReading>? _heartRateSub;

  @override
  Future<void> send(WatchCommand command) async {
    if (command == WatchCommand.start && !_standalone) {
      // Ask the phone *and* start recording locally, rather than choosing up
      // front on whether a phone once answered.
      //
      // `isConnected` only means "a message arrived at some point since this
      // app opened", and it never goes false again. Deciding on it left the
      // watch waiting forever on a phone that was backgrounded or asleep and
      // could not act — the phone cannot start a run it is not visible for,
      // since Android refuses a background foreground-service start.
      //
      // So the local countdown doubles as the grace period. If the phone comes
      // back with a live run during it, [_yieldToPhone] abandons the local one;
      // otherwise the watch simply carries on and records.
      await _relay.send(command);
      await _beginStandalone();
      return;
    }

    if (!_standalone) return _relay.send(command);

    switch (command) {
      case WatchCommand.pause:
        await _recorder.pause();
        _emitLocal(phase: RunPhase.paused);
      case WatchCommand.resume:
        await _recorder.resume();
        _emitLocal(phase: RunPhase.running);
      case WatchCommand.finish:
        await _endStandalone();
      case WatchCommand.start:
        break;
    }
  }

  /// Queues the finished run for the phone.
  ///
  /// Sent even when no phone is currently in range — that is the whole reason
  /// this uses a DataItem rather than a message. It sits in the Data Layer and
  /// syncs itself when the two devices next meet, which for a run that started
  /// with the phone at home may be an hour later.
  ///
  /// The local file is deliberately *not* deleted here. It goes only when the
  /// phone acknowledges storing the run, so a transfer that fails halfway
  /// costs nothing.
  Future<void> _retryUnacknowledgedRun() async {
    if (!await StandaloneRecorder.wasSent()) return;
    debugPrint('WatchRunCoordinator: retrying an unacknowledged run');
    await _handOffToPhone();
  }

  Future<bool> _handOffToPhone() async {
    final pending = await StandaloneRecorder.readPending();
    if (pending == null) {
      debugPrint('WatchRunCoordinator: nothing on disk to hand off');
      return false;
    }
    final queued = await _relay.sendStandaloneRun(jsonEncode(pending));
    debugPrint('WatchRunCoordinator: run queued for phone = $queued');
    if (queued) await StandaloneRecorder.markSent();
    return queued;
  }

  /// Sends the finished run to the phone, on the runner's say-so.
  ///
  /// Explicit rather than automatic at finish: the transfer is invisible and
  /// slow, and a runner who has just stopped should be told it happened rather
  /// than left guessing. [sendState] drives the button's label.
  Future<void> sendPendingRun() async {
    if (_sendState == RunSendState.sending ||
        _sendState == RunSendState.sent) {
      return;
    }
    _setSendState(RunSendState.sending);
    final queued = await _handOffToPhone();
    _setSendState(queued ? RunSendState.sent : RunSendState.failed);
  }

  RunSendState get sendState => _sendState;
  RunSendState _sendState = RunSendState.idle;

  final _sendStateController = StreamController<RunSendState>.broadcast();
  Stream<RunSendState> get sendStates => _sendStateController.stream;

  void _setSendState(RunSendState state) {
    _sendState = state;
    if (!_sendStateController.isClosed) _sendStateController.add(state);
  }

  /// How long after starting locally the phone may still claim the run. Long
  /// enough for the phone to acquire a GPS fix and begin its own countdown,
  /// short enough that a genuine standalone run is never yanked away.
  static const Duration _yieldWindow = Duration(seconds: 20);

  /// Abandons a local recording because the phone won the start race.
  ///
  /// **Only ever called for a run seconds old.** The few seconds recorded here
  /// duplicate what the phone is now recording, so importing both would claim
  /// the same ground twice. A *finished* run is never routed here — it is real
  /// data that has not reached the phone yet, and discarding it loses the run.
  Future<void> _yieldToPhone() async {
    debugPrint('WatchRunCoordinator: phone took the run — dropping local copy');
    _localTicker?.cancel();
    _localTicker = null;
    _countdownTimer?.cancel();
    _countdownTimer = null;
    await _recorder.stop();
    await RunForegroundService.stop();
    await StandaloneRecorder.clearPending();
    _standalone = false;
    _local = RunStats.idle;
  }

  /// Drops a finished standalone summary and returns to idle.
  ///
  /// The recorded run is deliberately left on disk — this clears the screen,
  /// not the run. It stays there until a phone confirms it has stored it.
  @override
  void dismissSummary() {
    if (!_standalone || _local.phase != RunPhase.finished) return;
    _standalone = false;
    _local = RunStats.idle;
    if (!_controller.isClosed) _controller.add(_local);
  }

  Future<void> _beginStandalone() async {
    debugPrint('WatchRunCoordinator: no phone — recording on the watch');
    _standalone = true;

    // Started *before* the countdown, not after. Wear OS drops the app to the
    // background within a few seconds of the wrist lowering, and a backgrounded
    // Flutter engine has its timers throttled — so a countdown started without
    // the service simply never finishes, and the run never begins. The service
    // has to exist first to keep the process alive through it.
    //
    // It must also be started while the app is still visible: Android 12+
    // refuses a background start, and by the time the countdown ended the app
    // may no longer qualify.
    await RunForegroundService.start(
      title: 'Starting run',
      body: 'Phone not connected',
    );

    // Same 5-second countdown as the phone, so a run feels identical wherever
    // it was started.
    var remaining = 5;
    _emitLocal(phase: RunPhase.countdown, countdown: remaining);
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) async {
      remaining--;
      if (remaining > 0) {
        _emitLocal(phase: RunPhase.countdown, countdown: remaining);
        return;
      }
      timer.cancel();
      _countdownTimer = null;

      final started = await _recorder.start();
      if (!started) {
        // Location refused or switched off — better to fall back to idle than
        // to sit showing a ticking clock over a run recording nothing.
        _standalone = false;
        await RunForegroundService.stop();
        _emitLocal(phase: RunPhase.idle);
        return;
      }

      await RunForegroundService.update(
        title: 'Recording run',
        body: 'Phone not connected',
      );
      _startLocalTicker();
      _emitLocal(phase: RunPhase.running);
    });
  }

  Future<void> _endStandalone() async {
    _localTicker?.cancel();
    _localTicker = null;
    _countdownTimer?.cancel();
    _countdownTimer = null;
    await _recorder.stop();
    await RunForegroundService.stop();
    // Stays standalone and finished: the run is on disk waiting for a phone,
    // and the summary on screen is the only record the runner can see until
    // then.
    _emitLocal(phase: RunPhase.finished);
  }

  void _startLocalTicker() {
    _localTicker?.cancel();
    _localTicker = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _emitLocal(phase: _local.phase),
    );
  }

  /// Builds a snapshot from the watch's own recording.
  ///
  /// Loops and claimed area are deliberately absent — they stay at 0 until the
  /// phone imports the run and computes them, because they decide territory
  /// and must be derived where the server can verify them. Showing a loop count
  /// here would be guessing at something that is not the watch's to decide.
  void _emitLocal({required RunPhase phase, int? countdown}) {
    final elapsed = _recorder.elapsed;
    final km = _recorder.distanceMeters / 1000;
    _local = RunStats(
      phase: phase,
      countdownValue: countdown ?? 0,
      elapsed: elapsed,
      distanceMeters: _recorder.distanceMeters,
      paceMinPerKm: km > 0.01 ? (elapsed.inSeconds / 60) / km : null,
      heartRateBpm: _heartRate.currentBpm,
      loopsCompleted: 0,
      claimedAreaM2: 0,
    );
    if (!_controller.isClosed) _controller.add(_local);
  }

  @override
  void dispose() {
    _localTicker?.cancel();
    _countdownTimer?.cancel();
    _relaySub?.cancel();
    _ackSub?.cancel();
    _heartRateSub?.cancel();
    _sendStateController.close();
    _relay.dispose();
    _controller.close();
  }
}
