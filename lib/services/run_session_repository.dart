import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../utils/geometry_utils.dart';
import '../utils/run_estimates.dart';

/// The body metrics of one run — what it cost the person, as opposed to where
/// it went.
///
/// Stored in `runningSessions/{sessionId}/private/metrics`, a subcollection
/// only the runner may read, **because the session document itself is
/// readable by every signed-in user** (see the read rule's own comment in
/// `firestore.rules`, and `RunSessionDetailPage`). Firestore cannot restrict
/// individual fields of a readable document, so genuinely private data has to
/// live somewhere with its own rule; hiding a widget is not privacy.
///
/// Currently only heart rate, which a companion watch measures and nothing
/// else can reconstruct. Energy is deliberately *not* here: it is
/// `distance * kCaloriesPerKm` (see [caloriesForDistance]), so storing it
/// privately would protect nothing while adding a second source of truth.
class RunPrivateMetrics {
  final int? avgHeartRateBpm;
  final int? maxHeartRateBpm;

  const RunPrivateMetrics({this.avgHeartRateBpm, this.maxHeartRateBpm});

  bool get isEmpty => avgHeartRateBpm == null && maxHeartRateBpm == null;

  /// The document ID under the session's `private` subcollection. A fixed name
  /// rather than an auto-ID so it can be fetched (and migrated) directly,
  /// without a query.
  static const String docId = 'metrics';

  Map<String, dynamic> toFirestore(String userId) => {
        // Denormalized so the security rule can authorize a read without a
        // get() on the parent session — a rules get() is a billed read on
        // every single evaluation.
        'userId': userId,
        'avgHeartRateBpm': ?avgHeartRateBpm,
        'maxHeartRateBpm': ?maxHeartRateBpm,
      };

  factory RunPrivateMetrics.fromDoc(DocumentSnapshot doc) {
    final d = doc.data() as Map<String, dynamic>? ?? const {};
    return RunPrivateMetrics(
      avgHeartRateBpm: (d['avgHeartRateBpm'] as num?)?.toInt(),
      maxHeartRateBpm: (d['maxHeartRateBpm'] as num?)?.toInt(),
    );
  }
}

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
  final double elevationDifferenceMeters;
  final int loopsCompleted;
  final List<LatLng> path;
  final DateTime createdAt;

  /// Total area claimed across every loop this session closed — written by
  /// `onRunningSessionCreateClaimedAreas`, server-only on the client
  /// (`firestore.rules`' `serverOnlyRunFields`). 0 for a session with no
  /// closed loops, or one whose points/territory haven't finished processing
  /// yet.
  final double totalAreaM2;

  /// Heart rate as it was stored on the *session* document by builds that
  /// predate [RunPrivateMetrics].
  ///
  /// **Legacy read path only, and it is on the public document — which is the
  /// bug the private subcollection exists to fix.** New runs never write these
  /// fields; `functions/_migrate_private_metrics.js` moves the existing ones
  /// into the subcollection and strips them from here. Once that has run
  /// against production, these two fields and their fallback in
  /// `RunSessionDetailPage` can be deleted outright.
  final int? legacyAvgHeartRateBpm;
  final int? legacyMaxHeartRateBpm;

  /// Energy, in kcal — **derived, never stored**. See [caloriesForDistance]
  /// for why.
  double get caloriesBurned => caloriesForDistance(distanceMeters);

  const RunSession({
    required this.id,
    required this.name,
    required this.distanceMeters,
    required this.duration,
    required this.avgPaceMinPerKm,
    required this.maxPaceMinPerKm,
    required this.elevationDifferenceMeters,
    required this.loopsCompleted,
    required this.path,
    required this.createdAt,
    required this.totalAreaM2,
    this.legacyAvgHeartRateBpm,
    this.legacyMaxHeartRateBpm,
  });

  /// [DocumentSnapshot] rather than the narrower [QueryDocumentSnapshot], so
  /// this also works for a single-doc `fetchSessionById` lookup, not only
  /// results from a `.where()` query (`fetchUserSessions`).
  factory RunSession.fromDoc(DocumentSnapshot doc) {
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
      elevationDifferenceMeters:
          (d['elevationDifferenceMeters'] as num?)?.toDouble() ?? 0.0,
      loopsCompleted: (d['loopsCompleted'] as num?)?.toInt() ?? 0,
      path: path,
      createdAt: d['createdAt'] != null
          ? (d['createdAt'] as Timestamp).toDate()
          : DateTime.now(),
      totalAreaM2: (d['totalAreaM2'] as num?)?.toDouble() ?? 0.0,
      legacyAvgHeartRateBpm: (d['avgHeartRateBpm'] as num?)?.toInt(),
      legacyMaxHeartRateBpm: (d['maxHeartRateBpm'] as num?)?.toInt(),
    );
  }
}

