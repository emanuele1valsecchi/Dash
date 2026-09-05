import 'package:dash_watch_protocol/dash_watch_protocol.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dash_wear/heart_rate_service.dart';

/// The one measurement only the watch can take.
///
/// Nothing else in Dash can produce a heart rate: if this accumulates wrongly
/// the number is wrong on the wrist *and* wrong in the run the phone imports,
/// with nothing to check it against. The accumulation is also the thing that
/// has to be cleared between runs — carrying one run's average into the next
/// is the same hazard `RunSessionController.reset` guards against on the
/// phone, and it fails silently.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const control = MethodChannel('dash/heart_rate');
  const values = EventChannel('dash/heart_rate/values');

  late HeartRateService service;

  /// Answers the sensor's capability probes.
  void sensor({bool available = true, bool permitted = true}) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(control, (call) async {
      switch (call.method) {
        case 'isAvailable':
          return available;
        case 'hasPermission':
          return permitted;
        default:
          return null;
      }
    });
  }

  setUp(() {
    sensor();
    service = HeartRateService();
  });

  tearDown(() {
    service.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(control, null);
  });

  /// Delivers one sample as the platform sensor would.
  Future<void> sample(Object? bpm) async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      values.name,
      const StandardMethodCodec().encodeSuccessEnvelope(bpm),
      (_) {},
    );
    for (var i = 0; i < 4; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  group('before any sample', () {
    test('every figure is absent, not zero', () async {
      // Zero is a heart rate. A watch that has not read one yet must not
      // report one, or a run with no sensor saves 0 bpm as though measured.
      expect(service.reading.currentBpm, isNull);
      expect(service.reading.averageBpm, isNull);
      expect(service.reading.maxBpm, isNull);
    });

    test('it does not claim the sensor is there', () async {
      expect(service.isAvailable, isFalse);
      expect(service.isPermitted, isFalse);
    });
  });

  group('accumulating', () {
    setUp(() async => service.start());

    test('one sample is the current, the average and the max', () async {
      await sample(142);

      expect(service.reading.currentBpm, 142);
      expect(service.reading.averageBpm, 142);
      expect(service.reading.maxBpm, 142);
    });

    test('the current follows the latest sample', () async {
      await sample(142);
      await sample(120);

      expect(service.reading.currentBpm, 120);
    });

    test('the max keeps the highest, not the latest', () async {
      // The peak of a run is a number people care about; letting a cooldown
      // sample overwrite it would quietly lower it.
      await sample(142);
      await sample(175);
      await sample(120);

      expect(service.reading.maxBpm, 175);
    });

    test('the average is over every sample', () async {
      await sample(140);
      await sample(160);

      expect(service.reading.averageBpm, 150);
    });

    test('the average rounds rather than truncating', () async {
      // 140, 140, 141 averages to 140.33; 140, 141, 141 to 140.67.
      await sample(140);
      await sample(141);
      await sample(141);

      expect(service.reading.averageBpm, 141);
    });

    test('each sample is published so the display can repaint', () async {
      final seen = <HeartRateReading>[];
      final sub = service.readings.listen(seen.add);

      await sample(142);
      await sample(150);
      await sub.cancel();

      expect(seen.map((r) => r.currentBpm), [142, 150]);
    });
  });

  group('samples that are not readings', () {
    setUp(() async => service.start());

    test('a non-integer sample is ignored', () async {
      // The platform side has been known to emit a null while the sensor
      // warms up; counting it would drag the average toward zero.
      await sample(142);

      await sample('not a number');
      await sample(null);

      expect(service.reading.currentBpm, 142);
      expect(service.reading.averageBpm, 142);
    });

    test('none of them throws', () async {
      await sample(<String, Object?>{});
      await sample(3.5);

      expect(service.reading.currentBpm, isNull);
    });
  });

  group('between runs', () {
    setUp(() async => service.start());

    test('resetting clears the accumulation', () async {
      // Without this the next run opens carrying the last one's average and
      // peak, which looks plausible and is entirely wrong.
      await sample(142);
      await sample(175);

      service.resetAccumulation();

      expect(service.reading.currentBpm, isNull);
      expect(service.reading.averageBpm, isNull);
      expect(service.reading.maxBpm, isNull);
    });

    test('and the next run accumulates from scratch', () async {
      await sample(180);
      service.resetAccumulation();

      await sample(120);

      expect(service.reading.maxBpm, 120,
          reason: 'the previous run\'s peak is gone, not merely hidden');
      expect(service.reading.averageBpm, 120);
    });

    test('the subscription survives the reset', () async {
      // Tearing the sensor down and back up between runs would drop samples
      // for however long it takes to re-acquire.
      await sample(142);
      service.resetAccumulation();

      await sample(150);

      expect(service.reading.currentBpm, 150);
    });
  });

  group('a watch without the sensor', () {
    test('reports it, rather than waiting for samples that never come',
        () async {
      sensor(available: false);

      await service.start();

      expect(service.isAvailable, isFalse);
    });

    test('and never produces a reading', () async {
      sensor(available: false);
      await service.start();

      expect(service.reading.currentBpm, isNull);
    });
  });
}
