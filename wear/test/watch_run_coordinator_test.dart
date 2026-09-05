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

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('dash_wear_test');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    // The relay and the foreground service are pure platform channels here.
    for (final channel in [wearChannel, runServiceChannel]) {
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'nodes' || call.method == 'getData') {
          return <Object?>[];
        }
        return null;
      });
    }
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
}

/// A recorder that never touches GPS. `WatchRunCoordinator` takes one by
/// constructor precisely so this is possible.
class _FakeRecorder extends StandaloneRecorder {
  Duration elapsedOverride = Duration.zero;
  bool stopped = false;

  @override
  Duration get elapsed => elapsedOverride;

  @override
  Future<bool> start() async => true;

  @override
  Future<void> stop() async {
    stopped = true;
  }

  @override
  Future<void> pause() async {}

  @override
  Future<void> resume() async {}
}
