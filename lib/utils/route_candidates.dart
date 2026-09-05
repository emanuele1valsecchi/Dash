import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import '../services/routing_service.dart';
import 'geometry_utils.dart';
import 'unit_formatter.dart';

/// What a user's distance/time/calorie entries add up to.
///
/// Exactly one of the three states holds: nothing was entered, the entries
/// disagree by more than [RouteCandidates.conflictTolerance], or they agree
/// well enough to average into a single target.
class RouteTarget {
  /// True when no field was filled in at all.
  final bool isEmpty;

  /// True when the entries imply distances too far apart to reconcile.
  final bool isConflict;

  /// The agreed target in kilometres; null unless the entries resolved.
  final double? targetKm;

  const RouteTarget.empty()
      : isEmpty = true,
        isConflict = false,
        targetKm = null;

  const RouteTarget.conflict()
      : isEmpty = false,
        isConflict = true,
        targetKm = null;

  const RouteTarget.resolved(double this.targetKm)
      : isEmpty = false,
        isConflict = false;
}

/// The candidate-selection rules behind route search: what counts as a real
/// loop, which results are near-duplicates of each other, and what the user's
/// typed constraints actually ask for.
///
/// Pure functions over segments and strings, extracted from
/// `route_search_page` so the rules can be tested without driving a search.
/// The transport they sit on top of (`RoutingService.fetchRoute` and friends)
/// is tested separately in `routing_service_test.dart`; what lives here is
/// the *strategy*, which is where this screen's reported field bugs were.
abstract final class RouteCandidates {
  /// Walking pace and energy per kilometre. Deliberately the same magic
  /// constants route creation uses, so a planned route and a found one report
  /// the same numbers for the same distance.
  static const double paceMinPerKm = 9.0;
  static const double calPerKm = 70.0;

  /// How far apart the time/distance/calorie entries may imply before they
  /// are treated as contradicting each other. Loose on purpose: all three are
  /// derived from the magic constants above, so they are never expected to
  /// agree exactly.
  static const double conflictTolerance = 0.30;

  /// How close a *generated* route must land to the target to be offered.
  /// Much tighter than [conflictTolerance] — a "find me an 8 km route" search
  /// returning 8.7 km reads as broken.
  static const double matchTolerance = 0.05;

  /// Typical road-network detour factor (road distance ÷ straight line) for
  /// city walking. The padding solver divides the target by it before solving
  /// for a detour offset, so the first probe lands near the target instead of
  /// systematically overshooting.
  static const double roadWindingFactor = 1.25;

  /// A loop must enclose at least this fraction of the area a circle of the
  /// same perimeter would.
  static const double _minAreaFractionOfCircle = 0.02;

  /// Whether [seg] encloses real ground rather than doubling back on itself.
  ///
  /// **This exists because of a reported bug.** A closed-circuit search could
  /// return a "route" that ran up a road and back down it — real ORS
  /// geometry, correct distance, and no enclosed area at all, because the two
  /// offset waypoints had road-snapped onto the same street. The shoelace
  /// area of an out-and-back cancels to roughly zero, so comparing against
  /// the area a circle of the same perimeter would enclose catches it.
  ///
  /// The 2% floor is deliberately generous: even a lopsided 10:1 rectangle
  /// clears it several times over, so only a genuinely degenerate shape is
  /// rejected.
  static bool enclosesRealArea(RouteSegment seg) {
    if (seg.polyline.length < 4 || seg.distanceMeters <= 0) return false;
    final area = GeometryUtils.polygonAreaM2(seg.polyline);
    final maxCircularArea =
        (seg.distanceMeters * seg.distanceMeters) / (4 * math.pi);
    return area >= maxCircularArea * _minAreaFractionOfCircle;
  }

  /// The mean of [points]. Not a true polygon centroid — an unweighted mean
  /// of the vertices, which is all the duplicate check below needs.
  static LatLng polylineCentroid(List<LatLng> points) {
    var lat = 0.0, lng = 0.0;
    for (final p in points) {
      lat += p.latitude;
      lng += p.longitude;
    }
    return LatLng(lat / points.length, lng / points.length);
  }

