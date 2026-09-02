import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:latlong2/latlong.dart';

import '../utils/geometry_utils.dart';
import 'package:flutter/foundation.dart';

/// One contiguous piece of a claimed area's territory — an outer boundary
/// plus zero or more holes (produced when someone else's loop carves a
/// piece out of the middle without touching an edge). A single [ClaimedArea]
/// can have more than one of these (e.g. a steal that cuts straight through
/// leaves two disconnected remaining pieces) — see [ClaimedArea.polygons].
class AreaPolygonPiece {
  final List<LatLng> outer;
  final List<List<LatLng>> holes;

  const AreaPolygonPiece({required this.outer, required this.holes});

  factory AreaPolygonPiece.fromMap(Map<String, dynamic> map) {
    LatLng toLatLng(dynamic p) => LatLng((p as GeoPoint).latitude, p.longitude);
    return AreaPolygonPiece(
      outer: (map['outer'] as List<dynamic>? ?? []).map(toLatLng).toList(),
      holes: (map['holes'] as List<dynamic>? ?? [])
          .map((h) => ((h as Map<String, dynamic>)['points'] as List<dynamic>? ?? [])
              .map(toLatLng)
              .toList())
          .toList(),
    );
  }
}

/// One run that contributed (some of) the ground making up a [ClaimedArea].
/// A merge (running a new loop that touches/overlaps your own existing
/// territory) combines both runs' contribution lists rather than replacing
/// one with the other — kept mainly so a user can see, and later re-run,
/// whichever of their past routes built up a given area.
///
/// Every contribution in a given [ClaimedArea.contributions] list was made
/// by that same area's own [ClaimedArea.userId] — the claim Cloud Function
/// only ever merges another area's contribution list into a new claim when
/// that area's owner matches the claiming user (see `computeClaim` in
/// functions/geo.js), so there's no separate per-contribution runner to
/// track here.
///
/// Deliberately just this much — a run-detail page wanting the *whole*
/// running session (full path, real distance/area/etc., not just the one
/// loop that happened to claim this area) reads the `runningSessions` doc
/// itself via `sessionId` (any signed-in user may read any session — see
/// firestore.rules), rather than this getting re-denormalized here again.
class AreaContribution {
  final String sessionId;
  final int durationMs;
  final double? avgPaceMinPerKm;
  final DateTime conquestDate;

  const AreaContribution({
    required this.sessionId,
    required this.durationMs,
    required this.avgPaceMinPerKm,
    required this.conquestDate,
  });

  factory AreaContribution.fromMap(Map<String, dynamic> map) {
    return AreaContribution(
      sessionId: map['sessionId'] as String? ?? '',
      durationMs: (map['durationMs'] as num?)?.toInt() ?? 0,
      avgPaceMinPerKm: (map['avgPaceMinPerKm'] as num?)?.toDouble(),
      conquestDate: map['conquestDate'] != null
          ? (map['conquestDate'] as Timestamp).toDate()
          : DateTime.now(),
    );
  }
}

/// A claimed territory, as stored in the `claimedAreas` Firestore
/// collection. Created and — unlike most other collections in this app —
/// later *mutated* by the `onRunningSessionCreateClaimedAreas` Cloud
/// Function (see functions/index.js and functions/geo.js) whenever a closed
/// loop unions into someone's own territory or cuts into someone else's; the
/// client never writes this collection directly (see firestore.rules).
class ClaimedArea {
  final String id;
  final String userId;
  final List<AreaPolygonPiece> polygons;
  final List<AreaContribution> contributions;
  final String? startLocality;
  final DateTime createdAt;
  final DateTime updatedAt;

  const ClaimedArea({
    required this.id,
    required this.userId,
    required this.polygons,
    required this.contributions,
    required this.startLocality,
    required this.createdAt,
    required this.updatedAt,
  });

  /// Total current area across every (dis)contiguous piece, holes
  /// subtracted — what actually belongs to this owner right now.
  double get totalAreaM2 {
    var total = 0.0;
    for (final piece in polygons) {
      total += GeometryUtils.polygonAreaM2(piece.outer);
      for (final hole in piece.holes) {
        total -= GeometryUtils.polygonAreaM2(hole);
      }
    }
    return total.clamp(0, double.infinity);
  }

