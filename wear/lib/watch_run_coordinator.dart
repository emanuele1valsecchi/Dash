import 'dart:async';

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
    _relaySub = _relay.stats.listen((stats) {
      if (_standalone) return; // our own numbers win once recording locally
      if (!_controller.isClosed) _controller.add(stats);
    });
  }

  void attachHeartRate(Stream<HeartRateReading> readings) =>
      _relay.attachHeartRate(readings);

  @override
  Future<void> send(WatchCommand command) async {
    if (command == WatchCommand.start && !_standalone) {
      // The phone gets first refusal. Only if nothing answers does the watch
      // take the run on itself — the phone remains the better recorder when
      // present, since it owns the territory geometry either way.
      if (_relay.isConnected) return _relay.send(command);
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
      heartRateBpm: _local.heartRateBpm,
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
    _relay.dispose();
    _controller.close();
  }
}
