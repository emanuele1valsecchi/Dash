import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dash_watch_protocol/dash_watch_protocol.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dash_wear/phone_relay_stats_source.dart';
import 'package:dash_wear/standalone_recorder.dart';
import 'package:dash_wear/watch_run_coordinator.dart';

/// The watch's decision about *who is recording*.
///
/// This is the highest-stakes logic in the watch app and the first thing here
/// to get any tests. It has already been wrong once in a way that destroyed
/// data: a finished standalone run was being deleted when the phone started
/// something unrelated, which lost a real run the user had already done and
/// which had not yet reached the phone.
///
/// The three branches all look similar and mean very different things:
///
///  * a local run **seconds old** when the phone reports a live run is a
///    duplicate of it — importing both would claim the same ground twice, so
///    it is abandoned;
///  * a local run **past the yield window** is a genuine run of its own and is
///    left alone;
///  * a **finished** local run is real, recorded, undelivered data and must
///    survive regardless.
///
/// None of the three throws when it goes wrong.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const wearChannel = MethodChannel('dash/wear_bridge');
  const wearMessages = EventChannel('dash/wear_bridge/messages');
  const runServiceChannel = MethodChannel('dash/run_service');
  const pathProvider =
      MethodChannel('plugins.flutter.io/path_provider');

  late _FakeRecorder recorder;
  late PhoneRelayStatsSource relay;
  late WatchRunCoordinator coordinator;
  late Directory tempDir;
  late List<String> serviceCalls;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('dash_wear_test');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    // The relay and the foreground service are pure platform channels here.
    messenger.setMockMethodCallHandler(wearChannel, (call) async {
      if (call.method == 'nodes' || call.method == 'getData') {
        return <Object?>[];
      }
      return null;
    });
    // The service calls are recorded rather than discarded: *when* it starts
    // relative to the countdown is load-bearing, not incidental.
    serviceCalls = [];
    messenger.setMockMethodCallHandler(runServiceChannel, (call) async {
      serviceCalls.add(call.method);
      return null;
    });
    // `StandaloneRecorder`'s static pending-run helpers write real files.
    messenger.setMockMethodCallHandler(pathProvider, (call) async {
      return tempDir.path;
    });

    recorder = _FakeRecorder();
    relay = PhoneRelayStatsSource();
    coordinator = WatchRunCoordinator(relay: relay, recorder: recorder);
  });

  tearDown(() async {
    coordinator.dispose();
    relay.dispose();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final c in [wearChannel, runServiceChannel, pathProvider]) {
      messenger.setMockMethodCallHandler(c, null);
    }
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  /// `_yieldToPhone` is fired with `unawaited` and awaits the recorder, the
  /// foreground service and a file delete before it flips `_standalone`, so a
  /// single event-loop turn is not enough to observe the result.
  Future<void> settle() async {
    for (var i = 0; i < 12; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// Delivers one message as if the phone had sent it.
  Future<void> fromPhone(RunStats stats) async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      wearMessages.name,
      const StandardMethodCodec().encodeSuccessEnvelope(<String, Object?>{
        'path': WearPaths.stats,
        'payload': jsonEncode(stats.toJson()),
      }),
      (_) {},
    );
    await settle();
  }

  group('starting a run from the watch', () {
    test('records locally rather than waiting on a phone that may be asleep',
        () async {
      // `isConnected` only means "a message arrived at some point"; deciding
      // on it left the watch waiting forever on a backgrounded phone that
      // cannot legally start a foreground service.
      await coordinator.start();
      await coordinator.send(WatchCommand.start);

      expect(coordinator.isStandalone, isTrue);
    });

    test('still asks the phone, so it can win the race', () async {
      await coordinator.start();
      await coordinator.send(WatchCommand.start);

      // Both happen: the phone is asked *and* the watch begins recording.
      expect(coordinator.isStandalone, isTrue);
    });
  });

  group('when the phone reports a live run', () {
    test('a just-started local run is abandoned, so ground is not claimed twice',
        () async {
      await coordinator.start();
      await coordinator.send(WatchCommand.start);
      expect(coordinator.isStandalone, isTrue);

      recorder.elapsedOverride = const Duration(seconds: 2);
      await fromPhone(const RunStats(phase: RunPhase.running));

      expect(coordinator.isStandalone, isFalse,
          reason: 'the phone won the start race');
      expect(recorder.stopped, isTrue);
    });

    test('a local run past the yield window is left alone', () async {
      // By then it is a real run of its own, not a duplicate of the phone's.
      await coordinator.start();
      await coordinator.send(WatchCommand.start);

      recorder.elapsedOverride = const Duration(minutes: 5);
      await fromPhone(const RunStats(phase: RunPhase.running));

      expect(coordinator.isStandalone, isTrue,
          reason: 'a five-minute run must not be thrown away');
      expect(recorder.stopped, isFalse);
    });

    test('an idle phone never takes over', () async {
      // Only a phone that is actually running, counting down or paused
      // outranks the watch.
      await coordinator.start();
      await coordinator.send(WatchCommand.start);

      recorder.elapsedOverride = const Duration(seconds: 2);
      await fromPhone(const RunStats(phase: RunPhase.idle));

      expect(coordinator.isStandalone, isTrue);
      expect(recorder.stopped, isFalse);
    });
  });

  group('a finished standalone run', () {
    /// The file `StandaloneRecorder` leaves on disk for the phone to pick up.
    /// This is the thing that actually gets destroyed, so it is what the
    /// assertion has to read — an earlier version of this test watched a flag
    /// on the fake recorder, which `clearPending()` (a *static*) never
    /// touches, so it passed with the regression reinstated.
    File pendingRun() => File('${tempDir.path}/standalone_run.json');

    test('survives the phone starting something unrelated', () async {
      // The regression that lost a real run. The handover is display-only:
      // the recorded data must not be discarded, because it has not reached
      // the phone yet.
      await coordinator.start();
      await coordinator.send(WatchCommand.start);
      recorder.elapsedOverride = const Duration(minutes: 5);
      await coordinator.send(WatchCommand.finish);
      await settle();

      // Stand in for what a real recording leaves behind; the fake recorder
      // deliberately does no file I/O of its own.
      await pendingRun().writeAsString('{"fixes":[]}');

      await fromPhone(const RunStats(phase: RunPhase.running));

      expect(coordinator.isStandalone, isFalse,
          reason: 'the display hands over to the phone');
      expect(await pendingRun().exists(), isTrue,
          reason: 'the undelivered run must still be on disk');
    });

    test('a just-started run being abandoned DOES clear the pending file',
        () async {
      // The mirror image, and what makes the test above meaningful: the
      // yield path is supposed to delete, so "the file survives" is a real
      // distinction rather than something that is always true here.
      await coordinator.start();
      await coordinator.send(WatchCommand.start);
      recorder.elapsedOverride = const Duration(seconds: 2);
      await pendingRun().writeAsString('{"fixes":[]}');

      await fromPhone(const RunStats(phase: RunPhase.running));

      expect(coordinator.isStandalone, isFalse);
      expect(await pendingRun().exists(), isFalse,
          reason: 'a duplicate of the phone run should be cleaned up');
    });
  });

  group('which stats are shown', () {
    test('the relay is the source while the phone owns the run', () async {
      await coordinator.start();

      await fromPhone(const RunStats(
          phase: RunPhase.running, distanceMeters: 1234));

      expect(coordinator.isStandalone, isFalse);
      expect(coordinator.current.distanceMeters, 1234);
    });
  });

  // ── Handing a finished run to the phone ───────────────────────────────────
  //
  // The most consequential thing the watch does. A standalone run exists only
  // as a file on the watch until the phone acknowledges it, so the states here
  // decide whether a real run is kept, retried, or quietly lost.

  /// Writes a finished run to the pending file, as a real standalone run
  /// would have left behind.
  Future<void> writePendingRun({bool alreadySent = false}) async {
    final file = File('${tempDir.path}/standalone_run.json');
    await file.writeAsString(jsonEncode({
      'startedAt': DateTime.now().millisecondsSinceEpoch,
      'durationMs': 1800000,
      'distanceMeters': 5000.0,
      'fixes': <Object?>[],
      if (alreadySent) 'sentAt': DateTime.now().millisecondsSinceEpoch,
    }));
  }

  bool pendingFileExists() =>
      File('${tempDir.path}/standalone_run.json').existsSync();

  Map<String, Object?> pendingFile() => (jsonDecode(
        File('${tempDir.path}/standalone_run.json').readAsStringSync(),
      ) as Map)
          .cast<String, Object?>();

  /// Decides whether the Data Layer accepts the run.
  ///
  /// A refusal throws rather than returning false: `sendStandaloneRun`
  /// discards `putData`'s return value and reports failure only from the
  /// exception, which is how the platform actually signals an unreachable
  /// phone.
  void phoneAccepts(bool accepted) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(wearChannel, (call) async {
      if (call.method == 'nodes' || call.method == 'getData') {
        return <Object?>[];
      }
      if (call.method == 'putData') {
        if (!accepted) {
          throw PlatformException(code: 'unavailable', message: 'no node');
        }
        return true;
      }
      return null;
    });
  }

  group('handing a finished run to the phone', () {
    test('does nothing when there is no run on disk', () async {
      phoneAccepts(true);

      await coordinator.sendPendingRun();

      expect(coordinator.sendState, RunSendState.failed,
          reason: 'nothing was handed over, so nothing succeeded');
    });

    test('is marked sent once the phone has queued it', () async {
      // `sentAt` is what makes the run eligible for an automatic retry later;
      // without it an unacknowledged run is never chased.
      await writePendingRun();
      phoneAccepts(true);

      await coordinator.sendPendingRun();

      expect(coordinator.sendState, RunSendState.sent);
      expect(pendingFile()['sentAt'], isNotNull);
    });

    test('the file survives being sent', () async {
      // Deleting on send rather than on acknowledgement would lose the run
      // whenever a transfer failed halfway.
      await writePendingRun();
      phoneAccepts(true);

      await coordinator.sendPendingRun();

      expect(pendingFileExists(), isTrue);
    });

    test('a refused hand-off is reported, and the run is not marked sent',
        () async {
      // Out of range, or the phone app not installed. Marking it sent would
      // make the retry think it had already gone.
      await writePendingRun();
      phoneAccepts(false);

      await coordinator.sendPendingRun();

      expect(coordinator.sendState, RunSendState.failed);
      expect(pendingFile()['sentAt'], isNull);
      expect(pendingFileExists(), isTrue);
    });

    test('a failed send can be tried again', () async {
      // `failed` is not a terminal state — the runner walks back into range
      // and taps again.
      await writePendingRun();
      phoneAccepts(false);
      await coordinator.sendPendingRun();
      expect(coordinator.sendState, RunSendState.failed);

      phoneAccepts(true);
      await coordinator.sendPendingRun();

      expect(coordinator.sendState, RunSendState.sent);
    });

    test('a run already sent is not sent twice', () async {
      // The transfer is invisible and slow; a second tap on a button that has
      // already succeeded should do nothing rather than duplicate the run.
      await writePendingRun();
      phoneAccepts(true);
      await coordinator.sendPendingRun();

      var puts = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(wearChannel, (call) async {
        if (call.method == 'putData') puts++;
        return call.method == 'putData' ? true : <Object?>[];
      });
      await coordinator.sendPendingRun();

      expect(puts, 0);
    });

    test('the send state is published, so the button can follow it', () async {
      // The screen shows "Send", "Sending…", "Sent" off this stream.
      await writePendingRun();
      phoneAccepts(true);
      final seen = <RunSendState>[];
      final sub = coordinator.sendStates.listen(seen.add);

      await coordinator.sendPendingRun();
      // The controller is a broadcast stream, so the last event is delivered
      // a turn later than the call that produced it.
      await settle();
      await sub.cancel();

      expect(seen, [RunSendState.sending, RunSendState.sent]);
    });

    test('a refusal ends in failed, not stuck sending', () async {
      await writePendingRun();
      phoneAccepts(false);
      final seen = <RunSendState>[];
      final sub = coordinator.sendStates.listen(seen.add);

      await coordinator.sendPendingRun();
      await settle();
      await sub.cancel();

      expect(seen.last, RunSendState.failed);
    });
  });

  group('heart rate', () {
    test('reaches the recorder, which is what writes it into the run',
        () async {
      // Only the watch can measure this. If it does not reach the recorder it
      // never reaches the file, and the phone has nothing to import.
      final readings = StreamController<HeartRateReading>.broadcast();
      addTearDown(readings.close);
      coordinator.attachHeartRate(readings.stream);

      readings.add(const HeartRateReading(
          currentBpm: 150, averageBpm: 142, maxBpm: 175));
      await settle();

      expect(recorder.avgHeartRate, 142);
      expect(recorder.maxHeartRate, 175);
    });

    test('the latest reading wins', () async {
      final readings = StreamController<HeartRateReading>.broadcast();
      addTearDown(readings.close);
      coordinator.attachHeartRate(readings.stream);

      readings.add(const HeartRateReading(
          currentBpm: 120, averageBpm: 118, maxBpm: 130));
      await settle();
      readings.add(const HeartRateReading(
          currentBpm: 160, averageBpm: 145, maxBpm: 178));
      await settle();

      expect(recorder.avgHeartRate, 145);
      expect(recorder.maxHeartRate, 178);
    });
  });

  // ── Starting a run with no phone ──────────────────────────────────────────
  //
  // `testWidgets` rather than `test`, for the clock: the countdown is a
  // `Timer.periodic` and only a widget binding gives a fake one that can be
  // wound forward without waiting five real seconds.

  group('the pre-run countdown', () {
    /// Asks for a run and lets the countdown run to completion.
    Future<void> startAndCountDown(WidgetTester tester,
        {int seconds = 6}) async {
      await coordinator.send(WatchCommand.start);
      for (var i = 0; i < seconds; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      // `pump`, not the `settle` helper the plain tests use: inside
      // `testWidgets` the clock is fake, so an awaited `Future.delayed` never
      // fires unless the test advances it — and waiting on one hangs.
      await tester.pump();
    }

    testWidgets('the foreground service starts before the counting does',
        (tester) async {
      // Load-bearing ordering, not tidiness. Wear OS backgrounds the app
      // within seconds of the wrist lowering, and a backgrounded Flutter
      // engine has its timers throttled — a countdown begun without the
      // service simply never finishes and the run never starts. Android 12+
      // also refuses a background service start, so it has to happen while
      // the app is still visible.
      await coordinator.send(WatchCommand.start);

      expect(serviceCalls.first, 'start');
      expect(coordinator.current.phase, RunPhase.countdown);
      // Cancels the countdown or the run ticker. A body that ends
      // with a periodic timer still pending fails the test, and a
      // tearDown runs after that check rather than before it.
      coordinator.dispose();
    });

    testWidgets('counts down from five', (tester) async {
      await coordinator.send(WatchCommand.start);

      expect(coordinator.current.countdownValue, 5);
      await tester.pump(const Duration(seconds: 1));
      expect(coordinator.current.countdownValue, 4);
      await tester.pump(const Duration(seconds: 1));
      expect(coordinator.current.countdownValue, 3);
      // Cancels the countdown or the run ticker. A body that ends
      // with a periodic timer still pending fails the test, and a
      // tearDown runs after that check rather than before it.
      coordinator.dispose();
    });

    testWidgets('recording begins when it reaches zero', (tester) async {
      await startAndCountDown(tester);

      expect(coordinator.current.phase, RunPhase.running);
      expect(coordinator.isStandalone, isTrue);
      // Cancels the countdown or the run ticker. A body that ends
      // with a periodic timer still pending fails the test, and a
      // tearDown runs after that check rather than before it.
      coordinator.dispose();
    });

    testWidgets('the service is told the run is under way', (tester) async {
      // The notification text changes from "Starting run" to "Recording run";
      // leaving it on the former is the visible symptom of a countdown that
      // never completed.
      await startAndCountDown(tester);

      expect(serviceCalls, contains('update'));
      // Cancels the countdown or the run ticker. A body that ends
      // with a periodic timer still pending fails the test, and a
      // tearDown runs after that check rather than before it.
      coordinator.dispose();
    });

    testWidgets('the phone is asked too, so it can win the race',
        (tester) async {
      // The local countdown doubles as the grace period — deciding up front
      // on whether a phone once answered left the watch waiting forever on a
      // phone that was asleep.
      await coordinator.send(WatchCommand.start);

      expect(coordinator.current.phase, RunPhase.countdown);
      // Cancels the countdown or the run ticker. A body that ends
      // with a periodic timer still pending fails the test, and a
      // tearDown runs after that check rather than before it.
      coordinator.dispose();
    });

    group('when location is unavailable', () {
      testWidgets('it falls back to idle rather than ticking over nothing',
          (tester) async {
        // A clock counting up over a recorder that captured no fixes is worse
        // than no run at all: it looks like a run right up until the moment
        // the runner tries to save it.
        recorder.startResult = false;

        await startAndCountDown(tester);

        expect(coordinator.current.phase, RunPhase.idle);
        coordinator.dispose();
      });

      testWidgets('the watch does not stay in standalone mode',
          (tester) async {
        // Otherwise the phone can never take the next run.
        recorder.startResult = false;

        await startAndCountDown(tester);

        expect(coordinator.isStandalone, isFalse);
        coordinator.dispose();
      });

      testWidgets('the foreground service is stopped again', (tester) async {
        // It was started before the countdown; leaving it running would pin a
        // notification over a run that does not exist.
        recorder.startResult = false;

        await startAndCountDown(tester);

        expect(serviceCalls, contains('stop'));
        coordinator.dispose();
      });
    });
  });

  group('controlling a standalone run', () {
    Future<void> beginRun(WidgetTester tester) async {
      await coordinator.send(WatchCommand.start);
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      await tester.pump();
    }

    testWidgets('pausing pauses the recorder, not just the display',
        (tester) async {
      // The clock stopping is cosmetic; if the GPS stream keeps running the
      // pause adds distance the runner did not cover.
      await beginRun(tester);

      await coordinator.send(WatchCommand.pause);

      expect(recorder.paused, isTrue);
      expect(coordinator.current.phase, RunPhase.paused);
      // Cancels the countdown or the run ticker. A body that ends
      // with a periodic timer still pending fails the test, and a
      // tearDown runs after that check rather than before it.
      coordinator.dispose();
    });

    testWidgets('resuming resumes it', (tester) async {
      await beginRun(tester);
      await coordinator.send(WatchCommand.pause);

      await coordinator.send(WatchCommand.resume);

      expect(recorder.resumed, isTrue);
      expect(coordinator.current.phase, RunPhase.running);
      // Cancels the countdown or the run ticker. A body that ends
      // with a periodic timer still pending fails the test, and a
      // tearDown runs after that check rather than before it.
      coordinator.dispose();
    });

    testWidgets('a second start while already recording is ignored',
        (tester) async {
      // The start button is gone by then, but a queued command from the phone
      // could still arrive — restarting would discard the run in progress.
      await beginRun(tester);
      final before = coordinator.current.phase;

      await coordinator.send(WatchCommand.start);

      expect(coordinator.current.phase, before);
      expect(recorder.stopped, isFalse);
      // Cancels the countdown or the run ticker. A body that ends
      // with a periodic timer still pending fails the test, and a
      // tearDown runs after that check rather than before it.
      coordinator.dispose();
    });
  });
}

/// A recorder that never touches GPS. `WatchRunCoordinator` takes one by
/// constructor precisely so this is possible.
class _FakeRecorder extends StandaloneRecorder {
  Duration elapsedOverride = Duration.zero;
  bool stopped = false;
  int? avgHeartRate;
  int? maxHeartRate;

  @override
  void setHeartRate({int? average, int? max}) {
    avgHeartRate = average;
    maxHeartRate = max;
  }

  @override
  Duration get elapsed => elapsedOverride;

  /// Whether the watch's GPS is available. False is a real state — location
  /// switched off, or permission refused — and the coordinator has to fall
  /// back rather than tick over a run recording nothing.
  bool startResult = true;
  bool paused = false;
  bool resumed = false;

  @override
  Future<bool> start() async => startResult;

  @override
  Future<void> stop() async {
    stopped = true;
  }

  @override
  Future<void> pause() async => paused = true;

  @override
  Future<void> resume() async => resumed = true;
}
