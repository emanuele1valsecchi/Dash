import 'package:dash_watch_protocol/dash_watch_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('RunStats round-trip', () {
    test('survives encode then decode intact', () {
      const original = RunStats(
        phase: RunPhase.running,
        elapsed: Duration(minutes: 27, seconds: 14),
        distanceMeters: 5432.1,
        paceMinPerKm: 5.28,
        heartRateBpm: 148,
        loopsCompleted: 2,
        claimedAreaM2: 84210.5,
        guidance: WatchGuidance(
          targetBearingDegrees: 214.5,
          headingDegrees: 190.0,
          isOffRoute: false,
          distanceToTurnMeters: 80,
          turnAngleDegrees: -88,
          distanceRemainingMeters: 1420,
        ),
      );

      final decoded = RunStats.decode(original.encode())!;

      expect(decoded.phase, RunPhase.running);
      expect(decoded.elapsed, const Duration(minutes: 27, seconds: 14));
      expect(decoded.distanceMeters, closeTo(5432.1, 0.001));
      expect(decoded.paceMinPerKm, closeTo(5.28, 0.001));
      expect(decoded.heartRateBpm, 148);
      expect(decoded.loopsCompleted, 2);
      expect(decoded.claimedAreaM2, closeTo(84210.5, 0.001));
      expect(decoded.guidance!.targetBearingDegrees, closeTo(214.5, 0.001));
      expect(decoded.guidance!.turnAngleDegrees, closeTo(-88, 0.001));
      expect(decoded.guidance!.isOffRoute, isFalse);
    });

    test('carries a null guidance through unchanged', () {
      const original = RunStats(phase: RunPhase.paused);
      expect(RunStats.decode(original.encode())!.guidance, isNull);
    });
  });

  // The phone and watch apps are installed and updated independently, so a
  // watch will meet messages from a newer phone (and vice versa). Every one of
  // these must degrade rather than throw: a stale watch showing less is fine,
  // a watch crashing mid-run is not.
  group('forward compatibility', () {
    test('an unknown phase falls back instead of throwing', () {
      final decoded = RunStats.fromJson({'phase': 'teleporting'});
      expect(decoded.phase, RunPhase.idle);
    });

    test('unknown fields are ignored', () {
      final decoded = RunStats.fromJson({
        'phase': 'running',
        'distance': 100.0,
        'cadenceSpm': 178, // a field this build has never heard of
        'vo2max': 51.2,
      });

      expect(decoded.phase, RunPhase.running);
      expect(decoded.distanceMeters, 100.0);
    });

    test('missing optional fields decode to null, not zero', () {
      final decoded = RunStats.fromJson({'phase': 'running'});

      // Null and 0 mean different things here: no reading yet, versus a
      // reading of zero. Rendering "0 bpm" for a sensor that has not reported
      // would be worse than showing nothing.
      expect(decoded.paceMinPerKm, isNull);
      expect(decoded.heartRateBpm, isNull);
      expect(decoded.guidance, isNull);
      expect(decoded.distanceMeters, 0);
    });

    test('malformed input decodes to null rather than throwing', () {
      expect(RunStats.decode('not json at all'), isNull);
      expect(RunStats.decode('[1,2,3]'), isNull);
      expect(RunStats.decode(''), isNull);
    });

    test('ints arriving where doubles are expected still parse', () {
      // JSON has one number type; a whole-valued double serialises as an int.
      final decoded = RunStats.fromJson({
        'phase': 'running',
        'distance': 5000,
        'pace': 5,
      });

      expect(decoded.distanceMeters, 5000.0);
      expect(decoded.paceMinPerKm, 5.0);
    });
  });

  group('WatchGuidance.arrowRotationDegrees', () {
    test('is the bearing relative to the runner heading', () {
      const guidance = WatchGuidance(
        targetBearingDegrees: 90,
        headingDegrees: 45,
        isOffRoute: false,
        distanceToTurnMeters: null,
        turnAngleDegrees: null,
        distanceRemainingMeters: 0,
      );

      expect(guidance.arrowRotationDegrees(), closeTo(45, 0.001));
    });

    test('wraps rather than going negative', () {
      const guidance = WatchGuidance(
        targetBearingDegrees: 10,
        headingDegrees: 350,
        isOffRoute: false,
        distanceToTurnMeters: null,
        turnAngleDegrees: null,
        distanceRemainingMeters: 0,
      );

      // 10 - 350 = -340, which must present as a 20 degree turn to the right.
      expect(guidance.arrowRotationDegrees(), closeTo(20, 0.001));
    });

    test('is null without a heading, so no arrow is drawn', () {
      const guidance = WatchGuidance(
        targetBearingDegrees: 90,
        headingDegrees: null,
        isOffRoute: false,
        distanceToTurnMeters: null,
        turnAngleDegrees: null,
        distanceRemainingMeters: 0,
      );

      expect(guidance.arrowRotationDegrees(), isNull);
    });

    test('a local compass heading overrides the one on the wire', () {
      // The watch has a magnetometer that stays correct while standing still,
      // unlike the phone's GPS course-over-ground.
      const guidance = WatchGuidance(
        targetBearingDegrees: 90,
        headingDegrees: 45,
        isOffRoute: false,
        distanceToTurnMeters: null,
        turnAngleDegrees: null,
        distanceRemainingMeters: 0,
      );

      expect(guidance.arrowRotationDegrees(heading: 90), closeTo(0, 0.001));
    });
  });

  group('WatchCommand', () {
    test('parses its own names', () {
      expect(WatchCommand.parse('start'), WatchCommand.start);
      expect(WatchCommand.parse('finish'), WatchCommand.finish);
    });

    test('returns null for anything else', () {
      expect(WatchCommand.parse('selfDestruct'), isNull);
      expect(WatchCommand.parse(''), isNull);
    });
  });
}
