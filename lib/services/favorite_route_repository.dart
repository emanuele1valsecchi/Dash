import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import 'route_repository.dart';

/// Gateway for favouriting another (or the same) user's run — from its
/// [RunSessionDetailPage] — as a route the current user can re-run later.
///
/// ## One shared route document, many per-user links
///
/// A favourited run is stored ONCE, not once per user who favourites it.
/// The geometry goes into a single `routes` doc whose **document ID is the
/// source session's ID**, and each user who favourites that run gets only a
/// small `favoriteRoutes/{uid}_{sessionId}` link pointing at it.
///
/// The deterministic ID is what makes this work without a lookup: two users
/// favouriting the same run independently compute the same document ID, so
/// the second one finds the route already there instead of creating a
/// near-identical duplicate. Previously every favourite published its own
/// full copy of the path, so a run favourited by four users cost four copies
/// of the same polyline.
///
/// ## Writes are server-side, and that is a security boundary
///
/// Creating a favourite goes through the `favoriteSession` Cloud Function,
/// and `firestore.rules` denies the client every write to a shared route and
/// to the link. **Only an ID and a display name ever cross the wire — never
/// geometry.** A shared route is read by *other* users, and no Firestore rule
/// can verify that a client-supplied polyline is really the run it claims to
/// be; a client-writable shared route would let anyone pre-create
/// `routes/{sessionId}` for a not-yet-favourited run and poison what every
/// later user sees. The server reads the `runningSessions` doc itself and
/// copies every stored value out of it.
///
/// The shared doc deliberately has **no owner and no name**:
///  * no `userId`, so it never appears in [RouteRepository.fetchUserRoutes]
///    (which queries by owner) and no single user can rename, overwrite or
///    delete geometry the others reference;
///  * the *name* is per-user and lives on each `favoriteRoutes` link, so two
///    users can call the same route whatever they like. That link also
///    carries a denormalized summary (distance, time, loop flag) so a list
///    can be rendered from a single query, without loading a polyline per
///    row — written by the server, so it can't be falsified either.
///
/// Because the shared doc outlives any one favourite, un-favouriting deletes
/// only the link — never the route, which other users may still reference.
///
/// This is why the flow no longer goes through [RouteRepository.publishRoute]
/// the way it used to: that method creates an *owned* route under an
/// auto-generated ID, which is exactly what the sharing model replaces. It
/// is still the right call for a route the user genuinely authored (planned
/// by hand, or saved from a parameter search) — those stay owned copies.
class FavoriteRouteRepository {
  static final FavoriteRouteRepository instance = FavoriteRouteRepository._();
  FavoriteRouteRepository._();

  final _db = FirebaseFirestore.instance;
  final _auth = FirebaseAuth.instance;

  /// Same region as every other callable in this app (see `RoutingService`).
  final _functions = FirebaseFunctions.instanceFor(region: 'europe-west1');

  String get _uid => _auth.currentUser!.uid;

  /// Cached favourites for the signed-in user, invalidated on every
  /// favourite/un-favourite — same one-time-read, cache-and-invalidate
  /// pattern as [RouteRepository], for the same reason (route lists change
  /// rarely, and a live listener would cost bandwidth mid-run).
  List<SavedRoute>? _cache;

  String _linkId(String routeId) => '${_uid}_$routeId';

  /// Whether the signed-in user has already favourited [sessionId].
  ///
  /// A single document read: the link's ID is fully determined by the user
  /// and the session, so this needs no query and no index — and, unlike the
  /// previous approach of scanning the user's whole route list for a
  /// matching `sourceSessionId`, it cannot go stale behind a cache.
  Future<bool> isFavorited(String sessionId) async {
    final snap =
        await _db.collection('favoriteRoutes').doc(_linkId(sessionId)).get();
    return snap.exists;
  }