class RunSessionRepository {
  static final RunSessionRepository instance = RunSessionRepository._();
  /// Collaborators default to the real Firebase singletons, so
  /// `RunSessionRepository.instance` behaves exactly as it always has and no
  /// call site changes. They are only ever passed by tests.
  RunSessionRepository._({
    FirebaseFirestore? db,
    FirebaseAuth? auth,
    http.Client? httpClient,
  })  : _db = db ?? FirebaseFirestore.instance,
        _auth = auth ?? FirebaseAuth.instance,
        // `this._httpClient` is unavailable: Dart forbids a private name as a
        // named parameter, and this stays named to match the other two.
        // ignore: prefer_initializing_formals
        _httpClient = httpClient;

  /// A repository wired to test doubles (`FakeFirebaseFirestore`,
  /// `MockFirebaseAuth`).
  ///
  /// **This is the seam that makes the data layer testable.** Reading
  /// `FirebaseFirestore.instance` in a field initializer, as this class
  /// used to, cannot be substituted from a test: there is no
  /// `Firebase.initializeApp` in the test binding, so touching it throws
  /// before a single assertion runs.
  ///
  /// A named constructor rather than a public `RunSessionRepository()`: the singleton stays
  /// the only way production code gets one, so this cannot quietly become
  /// a second live instance with its own cache.
  @visibleForTesting
  factory RunSessionRepository.withDependencies({
    FirebaseFirestore? db,
    FirebaseAuth? auth,
    http.Client? httpClient,
  }) =>
      RunSessionRepository._(db: db, auth: auth, httpClient: httpClient);

  final FirebaseFirestore _db;
  final FirebaseAuth _auth;

