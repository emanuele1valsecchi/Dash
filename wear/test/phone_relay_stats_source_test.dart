import 'dart:convert';

import 'package:dash_watch_protocol/dash_watch_protocol.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dash_wear/phone_relay_stats_source.dart';

/// The link to the phone, seen from the watch.
///
/// Everything arriving here came over Bluetooth from another device, so the
/// interesting cases are the ones where it arrives wrong: a message for
/// another path, a payload that will not decode, nothing at all. None of them
/// may take the watch down or blank a run in progress — the runner is
/// mid-workout and cannot do anything about it either way.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const wearChannel = MethodChannel('dash/wear_bridge');
  const wearMessages = EventChannel('dash/wear_bridge/messages');

  late PhoneRelayStatsSource relay;
  late List<String> sentPaths;

  setUp(() async {
    sentPaths = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(wearChannel, (call) async {
      if (call.method == 'send') {
        sentPaths.add((call.arguments as Map)['path'] as String);
      }
      if (call.method == 'nodes' || call.method == 'getData') {
        return <Object?>[];
      }
      return null;
    });
    relay = PhoneRelayStatsSource();
    await relay.start();
  });

  tearDown(() {
    relay.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(wearChannel, null);
  });

  /// Delivers one raw message as the platform would.
  Future<void> deliver(Object? message) async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      wearMessages.name,
      const StandardMethodCodec().encodeSuccessEnvelope(message),
      (_) {},
    );
    // The broadcast stream hands the decoded value on a later turn.
    for (var i = 0; i < 4; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<void> deliverStats(RunStats stats) => deliver(<String, Object?>{
        'path': WearPaths.stats,
        'payload': jsonEncode(stats.toJson()),
      });

  group('before the phone has said anything', () {
    test('it does not claim to be connected', () async {
      // "No phone here" and "the phone says the run is idle" look identical
      // on screen and mean very different things at a start line.
      expect(relay.isConnected, isFalse);
    });

    test('it shows an idle run rather than nothing', () async {
      expect(relay.current.phase, RunPhase.idle);
    });

    test('it asks the phone for a snapshot on connect', () async {
      expect(sentPaths, contains(WearPaths.requestSync));
    });
  });

  group('a stats message', () {
    test('becomes the current reading', () async {
      await deliverStats(const RunStats(
          phase: RunPhase.running, distanceMeters: 1234, loopsCompleted: 2));

      expect(relay.current.distanceMeters, 1234);
      expect(relay.current.loopsCompleted, 2);
      expect(relay.current.phase, RunPhase.running);
    });

    test('marks the phone as heard from', () async {
      await deliverStats(const RunStats(phase: RunPhase.idle));

      expect(relay.isConnected, isTrue);
    });

    test('is published to whoever is listening', () async {
      final seen = <RunStats>[];
      final sub = relay.stats.listen(seen.add);

      await deliverStats(const RunStats(
          phase: RunPhase.running, distanceMeters: 500));
      await sub.cancel();

      expect(seen.single.distanceMeters, 500);
    });

    test('a later one replaces the earlier', () async {
      await deliverStats(
          const RunStats(phase: RunPhase.running, distanceMeters: 100));
      await deliverStats(
          const RunStats(phase: RunPhase.running, distanceMeters: 900));

      expect(relay.current.distanceMeters, 900);
    });
  });

  group('messages that arrive wrong', () {
    test('an undecodable payload leaves the last good reading up', () async {
      // Mid-run, the previous number is far better than a blank: it is a few
      // seconds stale, where a blank looks like the run has stopped.
      await deliverStats(
          const RunStats(phase: RunPhase.running, distanceMeters: 1234));

      await deliver(<String, Object?>{
        'path': WearPaths.stats,
        'payload': 'not json at all',
      });

      expect(relay.current.distanceMeters, 1234);
    });

    test('a message with no payload is ignored', () async {
      await deliverStats(
          const RunStats(phase: RunPhase.running, distanceMeters: 1234));

      await deliver(<String, Object?>{'path': WearPaths.stats});

      expect(relay.current.distanceMeters, 1234);
    });

    test('a message for another path changes nothing', () async {
      await deliverStats(
          const RunStats(phase: RunPhase.running, distanceMeters: 1234));

      await deliver(<String, Object?>{'path': 'dash/something-else'});

      expect(relay.current.distanceMeters, 1234);
    });

    test('a message that is not a map at all is ignored', () async {
      await deliver('just a string');

      expect(relay.isConnected, isFalse);
    });

    test('none of them throws', () async {
      await deliver('a string');
      await deliver(<String, Object?>{'path': WearPaths.stats, 'payload': '{'});
      await deliver(<String, Object?>{});

      expect(relay.current.phase, RunPhase.idle);
    });
  });

  group('the run acknowledgement', () {
    test('fires when the phone confirms it stored the run', () async {
      // This is what lets the watch delete its own copy — until it arrives,
      // the file stays.
      var acks = 0;
      final sub = relay.runAcks.listen((_) => acks++);

      await deliver(<String, Object?>{'path': WearPaths.runAck});
      await sub.cancel();

      expect(acks, 1);
    });

    test('does not disturb the current reading', () async {
      await deliverStats(
          const RunStats(phase: RunPhase.running, distanceMeters: 1234));

      await deliver(<String, Object?>{'path': WearPaths.runAck});

      expect(relay.current.distanceMeters, 1234);
    });

    test('a stats message is not mistaken for one', () async {
      var acks = 0;
      final sub = relay.runAcks.listen((_) => acks++);

      await deliverStats(const RunStats(phase: RunPhase.running));
      await sub.cancel();

      expect(acks, 0);
    });
  });

  group('the watch\'s own heart rate', () {
    test('is merged into every reading from the phone', () async {
      // Measured on this device. Waiting for the phone to echo it back would
      // add a second of latency to a number already in hand, and blank it
      // entirely whenever the link dropped.
      final readings = Stream.value(
          const HeartRateReading(currentBpm: 152, averageBpm: 148, maxBpm: 170));
      relay.attachHeartRate(readings);
      for (var i = 0; i < 4; i++) {
        await Future<void>.delayed(Duration.zero);
      }

      await deliverStats(
          const RunStats(phase: RunPhase.running, distanceMeters: 500));

      expect(relay.current.heartRateBpm, 152);
    });

    test('a watch with no sensor simply never attaches one', () async {
      await deliverStats(const RunStats(phase: RunPhase.running));

      expect(relay.current.heartRateBpm, isNull);
    });
  });
}
