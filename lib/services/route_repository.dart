import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

/// A single user-created route as stored in Firestore.
class SavedRoute {
  final String id;

  /// Who owns this route, or **null for a shared session route** — the
  /// ownerless doc many users' favourites point at (see
  /// `FavoriteRouteRepository`), which stores `userId` as an explicit null
  /// rather than omitting it.
  ///
  /// Read by UI that has to decide whether the *viewer* may act on a route
  /// they can see: any signed-in user can now read any route (profiles show
  /// other people's), but only its owner may rename or delete it.
  final String? userId;

  final String name;
  final double distanceMeters;
  final double estimatedTimeMin;
  final double estimatedCalories;
  final bool isLoop;
  final double loopAreaM2;

  /// Whether anyone other than the owner may see this route.
  ///
  /// For an *owned* route this is the author's choice, made once when the
  /// route is saved and **permanent thereafter** — there is no toggle, and
  /// `firestore.rules` pins the field on update rather than leaving that to
  /// the UI. It decides whether the route appears on their profile for other
  /// people. For a *shared session route* it is always true, which is what
  /// lets every user who favourited that run read the one shared copy.
  ///
  /// **Defaults to false for a document written before the field existed** —
  /// private is the safe reading of "the author never opted in", and
  /// `firestore.rules` makes the same assumption.
  final bool isPublic;
  final List<LatLng> routePolyline;
  final DateTime createdAt;

  /// Set only for a route created by favouriting another (or the same)
  /// user's run from its detail page (see `FavoriteRouteRepository`) — the
  /// `runningSessions` id it was built from, used to detect "have I already
  /// favourited this session" without a second collection needing its own
  /// index.
  final String? sourceSessionId;

  double get distanceKm => distanceMeters / 1000;

  const SavedRoute({
    required this.id,
    required this.userId,
    required this.name,
    required this.distanceMeters,
    required this.estimatedTimeMin,
    required this.estimatedCalories,
    required this.isLoop,
    required this.loopAreaM2,
    required this.isPublic,
    required this.routePolyline,
    required this.createdAt,
    this.sourceSessionId,
  });

  factory SavedRoute.fromDoc(QueryDocumentSnapshot doc) =>
      SavedRoute._fromData(doc.id, doc.data() as Map<String, dynamic>);

  /// Builds a view model for a *shared* session route — the single, ownerless
  /// `routes` doc many users' favourites point at (see
  /// `FavoriteRouteRepository`). That doc carries no `name`, because the name
  /// is per-user and lives on each user's own `favoriteRoutes` link; [name]
  /// is that user's name for it.
  ///
  /// Takes a plain [DocumentSnapshot] rather than a [QueryDocumentSnapshot]
  /// because a shared route is fetched directly by ID, not through a query.
  factory SavedRoute.fromSharedRoute(
    DocumentSnapshot doc, {
    required String name,
  }) =>
      SavedRoute._fromData(
        doc.id,
        (doc.data() as Map<String, dynamic>? ?? const {}),
        nameOverride: name,
      );

  factory SavedRoute._fromData(
    String id,
    Map<String, dynamic> d, {
    String? nameOverride,
  }) {
    List<LatLng> toLatLngs(String field) {
      final raw = (d[field] as List<dynamic>?) ?? [];
      return raw.map((p) {
        final gp = p as GeoPoint;
        return LatLng(gp.latitude, gp.longitude);
      }).toList();
    }

    return SavedRoute(
      id: id,
      userId: d['userId'] as String?,
      name: nameOverride ?? d['name'] as String? ?? 'Unnamed route',
      distanceMeters: (d['distanceMeters'] as num?)?.toDouble() ?? 0.0,
      estimatedTimeMin: (d['estimatedTimeMin'] as num?)?.toDouble() ?? 0.0,
      estimatedCalories: (d['estimatedCalories'] as num?)?.toDouble() ?? 0.0,
      isLoop: d['isLoop'] as bool? ?? false,
      loopAreaM2: (d['loopAreaM2'] as num?)?.toDouble() ?? 0.0,
      // Missing means private — matching `firestore.rules`' own default.
      isPublic: d['isPublic'] as bool? ?? false,
      routePolyline: toLatLngs('routePolyline'),
      // Server timestamps may be null immediately after write on the same client.
      createdAt: d['createdAt'] != null
          ? (d['createdAt'] as Timestamp).toDate()
          : DateTime.now(),
      sourceSessionId: d['sourceSessionId'] as String?,
    );
  }
}