  /// Null in production, where the reverse-geocode makes its own one-shot
  /// request exactly as before. Injected by tests so it never hits Nominatim.
  final http.Client? _httpClient;

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
  ///
  /// [path] is Douglas-Peucker simplified before storage (see
  /// [GeometryUtils.simplifyPolyline] for why the live 2 m breadcrumb
  /// resolution is far finer than anything worth archiving). This is safe
  /// against every consumer of the stored path: `distanceMeters` and the pace
  /// stats are passed in already measured from the *raw* breadcrumb stream
  /// and are never recomputed from this field; territory resolution keys off
  /// `path[0]`, which simplification always preserves; everything else — the
  /// detail-page preview, favouriting the run as a route — is display.
  ///
  /// [closedLoops] are deliberately stored raw. Their boundaries are what
  /// `onRunningSessionCreateClaimedAreas` computes claimed area and XP from,
  /// so moving them even slightly would change a score the client must not
  /// influence.
  ///
  /// **Heart rate does not go on the session document.** It goes into the
  /// `private/metrics` subcollection ([RunPrivateMetrics]), which only the
  /// runner may read — the session itself is readable by every signed-in
  /// user, and Firestore cannot hide individual fields of a readable
  /// document. Both writes go in one [WriteBatch], so a run can never exist
  /// with its metrics half-written.
  ///
  /// **Energy is not stored at all**, in either place: it is
  /// `distance * kCaloriesPerKm` and is derived on read (see
  /// [caloriesForDistance]).
  Future<String> saveSession({
    required String name,
    required double distanceMeters,
    required Duration duration,
    required double avgPaceMinPerKm,
    double? maxPaceMinPerKm,
    required double elevationDifferenceMeters,
    required int loopsCompleted,
    required List<LatLng> path,
    required List<List<LatLng>> closedLoops,
    int? avgHeartRateBpm,
    int? maxHeartRateBpm,
  }) async {
    final storedPath = GeometryUtils.simplifyPolyline(path);

    final startLocality =
        path.isEmpty ? null : await _reverseGeocodeLocality(path.first);

    // The ID is needed before the write, to address the subcollection in the
    // same batch — so the ref is created locally rather than via add().
    final docRef = _db.collection('runningSessions').doc();
    final batch = _db.batch();

    batch.set(docRef, {
      'userId': _uid,
      'name': name.trim().isEmpty ? 'Untitled run' : name.trim(),
      'distanceMeters': distanceMeters,
      'durationMs': duration.inMilliseconds,
      'avgPaceMinPerKm': avgPaceMinPerKm,
      'maxPaceMinPerKm': maxPaceMinPerKm,
      'elevationDifferenceMeters': elevationDifferenceMeters,
      'loopsCompleted': loopsCompleted,
      'path':
          storedPath.map((p) => GeoPoint(p.latitude, p.longitude)).toList(),
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

    final metrics = RunPrivateMetrics(
      // Only set when a watch actually reported a reading. Omitted rather than
      // stored as 0 for a phone-only run: 0 bpm is not a measurement, and a
      // reader cannot tell a real zero from a missing one.
      avgHeartRateBpm: avgHeartRateBpm,
      maxHeartRateBpm: maxHeartRateBpm,
    );
    // No empty document for a phone-only run — its absence is the normal case
    // and reads the same as "no watch data".
    if (!metrics.isEmpty) {
      batch.set(
        docRef.collection('private').doc(RunPrivateMetrics.docId),
        metrics.toFirestore(_uid),
      );
    }

    await batch.commit();
    return docRef.id;
  }

  /// The body metrics of [sessionId], or null when there are none.
  ///
  /// **`permission-denied` is an expected, uninteresting outcome here, not a
  /// failure.** The rule authorizes against the document's own `userId`, so a
  /// document that does not exist has no `userId` to check and the read is
  /// denied rather than returning an empty snapshot — which is the case for
  /// every phone-only run, i.e. most of them.
  ///
  /// That is a deliberate trade rather than an oversight. Letting a missing
  /// document read as empty would have told any signed-in user which of
  /// someone else's runs carry watch data, since "denied" and "empty" are
  /// distinguishable; denying both leaks nothing at all. The cost is this
  /// swallowed error, which is cheaper than the alternatives (a `get()` on the
  /// parent session inside the rule is a billed read on every evaluation, and
  /// writing an empty document for every phone-only run is a write for
  /// nothing).
  Future<RunPrivateMetrics?> fetchPrivateMetrics(String sessionId) async {
    try {
      final doc = await _db
          .collection('runningSessions')
          .doc(sessionId)
          .collection('private')
          .doc(RunPrivateMetrics.docId)
          .get();
      if (!doc.exists) return null;
      return RunPrivateMetrics.fromDoc(doc);
    } on FirebaseException catch (e) {
      if (e.code != 'permission-denied') {
        debugPrint('Could not read private metrics for $sessionId: $e');
      }
      return null;
    } catch (e) {
      debugPrint('Could not read private metrics for $sessionId: $e');
      return null;
    }
  }

  Future<String?> _reverseGeocodeLocality(LatLng point) async {
    try {
      final uri = Uri.parse(
        'https://nominatim.openstreetmap.org/reverse'
        '?lat=${point.latitude}&lon=${point.longitude}&format=json&zoom=10',
      );
      final response = await (_httpClient?.get(
                uri,
                headers: {'User-Agent': 'DashApp/1.0'},
              ) ??
              http.get(uri, headers: {'User-Agent': 'DashApp/1.0'}))
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

  /// Returns a user's completed runs, newest first — the signed-in user's own
  /// by default, or [userId]'s when given, so a profile page can show someone
  /// else's runs. `firestore.rules` already lets any signed-in user read any
  /// `runningSessions` doc (see `fetchSessionById`), so this needs no special
  /// permission beyond being signed in.
  Future<List<RunSession>> fetchUserSessions({String? userId}) async {
    final snap = await _db
        .collection('runningSessions')
        .where('userId', isEqualTo: userId ?? _uid)
        .get();
    final list = snap.docs.map(RunSession.fromDoc).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list;
  }

  /// Fetches a single run by id, regardless of who owns it — used by
  /// `RunSessionDetailPage` to show another user's *whole* session (its
  /// complete GPS path and real stats, not just the one loop that happened
  /// to claim a given area), now that firestore.rules allows any signed-in
  /// user to read any `runningSessions` doc. A plain one-time read, not
  /// cached — unlike `fetchUserSessions`, this fetches an arbitrary other
  /// user's session on demand, not something worth keeping a warm
  /// current-user cache of. Returns null if the session doesn't exist
  /// (e.g. deleted).
  Future<RunSession?> fetchSessionById(String sessionId) async {
    final doc = await _db.collection('runningSessions').doc(sessionId).get();
    if (!doc.exists) return null;
    return RunSession.fromDoc(doc);
  }
}