  /// Drops candidates that are near-duplicates of one already kept — same
  /// length to within 3% *and* centroids within `max(60 m, 2% of length)`.
  ///
  /// Both halves are required. Two genuinely different loops of the same
  /// length are common (different directions from the same start), and so are
  /// two routes over the same streets at different lengths; only agreeing on
  /// both means the user would be offered the same route twice.
  ///
  /// Order matters: the first of a duplicate pair is the one kept, so callers
  /// should pass their preferred candidate first.
  static List<RouteSegment> dedupeSimilar(List<RouteSegment> segments) {
    final kept = <RouteSegment>[];
    final centroids = <LatLng>[];
    const dist = Distance();
    for (final s in segments) {
      final c = polylineCentroid(s.polyline);
      var isDup = false;
      for (var i = 0; i < kept.length; i++) {
        final lengthGap = (kept[i].distanceMeters - s.distanceMeters).abs() /
            math.max(kept[i].distanceMeters, s.distanceMeters);
        if (lengthGap > 0.03) continue;
        if (dist(centroids[i], c) <= math.max(60.0, s.distanceMeters * 0.02)) {
          isDup = true;
          break;
        }
      }
      if (!isDup) {
        kept.add(s);
        centroids.add(c);
      }
    }
    return kept;
  }

  /// Resolves the three optional constraint fields into one target.
  ///
  /// [units] converts the *typed* distance and energy, which are in whatever
  /// units the user chose; time is unitless minutes. Everything downstream —
  /// every generator, [matchTolerance] — is metric, so converting at this one
  /// boundary is what keeps the search logic unit-agnostic.
  static RouteTarget deriveTarget({
    required String timeText,
    required String distanceText,
    required String caloriesText,
    required UnitFormatter units,
  }) {
    final typedTime = double.tryParse(timeText.trim());
    final fromTime = typedTime == null ? null : typedTime / paceMinPerKm;

    final typedDist = double.tryParse(distanceText.trim());
    final fromDist =
        typedDist == null ? null : units.majorToMeters(typedDist) / 1000.0;

    final typedCal = double.tryParse(caloriesText.trim());
    final fromCal =
        typedCal == null ? null : units.displayToKcal(typedCal) / calPerKm;

    final targets = [fromTime, fromDist, fromCal].whereType<double>().toList();
    if (targets.isEmpty) return const RouteTarget.empty();

    if (targets.length > 1) {
      final minV = targets.reduce(math.min);
      final maxV = targets.reduce(math.max);
      if (minV > 0 && (maxV - minV) / minV > conflictTolerance) {
        return const RouteTarget.conflict();
      }
    }

    return RouteTarget.resolved(
      targets.reduce((a, b) => a + b) / targets.length,
    );
  }

  /// A point [distanceM] from [center] along [bearingDeg] (0 = north).
  ///
  /// A flat-earth approximation, which is what the padding solver wants: it
  /// is used to place a synthetic detour waypoint a few hundred metres away,
  /// where the error is far below the road network's own granularity.
  static LatLng offset(LatLng center, double distanceM, double bearingDeg) {
    final rad = bearingDeg * math.pi / 180;
    const mPerLat = 110540.0;
    final mPerLng = 111320.0 * math.cos(center.latitude * math.pi / 180);
    return LatLng(
      center.latitude + (distanceM * math.cos(rad)) / mPerLat,
      center.longitude + (distanceM * math.sin(rad)) / mPerLng,
    );
  }

  /// Total distance in kilometres once [laps] repetitions are counted.
  ///
  /// The loop finder searches for a *per-lap* size (the total target divided
  /// by the lap count), so the measured single-loop distance has to be
  /// multiplied back up before it is shown — otherwise a 3-lap 12 km search
  /// reports its result as 4 km.
  static double totalKm(double singleLoopMeters, {int laps = 1}) =>
      (singleLoopMeters / 1000) * laps;
}