  factory ClaimedArea.fromDoc(QueryDocumentSnapshot doc) {
    final d = doc.data() as Map<String, dynamic>;
    final polygons = (d['polygon'] as List<dynamic>? ?? [])
        .map((p) => AreaPolygonPiece.fromMap(p as Map<String, dynamic>))
        .toList();
    final contributions = (d['contributions'] as List<dynamic>? ?? [])
        .map((c) => AreaContribution.fromMap(c as Map<String, dynamic>))
        .toList();

    return ClaimedArea(
      id: doc.id,
      userId: d['userId'] as String? ?? '',
      polygons: polygons,
      contributions: contributions,
      startLocality: d['startLocality'] as String?,
      createdAt: d['createdAt'] != null
          ? (d['createdAt'] as Timestamp).toDate()
          : DateTime.now(),
      updatedAt: d['updatedAt'] != null
          ? (d['updatedAt'] as Timestamp).toDate()
          : DateTime.now(),
    );
  }
}

/// In-memory-cached gateway to the Firestore `claimedAreas` collection.
///
/// Unlike [RouteRepository]/[RunSessionRepository] this deliberately reads
/// every user's areas, not just the current user's — the whole point of the
/// area map is seeing what territory is already claimed by others and what's
/// still open to conquest. One-time read rather than a real-time listener
/// (claims don't need to update live while someone is just browsing the
/// map).
///
/// The first call reads the whole collection; every call after that only
/// queries for areas *touched* (created, reshaped by a merge, or shrunk by a
/// steal) after the newest `updatedAt` already cached, and merges results
/// into the cache **by id** rather than appending — an update needs to
/// replace the stale copy of that area, not sit alongside it. Areas can also
/// be fully absorbed by someone else's claim, at which point the Cloud
/// Function marks them `deleted: true` rather than actually deleting the
/// document — Firestore has no "what got deleted since X" query, so a hard
/// delete would just make the doc invisible to future queries without ever
/// telling an already-caching client to drop it. Tombstones are filtered out
/// of the returned list but still consume their `updatedAt` slot so the next
/// query's lower bound moves past them.
class ClaimedAreaRepository {
  static final ClaimedAreaRepository instance = ClaimedAreaRepository._();
  /// Collaborators default to the real Firebase singletons, so
  /// `ClaimedAreaRepository.instance` behaves exactly as it always has and no
  /// call site changes. They are only ever passed by tests.
  ClaimedAreaRepository._({
    FirebaseFirestore? db,
  })  :         _db = db ?? FirebaseFirestore.instance;

  /// A repository wired to test doubles (`FakeFirebaseFirestore`,
  /// `MockFirebaseAuth`).
  ///
  /// **This is the seam that makes the data layer testable.** Reading
  /// `FirebaseFirestore.instance` in a field initializer, as this class
  /// used to, cannot be substituted from a test: there is no
  /// `Firebase.initializeApp` in the test binding, so touching it throws
  /// before a single assertion runs.
  ///
  /// A named constructor rather than a public `ClaimedAreaRepository()`: the singleton stays
  /// the only way production code gets one, so this cannot quietly become
  /// a second live instance with its own cache.
  @visibleForTesting
  factory ClaimedAreaRepository.withDependencies({
    FirebaseFirestore? db,
  }) =>
      ClaimedAreaRepository._(db: db);

  final FirebaseFirestore _db;

  /// Returns a live stream of every currently-claimed area from every user.
  Stream<List<ClaimedArea>> areasStream() {
    return _db.collection('claimedAreas').snapshots().map((snap) {
      final areas = <ClaimedArea>[];
      
      for (final doc in snap.docs) {
        final data = doc.data();
        // Ignore logically deleted areas just like the original logic
        if (data['deleted'] == true) continue;
        
        areas.add(ClaimedArea.fromDoc(doc));
      }
      
      return areas;
    });
  }
}
