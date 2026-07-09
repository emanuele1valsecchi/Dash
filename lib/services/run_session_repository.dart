import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
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

  /// Persists a finished run. [closedLoops] are stored as an array of maps
  /// (`{'points': [...]}`) rather than a raw array-of-arrays — Firestore does
  /// not support nested arrays.
  Future<void> saveSession({
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
    await _db.collection('runningSessions').add({
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
      'pointsEarned': 0,
      'createdAt': FieldValue.serverTimestamp(),
    });
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