/// In-memory-cached gateway to the Firestore `routes` collection.
///
/// Uses one-time reads rather than real-time listeners — route lists change
/// infrequently, so a persistent stream would waste bandwidth.  The cache is
/// invalidated on every write or delete so the next read re-fetches from
/// Firestore.
///
/// Sorting is done client-side (newest first) to avoid requiring a composite
/// Firestore index on (userId, createdAt).
class RouteRepository {
  static final RouteRepository instance = RouteRepository._();
  RouteRepository._();

  final _db = FirebaseFirestore.instance;
  final _auth = FirebaseAuth.instance;

  List<SavedRoute>? _cache;

  String get _uid => _auth.currentUser!.uid;

  /// Saves a new route document and invalidates the local cache. Returns the
  /// new document's id (e.g. for `FavoriteRouteRepository` to link a
  /// `favoriteRoutes` doc to it).
  ///
  /// [waypoints] are the raw user tap-points; [routePolyline] is the merged
  /// road-snapped polyline built from all segments.  Firestore rules protect
  /// both fields from client-side mutation after creation. [sourceSessionId],
  /// when set, marks this route as having been created by favouriting a run
  /// (see `SavedRoute.sourceSessionId`) rather than drawn/planned by hand.
  ///
  /// Also best-effort reverse-geocodes the route's starting point to a raw
  /// locality name (`startLocality`, e.g. "Seregno") via Nominatim — same
  /// field, same source, same fire-and-forget-on-failure behaviour as
  /// `RunSessionRepository.saveSession`'s `startLocality`.
  Future<String> publishRoute({
    required String name,
    required List<LatLng> waypoints,
    required List<LatLng> routePolyline,
    required double distanceMeters,
    required double estimatedTimeMin,
    required double estimatedCalories,
    required bool isLoop,
    required double loopAreaM2,
    /// Whether other people may see this route on the author's profile.
    /// **Defaults to private** — publishing is an explicit choice, and a
    /// caller that forgets to ask cannot accidentally expose one.
    ///
    /// This is the only place it is ever set: the choice is permanent, and
    /// `firestore.rules` pins `isPublic` on update. A user who changes their
    /// mind deletes the route and saves it again.
    bool isPublic = false,
    String? sourceSessionId,
  }) async {
    final startLocality = routePolyline.isEmpty
        ? null
        : await _reverseGeocodeLocality(routePolyline.first);

    final doc = await _db.collection('routes').add({
      'userId': _uid,
      'name': name.trim().isEmpty ? 'Unnamed route' : name.trim(),
      'waypoints':
          waypoints.map((p) => GeoPoint(p.latitude, p.longitude)).toList(),
      'routePolyline':
          routePolyline.map((p) => GeoPoint(p.latitude, p.longitude)).toList(),
      'distanceMeters': distanceMeters,
      'estimatedTimeMin': estimatedTimeMin,
      'estimatedCalories': estimatedCalories,
      'isLoop': isLoop,
      'loopAreaM2': loopAreaM2,
      'isPublic': isPublic,
      'startLocality': startLocality,
      'createdAt': FieldValue.serverTimestamp(),
      'sourceSessionId': ?sourceSessionId,
    });
    _cache = null;
    return doc.id;
  }