  /// Favourites [sessionId] for the signed-in user.
  ///
  /// Delegates to the `favoriteSession` Cloud Function, which creates the
  /// shared route (if this is the first time anyone favourited this run) and
  /// the caller's link together, in one transaction.
  ///
  /// **Only an ID and a display name cross the wire — never geometry.** The
  /// shared route is read by other users, and no Firestore rule can check
  /// that a client-supplied polyline really is the run it claims to be, so
  /// the server reads the `runningSessions` doc itself and copies every
  /// stored value out of it. See `firestore.rules`' routes block, which
  /// denies the client any write to a shared route.
  ///
  /// [routeName] is this user's own name for it and is stored on their link,
  /// never on the shared route.
  Future<void> favoriteSession(
    String sessionId, {
    required String routeName,
  }) async {
    await _functions.httpsCallable('favoriteSession').call<dynamic>({
      'sessionId': sessionId,
      'name': routeName,
    });
    _cache = null;
  }

  /// Un-favourites [routeId] (== the source session's ID) by deleting only
  /// this user's link.
  ///
  /// The shared route document is deliberately left in place: other users'
  /// favourites may point at it, and it is not this user's to delete.
  /// Reclaiming routes that nobody references any more is a separate
  /// concern — one shared doc is small and bounded by the number of runs
  /// ever favourited, not by the number of users.
  Future<void> unfavoriteRoute(String routeId) async {
    await _db.collection('favoriteRoutes').doc(_linkId(routeId)).delete();
    _cache = null;
  }

  /// Renames the signed-in user's own favourite. Only their link changes —
  /// every other user's name for the same route is untouched.
  Future<void> renameFavorite(String routeId, String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    await _db
        .collection('favoriteRoutes')
        .doc(_linkId(routeId))
        .update({'name': trimmed});
    _cache = null;
  }

  /// The signed-in user's favourites, newest first, each with the shared
  /// route's geometry resolved so callers can draw a map preview.
  ///
  /// Returns [SavedRoute] rather than a separate model so existing route
  /// list UIs render a favourite and an owned route identically; `name`
  /// comes from this user's link, everything else from the shared route.
  ///
  /// Callers that only need to *list* favourites (name, distance, loop flag)
  /// can read those straight off the link documents instead — they are
  /// denormalized there precisely so that path costs one query and no
  /// polylines. This method pays for the geometry because its current
  /// callers draw map previews.
  Future<List<SavedRoute>> fetchFavorites() async {
    if (_cache != null) return _cache!;

    final links = await _db
        .collection('favoriteRoutes')
        .where('userId', isEqualTo: _uid)
        .get();

    if (links.docs.isEmpty) {
      _cache = const [];
      return _cache!;
    }

    // Sorted client-side (newest first) to avoid a composite index on
    // (userId, createdAt) — same trade-off as RouteRepository.fetchUserRoutes.
    final ordered = links.docs.toList()
      ..sort((a, b) {
        final at = a.data()['createdAt'] as Timestamp?;
        final bt = b.data()['createdAt'] as Timestamp?;
        if (at == null && bt == null) return 0;
        if (at == null) return -1; // just-written, server timestamp pending
        if (bt == null) return 1;
        return bt.compareTo(at);
      });

    final routes = <SavedRoute>[];
    for (final link in ordered) {
      final data = link.data();
      final routeId = data['routeId'] as String?;
      if (routeId == null) continue;

      // One unreadable route must not take the whole list down with it —
      // a favourites list that renders all but one row beats a page that
      // fails outright.
      try {
        final routeSnap = await _db.collection('routes').doc(routeId).get();
        if (!routeSnap.exists) continue; // shared route gone — skip it.

        routes.add(
          SavedRoute.fromSharedRoute(
            routeSnap,
            name: data['name'] as String? ?? 'Favourited run',
          ),
        );
      } catch (e) {
        debugPrint('Skipping favourite $routeId: $e');
      }
    }

    _cache = routes;
    return routes;
  }

  /// Drops the cached favourites so the next [fetchFavorites] re-reads.
  void invalidateCache() => _cache = null;
}
