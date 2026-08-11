import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'route_repository.dart';
import 'run_session_repository.dart';

/// Gateway for favouriting another (or the same) user's run — from its
/// [RunSessionDetailPage] — as a route the current user can re-run later.
///
/// Spans two collections that this one flow always keeps in lockstep:
/// favouriting publishes a new `routes` doc via
/// [RouteRepository.publishRoute] — using the *whole* session's own path,
/// not just whatever loop it happened to claim, and owned by the *current*
/// signed-in user, not the original runner, since that's the only way to
/// get a runnable route out of someone else's run in the first place —
/// tagged with `sourceSessionId` (see [SavedRoute.sourceSessionId]), then
/// links it with a `favoriteRoutes` doc. Un-favouriting deletes both: the
/// route only ever existed as a byproduct of favouriting this session, so
/// nothing of the user's own is lost by not leaving an unfavourited copy
/// behind.
///
/// Deliberately reuses [RouteRepository.publishRoute]/`deleteRoute` rather
/// than writing to `routes` directly, so this stays in lockstep with
/// whatever those already do (cache invalidation, field shape) instead of a
/// second, drifting copy of that logic.
class FavoriteRouteRepository {
  static final FavoriteRouteRepository instance = FavoriteRouteRepository._();
  FavoriteRouteRepository._();

  final _db = FirebaseFirestore.instance;
  final _auth = FirebaseAuth.instance;

  String get _uid => _auth.currentUser!.uid;

  /// Publishes [session]'s whole path as a new route owned by the current
  /// user and favourites it. Returns the new route's id.
  Future<String> favoriteSessionAsRoute(
    RunSession session, {
    required String routeName,
  }) async {
    final routeId = await RouteRepository.instance.publishRoute(
      name: routeName,
      waypoints: session.path,
      routePolyline: session.path,
      distanceMeters: session.distanceMeters,
      // The run's own real observed values, not distance-based estimates —
      // we actually know them, unlike for a not-yet-run planned route.
      estimatedTimeMin: session.duration.inMilliseconds / 60000.0,
      estimatedCalories: session.caloriesBurned,
      isLoop: session.loopsCompleted > 0,
      loopAreaM2: session.totalAreaM2,
      sourceSessionId: session.id,
    );
    await _db.collection('favoriteRoutes').doc('${_uid}_$routeId').set({
      'userId': _uid,
      'routeId': routeId,
      'createdAt': FieldValue.serverTimestamp(),
    });
    return routeId;
  }

  /// Un-favourites [routeId] — deletes the `favoriteRoutes` link first, then
  /// the `routes` doc it pointed at (see class doc for why removing both,
  /// not just the link, is correct here). That order, specifically: if only
  /// one delete succeeds, better to be left with an orphaned-but-harmless
  /// unfavourited route than a `favoriteRoutes` doc dangling on a route that
  /// no longer exists.
  Future<void> unfavoriteRoute(String routeId) async {
    await _db.collection('favoriteRoutes').doc('${_uid}_$routeId').delete();
    await RouteRepository.instance.deleteRoute(routeId);
  }
}
