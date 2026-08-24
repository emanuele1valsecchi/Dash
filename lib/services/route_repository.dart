import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

/// A single user-created route as stored in Firestore.
class SavedRoute {
  final String id;
  final String name;
  final double distanceMeters;
  final double estimatedTimeMin;
  final double estimatedCalories;
  final bool isLoop;
  final double loopAreaM2;
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
    required this.name,
    required this.distanceMeters,
    required this.estimatedTimeMin,
    required this.estimatedCalories,
    required this.isLoop,
    required this.loopAreaM2,
    required this.routePolyline,
    required this.createdAt,
    this.sourceSessionId,
  });

  factory SavedRoute.fromDoc(QueryDocumentSnapshot doc) {
    final d = doc.data() as Map<String, dynamic>;

    List<LatLng> toLatLngs(String field) {
      final raw = (d[field] as List<dynamic>?) ?? [];
      return raw.map((p) {
        final gp = p as GeoPoint;
        return LatLng(gp.latitude, gp.longitude);
      }).toList();
    }

    return SavedRoute(
      id: doc.id,
      name: d['name'] as String? ?? 'Unnamed route',
      distanceMeters: (d['distanceMeters'] as num?)?.toDouble() ?? 0.0,
      estimatedTimeMin: (d['estimatedTimeMin'] as num?)?.toDouble() ?? 0.0,
      estimatedCalories: (d['estimatedCalories'] as num?)?.toDouble() ?? 0.0,
      isLoop: d['isLoop'] as bool? ?? false,
      loopAreaM2: (d['loopAreaM2'] as num?)?.toDouble() ?? 0.0,
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
      'isPublic': false,
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
    final snap = await _db
        .collection('routes')
        .where('userId', isEqualTo: _uid)
        .get();
    final list = snap.docs.map(SavedRoute.fromDoc).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    _cache = list;
    return list;
  }

  /// Deletes a route from Firestore and removes it from the local cache.
  Future<void> deleteRoute(String id) async {
    await _db.collection('routes').doc(id).delete();
    _cache?.removeWhere((r) => r.id == id);
  }
}
