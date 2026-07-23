import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

/// A single completed, live-tracked run as stored in the `runningSessions`
/// Firestore collection.
///
/// This is deliberately a different collection from `routes`
/// ([RouteRepository]): a `routes` doc is a *planned* path the user built on
/// the map before running it, while a `runningSessions` doc is the record of
/// a run the user actually completed with GPS tracking. Points/XP, missions
/// and the homepage "recent runs" list are meant to read from this
/// collection, never from `routes`.
///
/// Firestore rules force `pointsEarned == 0` on client-side create — real
/// point awarding is expected to happen server-side (Cloud Function) once
/// that logic exists.
class RunSession {
  final String id;
  final String name;
  final double distanceMeters;
  final Duration duration;
  final double avgPaceMinPerKm;
  final double? maxPaceMinPerKm;
  final double caloriesBurned;
  final double elevationDifferenceMeters;
  final int loopsCompleted;
  final List<LatLng> path;
  final DateTime createdAt;

  const RunSession({
    required this.id,
    required this.name,
    required this.distanceMeters,
    required this.duration,
    required this.avgPaceMinPerKm,
    required this.maxPaceMinPerKm,
    required this.caloriesBurned,
    required this.elevationDifferenceMeters,
    required this.loopsCompleted,
    required this.path,
    required this.createdAt,
  });

  factory RunSession.fromDoc(QueryDocumentSnapshot doc) {
    final d = doc.data() as Map<String, dynamic>;

    final rawPath = (d['path'] as List<dynamic>?) ?? [];
    final path = rawPath
        .map((p) => LatLng((p as GeoPoint).latitude, p.longitude))
        .toList();

    return RunSession(
      id: doc.id,
      name: d['name'] as String? ?? 'Untitled run',
      distanceMeters: (d['distanceMeters'] as num?)?.toDouble() ?? 0.0,
      duration: Duration(milliseconds: (d['durationMs'] as num?)?.toInt() ?? 0),
      avgPaceMinPerKm: (d['avgPaceMinPerKm'] as num?)?.toDouble() ?? 0.0,
      maxPaceMinPerKm: (d['maxPaceMinPerKm'] as num?)?.toDouble(),
      caloriesBurned: (d['caloriesBurned'] as num?)?.toDouble() ?? 0.0,
      elevationDifferenceMeters:
          (d['elevationDifferenceMeters'] as num?)?.toDouble() ?? 0.0,
      loopsCompleted: (d['loopsCompleted'] as num?)?.toInt() ?? 0,
      path: path,
      createdAt: d['createdAt'] != null
          ? (d['createdAt'] as Timestamp).toDate()
          : DateTime.now(),
    );
  }
}

class RunSessionRepository {
  static final RunSessionRepository instance = RunSessionRepository._();
  RunSessionRepository._();

  final _db = FirebaseFirestore.instance;
  final _auth = FirebaseAuth.instance;

  String get _uid => _auth.currentUser!.uid;

  /// Persists a finished run and returns the new doc's ID — callers that need
  /// to observe the async server-side scoring (see
  /// `onRunningSessionCreateClaimedAreas` in `functions/index.js`, which sets
  /// `pointsEarned`/territory/`pointsProcessed` on this same doc after it's
  /// created) need the ID to listen on, e.g. `showRunResultsDialog`.
  ///
  /// [closedLoops] are stored as an array of maps (`{'points': [...]}`)
  /// rather than a raw array-of-arrays — Firestore does not support nested
  /// arrays.
  ///
  /// Also best-effort reverse-geocodes the run's starting point to a raw
  /// locality name (`startLocality`, e.g. "Seregno") via Nominatim. This is
  /// deliberately just the raw place name for display — scoreboard territory
  /// placement is separate, server-computed logic (see `functions/territory.js`)
  /// keyed off real coordinates, not this string.
  Future<String> saveSession({
    required String name,
    required double distanceMeters,
    required Duration duration,
    required double avgPaceMinPerKm,
    double? maxPaceMinPerKm,
    required double caloriesBurned,
    required double elevationDifferenceMeters,
    required int loopsCompleted,
    required List<LatLng> path,
    required List<List<LatLng>> closedLoops,
  }) async {
    final startLocality =
        path.isEmpty ? null : await _reverseGeocodeLocality(path.first);

    final docRef = await _db.collection('runningSessions').add({
      'userId': _uid,
      'name': name.trim().isEmpty ? 'Untitled run' : name.trim(),
      'distanceMeters': distanceMeters,
      'durationMs': duration.inMilliseconds,
      'avgPaceMinPerKm': avgPaceMinPerKm,
      'maxPaceMinPerKm': maxPaceMinPerKm,
      'caloriesBurned': caloriesBurned,
      'elevationDifferenceMeters': elevationDifferenceMeters,
      'loopsCompleted': loopsCompleted,
      'path': path.map((p) => GeoPoint(p.latitude, p.longitude)).toList(),
      'closedLoops': closedLoops
          .map((poly) => {
                'points':
                    poly.map((p) => GeoPoint(p.latitude, p.longitude)).toList(),
              })
          .toList(),
      'startLocality': startLocality,
      'pointsEarned': 0,
      'createdAt': FieldValue.serverTimestamp(),
    });
    return docRef.id;
  }

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
      // Best-effort only — a run should still save if reverse geocoding
      // fails or Nominatim is unreachable.
      return null;
    }
  }

  /// Returns the current user's completed runs, newest first.
  Future<List<RunSession>> fetchUserSessions() async {
    final snap = await _db
        .collection('runningSessions')
        .where('userId', isEqualTo: _uid)
        .get();
    final list = snap.docs.map(RunSession.fromDoc).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list;
  }
}
