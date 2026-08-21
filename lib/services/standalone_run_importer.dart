import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';

import '../utils/geometry_utils.dart';
import 'run_session_repository.dart';

/// Turns a run recorded on the watch into a normal `runningSessions` document.
///
/// The watch sends raw breadcrumbs and nothing else. **Everything that decides
/// territory is recomputed here** — distance, closed loops, area — rather than
/// trusted from the watch, for the same reason `pointsEarned` is server-only: a
/// device a user controls must never be able to assert how much ground it won.
/// The distance shown on the wrist mid-run was only ever a display value.
///
/// Once written, the Cloud Function claims territory exactly as it does for a
/// phone-recorded run. Nothing downstream knows or cares which device recorded
/// it.
class StandaloneRunImporter {
  StandaloneRunImporter._();

  /// Mirrors `RunSessionController`'s own thresholds so an imported run is
  /// filtered identically to one recorded on the phone. If those ever change,
  /// these must too — the duplication is deliberate but fragile, and the two
  /// belong in one place if a third caller ever appears.
  static const double _maxPlausibleSpeedMs = 8.0;
  static const double _minLoopAreaM2 = 50.0;

  /// Decodes the gzipped JSON the watch put on the Data Layer.
  ///
  /// Returns null on anything malformed rather than throwing: a corrupt
  /// transfer should be dropped and retried, not crash the phone app while the
  /// user is doing something else entirely.
  static Map<String, Object?>? decode(Uint8List bytes) {
    try {
      final json = utf8.decode(gzip.decode(bytes));
      final decoded = jsonDecode(json);
      return decoded is Map ? decoded.cast<String, Object?>() : null;
    } catch (e) {
      debugPrint('StandaloneRunImporter: undecodable payload — $e');
      return null;
    }
  }

  /// Writes the run and returns its new session id, or null if it was empty or
  /// unusable.
  static Future<String?> import(Map<String, Object?> run) async {
    final rawFixes = run['fixes'];
    if (rawFixes is! List || rawFixes.length < 2) {
      debugPrint('StandaloneRunImporter: too few fixes to import');
      return null;
    }

    final points = <LatLng>[];
    final times = <DateTime>[];
    for (final raw in rawFixes) {
      if (raw is! Map) continue;
      final lat = (raw['a'] as num?)?.toDouble();
      final lng = (raw['o'] as num?)?.toDouble();
      final ms = raw['t'] as int?;
      if (lat == null || lng == null || ms == null) continue;
      points.add(LatLng(lat, lng));
      times.add(DateTime.fromMillisecondsSinceEpoch(ms));
    }
    if (points.length < 2) return null;

    final distanceMeters = _distanceOf(points, times);
    final duration = Duration(milliseconds: run['durationMs'] as int? ?? 0);
    final loops = _closedLoops(points);

    final minutes = duration.inMilliseconds / 1000 / 60;
    final km = distanceMeters / 1000;
    final avgPace = km > 0 ? minutes / km : 0.0;

    return RunSessionRepository.instance.saveSession(
      // Named rather than prompted for: the run finished on a wrist, possibly
      // hours ago, and interrupting the user to name it on arrival would be
      // worse than a sensible default they can change later.
      name: 'Watch run',
      distanceMeters: distanceMeters,
      duration: duration,
      avgPaceMinPerKm: avgPace,
      caloriesBurned: km * 70.0,
      elevationDifferenceMeters: _elevationOf(rawFixes),
      loopsCompleted: loops.length,
      path: points,
      closedLoops: loops,
      avgHeartRateBpm: run['avgHeartRateBpm'] as int?,
      maxHeartRateBpm: run['maxHeartRateBpm'] as int?,
    );
  }

  /// Same GPS-spike rejection the live controller applies, so a watch run and a
  /// phone run of the same route report the same distance.
  static double _distanceOf(List<LatLng> points, List<DateTime> times) {
    const dist = Distance();
    var total = 0.0;
    for (var i = 1; i < points.length; i++) {
      final metres = dist(points[i - 1], points[i]);
      final seconds = times[i].difference(times[i - 1]).inMilliseconds / 1000.0;
      if (seconds > 0 && metres / seconds > _maxPlausibleSpeedMs) continue;
      total += metres;
    }
    return total;
  }

  static double _elevationOf(List<Object?> rawFixes) {
    var min = double.infinity;
    var max = double.negativeInfinity;
    for (final raw in rawFixes) {
      if (raw is! Map) continue;
      final altitude = (raw['e'] as num?)?.toDouble();
      if (altitude == null || !altitude.isFinite) continue;
      if (altitude < min) min = altitude;
      if (altitude > max) max = altitude;
    }
    return min.isFinite && max.isFinite ? max - min : 0.0;
  }

  /// Replays the trail looking for closed loops, mirroring
  /// `RunSessionController._checkLoopClosure` — including the rule that a newly
  /// closed loop supersedes any earlier one sharing its ground, since
  /// `findLoopClosureIndex` always walks as far back as still closes and so is
  /// never smaller than what it replaces.
  static List<List<LatLng>> _closedLoops(List<LatLng> points) {
    final loops = <List<LatLng>>[];
    final rangeStart = <int>[];
    final rangeEnd = <int>[];

    for (var end = 4; end <= points.length; end++) {
      final soFar = points.sublist(0, end);
      final idx = GeometryUtils.findLoopClosureIndex(soFar);
      if (idx == null) continue;

      final polygon = soFar.sublist(idx);
      if (GeometryUtils.polygonAreaM2(polygon) < _minLoopAreaM2) continue;

      final start = idx;
      final finish = soFar.length - 1;
      for (var i = loops.length - 1; i >= 0; i--) {
        if (rangeStart[i] <= finish && start <= rangeEnd[i]) {
          loops.removeAt(i);
          rangeStart.removeAt(i);
          rangeEnd.removeAt(i);
        }
      }
      loops.add(polygon);
      rangeStart.add(start);
      rangeEnd.add(finish);
    }
    return loops;
  }
}
