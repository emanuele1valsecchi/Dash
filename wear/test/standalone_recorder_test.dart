import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';

import 'package:dash_wear/standalone_recorder.dart';

/// Recording a run on the watch's own GPS, with the phone left at home.
///
/// The filtering here decides the distance shown on the wrist, and unlike a
/// phone-recorded run there is nothing alongside it to check against. The
/// thresholds deliberately match the phone's own, so that a run imported
/// later is filtered the way a phone-recorded one would have been — if these
/// two drift apart, the same run reads as two different distances depending
/// on which device recorded it.
///
/// Nothing here touches the file on disk: the persistence half goes through
/// `getApplicationDocumentsDirectory`, which needs a platform channel. What
/// is covered is everything that decides *what would be written*.
void main() {
  late StandaloneRecorder recorder;

  setUp(() => recorder = StandaloneRecorder());

  final start = DateTime(2026, 3, 14, 9, 0, 0);

  /// A GPS fix. Defaults are deliberately "good" — accurate, and at a
  /// believable running pace — so a test only states the field it is about.
  Position fix({
    double latitude = 45.4642,
    double longitude = 9.1900,
    double altitude = 120,
    double accuracy = 5,
    Duration after = Duration.zero,
  }) =>
      Position(
        latitude: latitude,
        longitude: longitude,
        timestamp: start.add(after),
        accuracy: accuracy,
        altitude: altitude,
        altitudeAccuracy: 1,
        heading: 0,
        headingAccuracy: 1,
        speed: 3,
        speedAccuracy: 1,
      );

  /// Roughly [metres] north of the base latitude.
  double northOf(double metres) => 45.4642 + metres / 110540.0;

  group('a recorded fix', () {
    test('survives a round trip through its stored form', () {
      final original = RecordedFix(
        latitude: 45.4642,
        longitude: 9.19,
        altitude: 137.5,
        time: start,
      );

      final back = RecordedFix.fromJson(original.toJson());

      expect(back.latitude, original.latitude);
      expect(back.longitude, original.longitude);
      expect(back.altitude, original.altitude);
      expect(back.time, original.time);
    });

    test('is stored under short keys', () {
      // An hour of running is roughly 1800 fixes and the whole thing has to
      // cross a Bluetooth link; verbose keys would add tens of kilobytes.
      final json = RecordedFix(
        latitude: 1, longitude: 2, altitude: 3, time: start).toJson();

      expect(json.keys.toSet(), {'a', 'o', 'e', 't'});
    });

    test('stores time as epoch millis, not a formatted string', () {
      final json = RecordedFix(
        latitude: 1, longitude: 2, altitude: 3, time: start).toJson();

      expect(json['t'], start.millisecondsSinceEpoch);
    });

    test('a fix with no altitude reads as zero rather than failing', () {
      // Older watch firmware omits it; a null here would throw on import and
      // take the whole pending run with it.
      final back = RecordedFix.fromJson({
        'a': 45.0,
        'o': 9.0,
        't': start.millisecondsSinceEpoch,
      });

      expect(back.altitude, 0);
    });
  });

  group('which fixes are kept', () {
    test('an accurate fix is recorded', () {
      recorder.onPosition(fix(accuracy: 5));

      expect(recorder.fixes, hasLength(1));
    });

    test('a fix at the accuracy limit is still recorded', () {
      // The threshold is a rejection bound, not a target: 20 m is the
      // ordinary quality of a first fix under trees.
      recorder.onPosition(fix(accuracy: 20));

      expect(recorder.fixes, hasLength(1));
    });

    test('a fix too vague to place is discarded', () {
      // A 50 m error is not a position, and appending it would add distance
      // the runner never covered.
      recorder.onPosition(fix(accuracy: 50));

      expect(recorder.fixes, isEmpty);
      expect(recorder.distanceMeters, 0);
    });

    test('a discarded fix does not become the next one\'s starting point',
        () {
      // Otherwise the bad fix still contributes, just one step later.
      recorder.onPosition(fix());
      recorder.onPosition(
          fix(latitude: northOf(500), accuracy: 50, after: const Duration(minutes: 5)));
      recorder.onPosition(
          fix(latitude: northOf(20), after: const Duration(seconds: 10)));

      expect(recorder.fixes, hasLength(2));
      expect(recorder.distanceMeters, closeTo(20, 2),
          reason: 'measured from the last *kept* fix');
    });
  });

  group('how far it thinks you have run', () {
    test('starts at nothing', () {
      expect(recorder.distanceMeters, 0);
    });

    test('the first fix adds no distance', () {
      // There is nothing to measure from yet.
      recorder.onPosition(fix());

      expect(recorder.distanceMeters, 0);
    });

    test('accumulates between consecutive fixes', () {
      recorder.onPosition(fix());
      recorder.onPosition(
          fix(latitude: northOf(20), after: const Duration(seconds: 10)));

      expect(recorder.distanceMeters, closeTo(20, 2));
    });

    test('keeps accumulating across many fixes', () {
      for (var i = 0; i <= 5; i++) {
        recorder.onPosition(fix(
          latitude: northOf(20.0 * i),
          after: Duration(seconds: 10 * i),
        ));
      }

      expect(recorder.fixes, hasLength(6));
      expect(recorder.distanceMeters, closeTo(100, 5));
    });
  });

  group('GPS spikes', () {
    test('a jump no runner could have made is rejected', () {
      // 500 m in one second. Left in, a single spike adds half a kilometre
      // to the run and the same again coming back.
      recorder.onPosition(fix());
      recorder.onPosition(
          fix(latitude: northOf(500), after: const Duration(seconds: 1)));

      expect(recorder.fixes, hasLength(1));
      expect(recorder.distanceMeters, 0);
    });

    test('a genuine sprint is not mistaken for one', () {
      // 7 m/s is about a 2:23 km — fast, and real. The threshold has to sit
      // above what a person can actually do.
      recorder.onPosition(fix());
      recorder.onPosition(
          fix(latitude: northOf(70), after: const Duration(seconds: 10)));

      expect(recorder.fixes, hasLength(2));
      expect(recorder.distanceMeters, closeTo(70, 3));
    });

    test('two fixes at the same instant are not a division by zero', () {
      // The speed check needs an elapsed time; a repeated timestamp would
      // otherwise produce infinity and reject a perfectly good fix.
      recorder.onPosition(fix());
      recorder.onPosition(fix(latitude: northOf(10)));

      expect(recorder.fixes, hasLength(2));
      expect(recorder.distanceMeters, closeTo(10, 2));
    });
  });

  group('heart rate', () {
    test('is carried, because only the watch can measure it', () {
      // Nothing else in the system can produce this: if the recorder drops
      // it, it is gone the moment the run ends.
      recorder.setHeartRate(average: 142, max: 175);

      expect(recorder.isRecording, isFalse,
          reason: 'setting it does not start a run');
    });

    test('is accepted before any fix has arrived', () {
      recorder.setHeartRate(average: 130, max: 160);

      expect(recorder.fixes, isEmpty);
    });
  });

  group('what the watch does not do', () {
    test('it records fixes and nothing derived from them', () {
      // Loop geometry, area and XP decide territory ownership, so they are
      // computed where the server can verify them. The watch produces a
      // breadcrumb list; the phone recomputes everything on import, which is
      // what stops a tampered-with watch claiming ground.
      recorder.onPosition(fix());
      recorder.onPosition(
          fix(latitude: northOf(20), after: const Duration(seconds: 10)));

      expect(recorder.fixes.every((f) => f.latitude != 0), isTrue);
      expect(recorder.isRecording, isFalse,
          reason: 'no stream was started, yet fixes still record');
    });

    test('it reports no lost GPS before a run has started', () {
      expect(recorder.hasLostGps, isFalse);
    });
  });
}
