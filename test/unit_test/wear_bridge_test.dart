import 'dart:convert';

import 'package:dash_watch_protocol/dash_watch_protocol.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:geolocator/geolocator.dart';

import 'package:dash/services/run_session_controller.dart';
import 'package:dash/services/wear_bridge.dart';

/// A plausible GPS fix — accurate, running speed, valid heading.
Position _fix(double lat, double lng, {required int seconds}) => Position(
      latitude: lat,
      longitude: lng,
      timestamp: DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true),
      accuracy: 5,
      altitude: 120,
      altitudeAccuracy: 3,
      heading: 90,
      headingAccuracy: 5,
      speed: 3,
      speedAccuracy: 1,
    );

/// Drives the bridge through its two platform channels: `send`/`nodes`/
/// `getData`/`deleteData` are answered by a mock handler that records what
/// was sent, and incoming watch messages are pushed straight into the
/// bridge's own handler through the event channel.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final bridge = WearBridge.instance;
  final controller = RunSessionController.instance;

  const channel = MethodChannel('dash/wear_bridge');
  const messages = EventChannel('dash/wear_bridge/messages');

  late List<MethodCall> calls;
  late List<Object?> nodes;
  late List<Object?> pendingData;

  /// Everything sent to the watch, newest last, as `{path: payload}`.
  List<Map<String, Object?>> sent() => [
        for (final c in calls)
          if (c.method == 'send')
            (c.arguments as Map).cast<String, Object?>(),
      ];

  Map<String, Object?>? lastStats() {
    for (final m in sent().reversed) {
      if (m['path'] == WearPaths.stats) {
        return jsonDecode(m['payload'] as String) as Map<String, Object?>;
      }
    }
    return null;
  }

  /// Delivers one message as if it had arrived from the watch.
  Future<void> fromWatch(Map<String, Object?> message) async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      messages.name,
      const StandardMethodCodec().encodeSuccessEnvelope(message),
      (_) {},
    );
    // Let the bridge's stream listener and any async handling run.
    await Future<void>.delayed(Duration.zero);
  }

  setUp(() async {
    calls = [];
    nodes = [];
    pendingData = [];
    controller.reset();
    bridge.resetForTest();

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return switch (call.method) {
        'nodes' => nodes,
        'getData' => pendingData,
        'deleteData' => true,
        _ => 0,
      };
    });

    await bridge.start();
  });

  tearDown(() {
    // `resetForTest` rather than `dispose`: dispose closes the broadcast
    // controllers for good, and this is a singleton, so the next test in the
    // file would get a bridge that runs but silently drops everything.
    bridge.resetForTest();
    controller.reset();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('watch presence', () {
    test('no connected nodes means no watch', () async {
      expect(bridge.hasWatch, isFalse);
    });

    test('a connected node means a watch', () async {
      nodes = ['watch-1'];

      await bridge.refreshWatchPresence();

      expect(bridge.hasWatch, isTrue);
    });

    test('a platform failure is not fatal, just no watch', () async {
      // Play Services missing or unavailable is normal on many devices.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'unavailable');
      });

      await bridge.refreshWatchPresence();

      expect(bridge.hasWatch, isFalse);
    });
  });

  group('commands from the watch', () {
    test('pause pauses a running run', () async {
      controller.beginRunForTesting();

      await fromWatch({
        'path': WearPaths.command,
        'payload': WatchCommand.pause.name,
      });

      expect(controller.isPaused, isTrue);
    });

    test('pause does nothing before a run has started', () async {
      await fromWatch({
        'path': WearPaths.command,
        'payload': WatchCommand.pause.name,
      });

      expect(controller.isPaused, isFalse);
    });

    test('resume unpauses', () async {
      controller.beginRunForTesting();
      controller.togglePause();

      await fromWatch({
        'path': WearPaths.command,
        'payload': WatchCommand.resume.name,
      });

      expect(controller.isPaused, isFalse);
    });

    test('resume does nothing when not paused', () async {
      controller.beginRunForTesting();

      await fromWatch({
        'path': WearPaths.command,
        'payload': WatchCommand.resume.name,
      });

      expect(controller.isPaused, isFalse);
    });

    test('start is handed to the UI, not actioned here', () async {
      // Starting needs navigation to the run screen, which a service cannot
      // do — so it is forwarded rather than swallowed.
      final seen = <WatchCommand>[];
      final sub = bridge.commands.listen(seen.add);
      addTearDown(sub.cancel);

      await fromWatch({
        'path': WearPaths.command,
        'payload': WatchCommand.start.name,
      });

      expect(seen, [WatchCommand.start]);
    });

    test('finish is handed to the UI too', () async {
      final seen = <WatchCommand>[];
      final sub = bridge.commands.listen(seen.add);
      addTearDown(sub.cancel);

      await fromWatch({
        'path': WearPaths.command,
        'payload': WatchCommand.finish.name,
      });

      expect(seen, [WatchCommand.finish]);
    });

    test('acting on a command echoes the new state back immediately',
        () async {
      // So the watch's own button feels responsive rather than waiting up to
      // a second for the next tick.
      controller.beginRunForTesting();
      calls.clear();

      await fromWatch({
        'path': WearPaths.command,
        'payload': WatchCommand.pause.name,
      });

      expect(lastStats(), isNotNull);
      expect(lastStats()!['phase'], RunPhase.paused.name);
    });

    test('a forwarded command still acks with the current state', () async {
      // The case above would pass without the explicit publish in
      // `_applyCommand`, because pausing changes the phase and the
      // controller listener republishes anyway. `start` and `finish` do not
      // change the phase — they are handed to the UI — so that listener
      // never fires, and the explicit publish is the only thing that answers
      // the watch. Without it a watch button press gets silence.
      calls.clear();

      await fromWatch({
        'path': WearPaths.command,
        'payload': WatchCommand.start.name,
      });

      expect(lastStats(), isNotNull);
    });

    test('an unknown command is ignored, not crashed on', () async {
      await fromWatch({
        'path': WearPaths.command,
        'payload': 'self_destruct',
      });

      expect(controller.isPaused, isFalse);
    });
  });

  group('heart rate from the watch', () {
    test('is stored on the controller', () async {
      await fromWatch({
        'path': WearPaths.heartRate,
        'payload': const HeartRateReading(
          currentBpm: 148,
          averageBpm: 152,
          maxBpm: 178,
        ).encode(),
      });

      expect(controller.heartRateBpm, 148);
      expect(controller.avgHeartRateBpm, 152);
      expect(controller.maxHeartRateBpm, 178);
    });

    test('an undecodable reading is ignored', () async {
      await fromWatch({
        'path': WearPaths.heartRate,
        'payload': 'not json at all',
      });

      expect(controller.heartRateBpm, isNull);
    });
  });

  group('sync requests', () {
    test('a watch that just connected is told the current state', () async {
      // It has no idea what is going on until the phone says so.
      calls.clear();

      await fromWatch({'path': WearPaths.requestSync, 'payload': ''});

      expect(lastStats(), isNotNull);
    });

    test('a message on an unknown path is ignored', () async {
      calls.clear();

      await fromWatch({'path': '/dash/something_new', 'payload': 'x'});

      expect(sent(), isEmpty);
    });

    test('a malformed message is ignored', () async {
      calls.clear();

      await fromWatch(<String, Object?>{});

      expect(sent(), isEmpty);
    });
  });

  group('what gets published', () {
    test('an idle bridge reports the idle phase', () async {
      await bridge.publishNow();

      expect(lastStats()!['phase'], RunPhase.idle.name);
    });

    test('a started run reports running', () async {
      controller.beginRunForTesting();

      await bridge.publishNow();

      expect(lastStats()!['phase'], RunPhase.running.name);
    });

    test('a phase change is published without waiting for the tick',
        () async {
      // The point of this: the periodic publish only fires while a run is
      // live, so ending one used to just stop the messages — leaving the
      // watch counting up forever from its last snapshot. Terminal states
      // have to be told, not inferred from silence.
      controller.beginRunForTesting();
      calls.clear();

      controller.togglePause();
      await Future<void>.delayed(Duration.zero);

      expect(lastStats()!['phase'], RunPhase.paused.name);
    });

    test('an unchanged phase does not republish on every fix', () async {
      // The controller notifies on every GPS fix, far more often than a
      // watch face can usefully redraw, and every message costs radio time.
      controller.beginRunForTesting();
      await Future<void>.delayed(Duration.zero);
      calls.clear();

      controller.onPosition(_fix(45.4642, 9.1900, seconds: 0));
      controller.onPosition(_fix(45.4643, 9.1900, seconds: 5));
      await Future<void>.delayed(Duration.zero);

      expect(sent(), isEmpty);
    });

    test('a publish failure is survivable', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'not_connected');
      });

      await bridge.publishNow();

      expect(true, isTrue, reason: 'did not throw');
    });
  });
}
