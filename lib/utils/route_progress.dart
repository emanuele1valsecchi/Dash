import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import 'geometry_utils.dart';

/// How much of a planned route the runner has actually covered.
///
/// A snapshot of [RouteProgressTracker]'s state, kept as a plain value object
/// (no Flutter dependency) for the same reason [RouteGuidance] is: the same
/// computation should be able to drive a smartwatch face later without
/// dragging `RunTrackingPage` along with it.
class RouteProgress {
  /// How many checkpoints the runner has passed, in order.
  final int reached;

  /// How many the route was divided into. Zero when the route was too short
  /// (or too degenerate) to place any, in which case [isCovered] is always
  /// true and this gate effectively disables itself.
  final int total;

  const RouteProgress({required this.reached, required this.total});

  /// True once every checkpoint has been passed — the precondition for
  /// telling the runner they have finished. Vacuously true when there are no
  /// checkpoints to pass.
  bool get isCovered => reached >= total;

  int get remaining => (total - reached).clamp(0, total);

  double get fraction => total == 0 ? 1 : reached / total;
}

/// Tracks a runner's progress through a planned route as an ordered sequence
/// of checkpoints, so "you have arrived" can be gated on having actually gone
/// round rather than merely being near the finish.
///
/// **The problem this exists to solve.** Arrival used to be a pure proximity
/// test — remaining route distance under ~20 m. On a closed loop, where
/// `route.first` and `route.last` are the same place, that is already true
/// before the runner takes a single step, and a field test duly reported
/// "Route complete" appearing immediately on a route whose start and finish
/// were set to the same point (the way most people will use the app).
/// Proximity to the finish simply cannot distinguish "hasn't started" from
/// "has come all the way round"; only progress *through* the route can.
///
/// **Why ordered, and why a look-ahead window.** Checkpoints must be reached
/// in sequence, because an unordered proximity test reintroduces the very bug
/// above from the other end: on a small loop the *last* checkpoint can sit
/// well within [visitRadiusMeters] of the start as the crow flies, across the
/// loop's interior, and would be ticked off before the runner moves. Ordering
/// makes that impossible — the last checkpoint is unreachable until its
/// predecessors have been. Strict ordering alone would be too rigid, though:
/// a runner who cuts a roundabout at the crosswalk (also reported from the
/// same field test) can legitimately miss one checkpoint, and blocking on it
/// forever would leave them permanently short of the finish. So the pointer
/// may jump forward by up to [_lookAheadCheckpoints], which absorbs a cut
/// corner while still refusing to skip a whole limb of the route.
///
/// **Known limitation.** A runner who joins the route partway along — rather
/// than at its start, which is what both "Run now" flows actually do — can
/// never reach the checkpoints already behind them, so the completion banner
/// simply never fires for that run. Everything else (the arrow, distance
/// remaining, off-route detection) is unaffected. Degrading to "no banner" is
/// deliberate: it is strictly better than the false "Route complete" it
/// replaces, and gating on the runner's own accumulated distance instead
/// would hand the decision back to a measurement that says nothing about
/// *where* they went.
class RouteProgressTracker {
  /// Roughly how far apart to place checkpoints along the route. Fine enough
  /// that a short loop still gets a meaningful gate, coarse enough that a
  /// long route does not accumulate hundreds of them.
  static const double _spacingMeters = 150;

  /// Bounds on the resulting count, so neither a 200 m loop nor a 20 km route
  /// ends up with a nonsensical number of checkpoints.
  static const int _minCheckpoints = 3;
  static const int _maxCheckpoints = 12;

  /// How close the runner must come to count a checkpoint as passed. Generous
  /// enough to absorb consumer-GPS error plus running on the far pavement of a
  /// wide road — the same reasoning behind route guidance's own 25 m
  /// off-route threshold.
  static const double defaultVisitRadiusMeters = 35;

  /// How far ahead of the next expected checkpoint the runner may be picked
  /// up. One skipped checkpoint is a cut corner; three would be a shortcut
  /// past a whole section of the route.
  static const int _lookAheadCheckpoints = 2;

  final List<LatLng> checkpoints;
  final double visitRadiusMeters;

  int _reached = 0;

  RouteProgressTracker(
    List<LatLng> route, {
    this.visitRadiusMeters = defaultVisitRadiusMeters,
  }) : checkpoints = _placeCheckpoints(route);

  /// Checkpoints evenly spaced along [route] by *cumulative distance*, both
  /// endpoints deliberately excluded — [GeometryUtils.arrowPositions] already
  /// samples exactly this way for the direction arrows on a run's detail map,
  /// and skipping the endpoints is what this needs too: a checkpoint at the
  /// start would be passed before the runner moves, and one at the finish
  /// would duplicate the proximity test this gate wraps.
  static List<LatLng> _placeCheckpoints(List<LatLng> route) {
    if (route.length < 2) return const [];

    const dist = Distance();
    var total = 0.0;
    for (int i = 1; i < route.length; i++) {
      total += dist(route[i - 1], route[i]);
    }
    if (total <= 0) return const [];

    final count = (total / _spacingMeters)
        .floor()
        .clamp(_minCheckpoints, _maxCheckpoints);

    return GeometryUtils.arrowPositions(route, count: count)
        .map((a) => a.point)
        .toList(growable: false);
  }

  /// How far ahead the window actually reaches, which is *not* simply
  /// [_lookAheadCheckpoints]: on a route with only a handful of checkpoints
  /// that constant would span the whole thing, and the ordering this class
  /// depends on would quietly stop applying — the last checkpoint would once
  /// again be claimable from the start line, which is the exact bug ordering
  /// exists to prevent. Capping it at half the route keeps a look-ahead of
  /// "one cut corner" proportional on short routes and full-strength on long
  /// ones.
  int get _lookAhead =>
      math.min(_lookAheadCheckpoints, (checkpoints.length - 1) ~/ 2);

  /// Advances the pointer if [position] has reached the next expected
  /// checkpoint, or one within the look-ahead window. Cheap enough to call on
  /// every GPS fix: it tests at most [_lookAheadCheckpoints] + 1 points.
  void update(LatLng position) {
    if (_reached >= checkpoints.length) return;

    const dist = Distance();
    final last = (_reached + _lookAhead).clamp(0, checkpoints.length - 1);

    // Scan the window from its far end back, so a runner who has genuinely
    // passed several checkpoints between two fixes lands on the furthest one
    // rather than re-acquiring the nearest and advancing only a single step.
    for (int i = last; i >= _reached; i--) {
      if (dist(position, checkpoints[i]) <= visitRadiusMeters) {
        _reached = i + 1;
        return;
      }
    }
  }

  RouteProgress get progress =>
      RouteProgress(reached: _reached, total: checkpoints.length);
}
