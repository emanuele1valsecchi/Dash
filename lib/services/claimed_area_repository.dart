import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:latlong2/latlong.dart';

/// A claimed territory — the polygon of a closed loop some user ran, as
/// stored in the `claimedAreas` Firestore collection. Created only by the
/// `onRunningSessionCreateClaimedAreas` Cloud Function (see functions/index.js)
/// from a completed run's closed loops; the client never writes this
/// collection (see firestore.rules). `durationMs`/`avgPaceMinPerKm` are
/// copied from the originating `runningSessions` doc by that same function —
/// the client can't read another user's `runningSessions` doc directly (see
/// firestore.rules), so these are denormalized onto the area instead of
/// looked up live.
class ClaimedArea {
  final String id;
  final String userId;
  final List<LatLng> polygon;
  final String? startLocality;
  final DateTime createdAt;
  final int durationMs;
  final double? avgPaceMinPerKm;

  const ClaimedArea({
    required this.id,
    required this.userId,
    required this.polygon,
    required this.startLocality,
    required this.createdAt,
    required this.durationMs,
    required this.avgPaceMinPerKm,
  });

  factory ClaimedArea.fromDoc(QueryDocumentSnapshot doc) {
    final d = doc.data() as Map<String, dynamic>;
    final polygon = (d['polygon'] as List<dynamic>? ?? [])
        .map((p) => LatLng((p as GeoPoint).latitude, p.longitude))
        .toList();

    return ClaimedArea(
      id: doc.id,
      userId: d['userId'] as String? ?? '',
      polygon: polygon,
      startLocality: d['startLocality'] as String?,
      createdAt: d['createdAt'] != null
          ? (d['createdAt'] as Timestamp).toDate()
          : DateTime.now(),
      durationMs: (d['durationMs'] as num?)?.toInt() ?? 0,
      avgPaceMinPerKm: (d['avgPaceMinPerKm'] as num?)?.toDouble(),
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
/// queries for areas created after the newest one already cached, so
/// revisiting the Area page after claiming a new one (e.g. finishing a run)
/// picks it up without re-downloading everything that hasn't changed —
/// closer to "ask the db if anything's new" than either a full live listener
/// or a cache that only clears on app restart. Areas are immutable once
/// created (no update, per firestore.rules) so a newest-first delta is
/// enough; the one gap is a *deleted* area not disappearing until the next
/// full app start, which isn't a path the app exposes yet.
class ClaimedAreaRepository {
  static final ClaimedAreaRepository instance = ClaimedAreaRepository._();
  ClaimedAreaRepository._();

  final _db = FirebaseFirestore.instance;

  final List<ClaimedArea> _cache = [];
  DateTime? _newestSeen;

  /// Returns every claimed area from every user.
  Future<List<ClaimedArea>> fetchAllAreas() async {
    Query<Map<String, dynamic>> query = _db.collection('claimedAreas');
    final newestSeen = _newestSeen;
    if (newestSeen != null) {
      query = query.where(
        'createdAt',
        isGreaterThan: Timestamp.fromDate(newestSeen),
      );
    }

    final snap = await query.get();
    for (final doc in snap.docs) {
      final area = ClaimedArea.fromDoc(doc);
      _cache.add(area);
      if (_newestSeen == null || area.createdAt.isAfter(_newestSeen!)) {
        _newestSeen = area.createdAt;
      }
    }
    return List.unmodifiable(_cache);
  }
}