  /// Best-effort Nominatim reverse geocode of [point] down to a raw locality
  /// name — identical in behaviour to
  /// `RunSessionRepository._reverseGeocodeLocality`, kept as a separate copy
  /// rather than a shared helper since the two repositories don't otherwise
  /// depend on each other.
  Future<String?> _reverseGeocodeLocality(LatLng point) async {
    try {
      final uri = Uri.parse(
        'https://nominatim.openstreetmap.org/reverse'
        '?lat=${point.latitude}&lon=${point.longitude}&format=json&zoom=10',
      );
      final response = await http
          .get(uri, headers: {'User-Agent': 'DashApp/1.0'})
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return null;

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final address = data['address'] as Map<String, dynamic>?;
      if (address == null) return null;

      return (address['city'] ??
          address['town'] ??
          address['village'] ??
          address['municipality']) as String?;
    } catch (_) {
      // Best-effort only — a route should still save if reverse geocoding
      // fails or Nominatim is unreachable.
      return null;
    }
  }

  /// Returns the current user's routes, newest first.
  ///
  /// Serves from the in-memory cache when available; hits Firestore only on
  /// first load or after a write/delete.
  Future<List<SavedRoute>> fetchUserRoutes() async {
    if (_cache != null) return _cache!;
    final list = await fetchRoutesForUser(_uid);
    _cache = list;
    return list;
  }

  /// Routes owned by [userId] — **any** user, not only the signed-in one, so
  /// a profile page can show someone else's routes.
  ///
  /// [publicOnly] must be true whenever [userId] is not the signed-in user.
  /// It is not merely a filter: `firestore.rules` only lets a non-owner read a
  /// route with `isPublic == true`, and Firestore rejects a query it cannot
  /// prove is safe — so without the extra `where` the whole query is denied
  /// rather than returning a subset. Two equality filters need no composite
  /// index; Firestore merges the single-field ones.
  ///
  /// Deliberately uncached, unlike [fetchUserRoutes]: this fetches an
  /// arbitrary other user's list on demand, which isn't something worth
  /// holding a warm cache of (same reasoning as
  /// `RunSessionRepository.fetchSessionById`). Callers looking at the signed-in
  /// user's own routes should go through [fetchUserRoutes] to get the cache.
  Future<List<SavedRoute>> fetchRoutesForUser(
    String userId, {
    bool publicOnly = false,
  }) async {
    var query = _db.collection('routes').where('userId', isEqualTo: userId);
    if (publicOnly) {
      query = query.where('isPublic', isEqualTo: true);
    }
    final snap = await query.get();
    // Sorted client-side (newest first) to avoid a composite index on
    // (userId, createdAt).
    return snap.docs.map(SavedRoute.fromDoc).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  /// Renames an owned route.
  ///
  /// `firestore.rules` lets an owner update `name` provided the geometry
  /// fields come back unchanged, which a field-scoped `update` satisfies —
  /// the untouched fields are carried into `request.resource.data` as they
  /// already were.
  ///
  /// **A shared session route cannot be renamed through here**, and the rules
  /// enforce that rather than relying on this method: it has no owner, so
  /// every client write to it is denied. A favourite's name is per-user and
  /// lives on that user's own `favoriteRoutes` link — see
  /// `FavoriteRouteRepository.renameFavorite`.
  Future<void> renameRoute(String id, String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    await _db.collection('routes').doc(id).update({'name': trimmed});
    _cache = null;
  }

  /// Drops the cached routes so the next [fetchUserRoutes] re-reads from
  /// Firestore — mirrors [FavoriteRouteRepository.invalidateCache], and
  /// exists for the same reason: a pull-to-refresh needs a way to say "I
  /// know the cache is warm, fetch anyway".
  void invalidateCache() => _cache = null;

  /// Deletes a route from Firestore and removes it from the local cache.
  Future<void> deleteRoute(String id) async {
    await _db.collection('routes').doc(id).delete();
    _cache?.removeWhere((r) => r.id == id);
  }
}
