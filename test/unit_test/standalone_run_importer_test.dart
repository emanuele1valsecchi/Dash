import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dash/services/standalone_run_importer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mockito/mockito.dart';

import '../mocks.mocks.dart';

/// Importing a run the watch recorded on its own.
///
/// The payload arrives gzipped over the Wear Data Layer, so **decoding must
/// never throw**: a corrupt transfer should be dropped and retried, not crash
/// the phone app while the user is doing something else entirely.
///
/// The other half is that a watch run and a phone run of the same route must
/// report the *same* numbers — the importer replays the same GPS-spike
/// rejection and loop detection the live controller uses, rather than trusting
/// whatever the watch computed.
void main() {
  late MockRunSessionRepository repo;

  /// Encodes a run the way the watch does: gzipped UTF-8 JSON.
  Uint8List encode(Object? payload) =>
      Uint8List.fromList(gzip.encode(utf8.encode(jsonEncode(payload))));

  /// One GPS fix. `a`/`o`/`t`/`e` are the watch's short field names.
  Map<String, Object?> fix(
    double lat,
    double lng,
    int msSinceStart, {
    double? altitude,
  }) =>
      {
        'a': lat,
        'o': lng,
        't': DateTime(2026, 3, 14).millisecondsSinceEpoch + msSinceStart,
        'e': ?altitude,
      };

  setUp(() {
    repo = MockRunSessionRepository();
    when(repo.saveSession(
      name: anyNamed('name'),
      distanceMeters: anyNamed('distanceMeters'),
      duration: anyNamed('duration'),
      avgPaceMinPerKm: anyNamed('avgPaceMinPerKm'),
      elevationDifferenceMeters: anyNamed('elevationDifferenceMeters'),
      loopsCompleted: anyNamed('loopsCompleted'),
      path: anyNamed('path'),
      closedLoops: anyNamed('closedLoops'),
      avgHeartRateBpm: anyNamed('avgHeartRateBpm'),
      maxHeartRateBpm: anyNamed('maxHeartRateBpm'),
    )).thenAnswer((_) async => 'session-1');
  });

  group('decode', () {
    test('round-trips a gzipped JSON payload', () {
      final bytes = encode({'durationMs': 1000, 'fixes': []});

      expect(StandaloneRunImporter.decode(bytes), isNotNull);
      expect(StandaloneRunImporter.decode(bytes)!['durationMs'], 1000);
    });

    test('returns null for bytes that are not gzip', () {
      // A truncated or mangled Data Layer transfer.
      expect(
        StandaloneRunImporter.decode(Uint8List.fromList([1, 2, 3, 4])),
        isNull,
      );
    });

    test('returns null for gzipped bytes that are not JSON', () {
      final bytes = Uint8List.fromList(gzip.encode(utf8.encode('not json')));

      expect(StandaloneRunImporter.decode(bytes), isNull);
    });

    test('returns null for valid JSON that is not an object', () {
      // A bare list or number is well-formed JSON but not a run.
      expect(StandaloneRunImporter.decode(encode([1, 2, 3])), isNull);
      expect(StandaloneRunImporter.decode(encode(42)), isNull);
    });

    test('returns null rather than throwing on empty bytes', () {
      expect(StandaloneRunImporter.decode(Uint8List(0)), isNull);
    });
  });

  group('import refuses unusable runs', () {
    test('a run with no fixes writes nothing', () async {
      expect(
        await StandaloneRunImporter.import({'fixes': []}, repository: repo),
        isNull,
      );
      verifyNever(repo.saveSession(
        name: anyNamed('name'),
        distanceMeters: anyNamed('distanceMeters'),
        duration: anyNamed('duration'),
        avgPaceMinPerKm: anyNamed('avgPaceMinPerKm'),
        elevationDifferenceMeters: anyNamed('elevationDifferenceMeters'),
        loopsCompleted: anyNamed('loopsCompleted'),
        path: anyNamed('path'),
        closedLoops: anyNamed('closedLoops'),
      ));
    });

    test('a single fix is not a run', () async {
      // Two points are the minimum that can describe any movement.
      expect(
        await StandaloneRunImporter.import(
          {'fixes': [fix(45.65, 9.20, 0)]},
          repository: repo,
        ),
        isNull,
      );
    });

    test('a missing fixes key writes nothing', () async {
      expect(
        await StandaloneRunImporter.import({'durationMs': 1000},
            repository: repo),
        isNull,
      );
    });

    test('fixes of the wrong type write nothing', () async {
      expect(
        await StandaloneRunImporter.import({'fixes': 'nonsense'},
            repository: repo),
        isNull,
      );
    });
  });

  group('import writes the run', () {
    /// A straight line of five fixes ~3.3 m apart, one second between each —
    /// about 12 km/h, a realistic jog and comfortably under the 8 m/s
    /// plausibility cap.
    ///
    /// Spacing matters: 0.0001 degrees per second is ~11 m/s (40 km/h), which
    /// the spike filter correctly rejects, so a fixture that fast measures
    /// zero distance.
    Map<String, Object?> straightRun() => {
          'durationMs': 4000,
          'fixes': [
            for (var i = 0; i < 5; i++)
              fix(45.6500 + i * 0.00003, 9.2000, i * 1000, altitude: 100.0 + i),
          ],
        };

    test('returns the new session id', () async {
      expect(
        await StandaloneRunImporter.import(straightRun(), repository: repo),
        'session-1',
      );
    });

    test('names it rather than prompting', () async {
      // The run finished on a wrist, possibly hours ago — interrupting the
      // user to name it on arrival would be worse than a default.
      await StandaloneRunImporter.import(straightRun(), repository: repo);

      verify(repo.saveSession(
        name: 'Watch run',
        distanceMeters: anyNamed('distanceMeters'),
        duration: anyNamed('duration'),
        avgPaceMinPerKm: anyNamed('avgPaceMinPerKm'),
        elevationDifferenceMeters: anyNamed('elevationDifferenceMeters'),
        loopsCompleted: anyNamed('loopsCompleted'),
        path: anyNamed('path'),
        closedLoops: anyNamed('closedLoops'),
        avgHeartRateBpm: anyNamed('avgHeartRateBpm'),
        maxHeartRateBpm: anyNamed('maxHeartRateBpm'),
      )).called(1);
    });

    test('passes the duration the watch reported', () async {
      await StandaloneRunImporter.import(straightRun(), repository: repo);

      final call = verify(repo.saveSession(
        name: anyNamed('name'),
        distanceMeters: anyNamed('distanceMeters'),
        duration: captureAnyNamed('duration'),
        avgPaceMinPerKm: anyNamed('avgPaceMinPerKm'),
        elevationDifferenceMeters: anyNamed('elevationDifferenceMeters'),
        loopsCompleted: anyNamed('loopsCompleted'),
        path: anyNamed('path'),
        closedLoops: anyNamed('closedLoops'),
        avgHeartRateBpm: anyNamed('avgHeartRateBpm'),
        maxHeartRateBpm: anyNamed('maxHeartRateBpm'),
      ))..called(1);

      expect(call.captured.single, const Duration(milliseconds: 4000));
    });

    test('rebuilds the path from the fixes', () async {
      await StandaloneRunImporter.import(straightRun(), repository: repo);

      final call = verify(repo.saveSession(
        name: anyNamed('name'),
        distanceMeters: anyNamed('distanceMeters'),
        duration: anyNamed('duration'),
        avgPaceMinPerKm: anyNamed('avgPaceMinPerKm'),
        elevationDifferenceMeters: anyNamed('elevationDifferenceMeters'),
        loopsCompleted: anyNamed('loopsCompleted'),
        path: captureAnyNamed('path'),
        closedLoops: anyNamed('closedLoops'),
        avgHeartRateBpm: anyNamed('avgHeartRateBpm'),
        maxHeartRateBpm: anyNamed('maxHeartRateBpm'),
      ))..called(1);

      final path = call.captured.single as List<LatLng>;
      expect(path, hasLength(5));
      expect(path.first.latitude, closeTo(45.65, 1e-9));
    });

    test('derives elevation gain from the altitude samples', () async {
      // 100 -> 104 across the five fixes.
      await StandaloneRunImporter.import(straightRun(), repository: repo);

      final call = verify(repo.saveSession(
        name: anyNamed('name'),
        distanceMeters: anyNamed('distanceMeters'),
        duration: anyNamed('duration'),
        avgPaceMinPerKm: anyNamed('avgPaceMinPerKm'),
        elevationDifferenceMeters: captureAnyNamed('elevationDifferenceMeters'),
        loopsCompleted: anyNamed('loopsCompleted'),
        path: anyNamed('path'),
        closedLoops: anyNamed('closedLoops'),
        avgHeartRateBpm: anyNamed('avgHeartRateBpm'),
        maxHeartRateBpm: anyNamed('maxHeartRateBpm'),
      ))..called(1);

      expect(call.captured.single, closeTo(4.0, 1e-9));
    });

    test('reports no elevation when the watch sent no altitudes', () async {
      // Absence must read as zero gain, not as a NaN or an infinity.
      await StandaloneRunImporter.import({
        'durationMs': 2000,
        'fixes': [fix(45.65, 9.20, 0), fix(45.65003, 9.20, 1000)],
      }, repository: repo);

      final call = verify(repo.saveSession(
        name: anyNamed('name'),
        distanceMeters: anyNamed('distanceMeters'),
        duration: anyNamed('duration'),
        avgPaceMinPerKm: anyNamed('avgPaceMinPerKm'),
        elevationDifferenceMeters: captureAnyNamed('elevationDifferenceMeters'),
        loopsCompleted: anyNamed('loopsCompleted'),
        path: anyNamed('path'),
        closedLoops: anyNamed('closedLoops'),
        avgHeartRateBpm: anyNamed('avgHeartRateBpm'),
        maxHeartRateBpm: anyNamed('maxHeartRateBpm'),
      ))..called(1);

      expect(call.captured.single, 0.0);
    });

    test('forwards heart rate when the watch measured it', () async {
      // The one metric only a watch can supply — and it goes to the
      // owner-only private subcollection, never the public session doc.
      await StandaloneRunImporter.import({
        ...straightRun(),
        'avgHeartRateBpm': 152,
        'maxHeartRateBpm': 178,
      }, repository: repo);

      verify(repo.saveSession(
        name: anyNamed('name'),
        distanceMeters: anyNamed('distanceMeters'),
        duration: anyNamed('duration'),
        avgPaceMinPerKm: anyNamed('avgPaceMinPerKm'),
        elevationDifferenceMeters: anyNamed('elevationDifferenceMeters'),
        loopsCompleted: anyNamed('loopsCompleted'),
        path: anyNamed('path'),
        closedLoops: anyNamed('closedLoops'),
        avgHeartRateBpm: 152,
        maxHeartRateBpm: 178,
      )).called(1);
    });
  });

  group('distance matches what the phone would have recorded', () {
    Future<double> distanceOf(Map<String, Object?> run) async {
      await StandaloneRunImporter.import(run, repository: repo);
      final call = verify(repo.saveSession(
        name: anyNamed('name'),
        distanceMeters: captureAnyNamed('distanceMeters'),
        duration: anyNamed('duration'),
        avgPaceMinPerKm: anyNamed('avgPaceMinPerKm'),
        elevationDifferenceMeters: anyNamed('elevationDifferenceMeters'),
        loopsCompleted: anyNamed('loopsCompleted'),
        path: anyNamed('path'),
        closedLoops: anyNamed('closedLoops'),
        avgHeartRateBpm: anyNamed('avgHeartRateBpm'),
        maxHeartRateBpm: anyNamed('maxHeartRateBpm'),
      ))..called(1);
      return call.captured.single as double;
    }

    test('sums the legs of a clean trail', () async {
      final metres = await distanceOf({
        'durationMs': 2000,
        'fixes': [
          fix(45.65000, 9.20, 0),
          fix(45.65003, 9.20, 1000),
          fix(45.65006, 9.20, 2000),
        ],
      });

      // Two legs of ~3.3 m each.
      expect(metres, greaterThan(5));
      expect(metres, lessThan(10));
    });

    test('discards a leg implying an impossible speed', () async {
      // The same spike rejection the live controller applies, so a watch run
      // and a phone run of the same route report the same distance. Without
      // it one bad fix adds kilometres.
      final withSpike = await distanceOf({
        'durationMs': 2000,
        'fixes': [
          fix(45.6500, 9.20, 0),
          fix(46.5000, 9.20, 1000), // ~95 km in one second
          fix(45.6501, 9.20, 2000),
        ],
      });

      expect(withSpike, lessThan(1000));
    });

    test('a stationary run measures nothing rather than drifting', () async {
      final metres = await distanceOf({
        'durationMs': 2000,
        'fixes': [
          fix(45.65, 9.20, 0),
          fix(45.65, 9.20, 1000),
          fix(45.65, 9.20, 2000),
        ],
      });

      expect(metres, closeTo(0, 0.001));
    });
  });

  group('malformed fixes', () {
    test('a fix missing coordinates is skipped, not fatal', () async {
      final id = await StandaloneRunImporter.import({
        'durationMs': 3000,
        'fixes': [
          fix(45.65000, 9.20, 0),
          {'t': 1}, // no lat/lng
          fix(45.65006, 9.20, 2000),
        ],
      }, repository: repo);

      expect(id, 'session-1');
    });

    test('a run of only malformed fixes writes nothing', () async {
      expect(
        await StandaloneRunImporter.import({
          'durationMs': 1000,
          'fixes': [
            {'t': 1},
            {'t': 2},
          ],
        }, repository: repo),
        isNull,
      );
    });

    test('a missing duration is treated as zero, not as null', () async {
      final id = await StandaloneRunImporter.import({
        'fixes': [fix(45.65000, 9.20, 0), fix(45.65006, 9.20, 2000)],
      }, repository: repo);

      expect(id, 'session-1');
    });
  });
}
