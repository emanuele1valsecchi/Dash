import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import 'user_appearance_service.dart';

/// Resolves *who originally ran* a shared session route — the single
/// ownerless `routes` document every user who favourited a given run points
/// at (see `FavoriteRouteRepository`).
///
/// That document deliberately carries no `userId`: it has no owner, precisely
/// so no one user can rename, reshape or delete geometry the others
/// reference. It does carry `sourceSessionId`, though, and
/// `runningSessions/{id}.userId` is readable by any signed-in user (see the
/// read rule's own comment in `firestore.rules`), so the original runner is
/// exactly one document read away — which is what lets a favourites list show
/// "by @someone" instead of an anonymous card.
///
/// **A route with no `sourceSessionId` resolves to no author, and that is the
/// intended outcome rather than a failure.** Account deletion strips that
/// field from the shared route specifically to break the last link back to
/// the deleted person (see `anonymizeSessionDerivedRoutes` in
/// `functions/index.js`), so this service naturally stops naming them.
///
/// App-lifetime singleton and a [ChangeNotifier], matching
/// [UserAppearanceService], which it delegates the uid → username half of the
/// lookup to (and which already batches and caches those). Read cost follows
/// the same rule as every other repository in this app: a session is looked
/// up at most once per process, lookups are batched 30 at a time, and a
/// session that resolves to nothing is remembered as such so it is not
/// re-queried.
class RouteAuthorService extends ChangeNotifier {
  RouteAuthorService._();

  static final RouteAuthorService instance = RouteAuthorService._();

  /// Firestore caps `whereIn` at 30 values per query.
  static const int _batchSize = 30;

  /// Test seam, matching [UserAppearanceService.firestoreOverride].
  @visibleForTesting
  FirebaseFirestore? firestoreOverride;

  /// A getter, not a `late final` field, and not an eager one either.
  ///
  /// Eager throws `[core/no-app]` the moment `instance` is first touched.
  /// `late final` would resolve once and then ignore any later override —
  /// which on an app-lifetime singleton means the second test in a file
  /// silently keeps the first one's database. Same shape as
  /// [UserAppearanceService].
  FirebaseFirestore get _db => firestoreOverride ?? FirebaseFirestore.instance;

  /// sessionId → the uid that ran it.
  final Map<String, String> _ownerBySession = {};

  /// Sessions that resolved to no document, or to one with no `userId`.
  /// Cached as a negative result so a deleted run isn't re-queried.
  final Set<String> _unresolvable = {};

  final Set<String> _inFlight = {};

  /// The original runner's username for [sessionId], or null while it is
  /// still loading, unknown, or deliberately unavailable (see the class doc).
  ///
  /// Callers must render sensibly for null rather than waiting on it — the
  /// author line is an enrichment, never something a card blocks on.
  String? authorNameFor(String? sessionId) {
    final uid = authorUidFor(sessionId);
    if (uid == null) return null;
    return UserAppearanceService.instance.get(uid)?.username;
  }

  /// The original runner's uid for [sessionId], or null if not (yet) known.
  String? authorUidFor(String? sessionId) =>
      sessionId == null ? null : _ownerBySession[sessionId];

  /// Loads the authors of any of [sessionIds] not already known or in flight,
  /// then their profiles. Safe to call on every rebuild: a known session
  /// costs nothing and one already being fetched is not fetched again.
  Future<void> ensureLoaded(Iterable<String?> sessionIds) async {
    final ids = <String>{
      for (final id in sessionIds)
        if (id != null && id.isNotEmpty) id,
    };

    final wanted = ids
        .where((id) =>
            !_ownerBySession.containsKey(id) &&
            !_unresolvable.contains(id) &&
            !_inFlight.contains(id))
        .toSet();

    // Sessions whose owner is already known may still be missing a profile —
    // ask for those regardless of whether anything new needs looking up.
    final uids = <String>{
      for (final id in ids)
        if (_ownerBySession[id] != null) _ownerBySession[id]!,
    };

    if (wanted.isNotEmpty) {
      _inFlight.addAll(wanted);
      try {
        final all = wanted.toList();
        final batches = <List<String>>[];
        for (var i = 0; i < all.length; i += _batchSize) {
          batches.add(all.sublist(i, (i + _batchSize).clamp(0, all.length)));
        }

        final results = await Future.wait(batches.map(_fetchBatch));
        for (final batch in results) {
          for (final entry in batch.entries) {
            _ownerBySession[entry.key] = entry.value;
            uids.add(entry.value);
          }
        }
        for (final id in wanted) {
          if (!_ownerBySession.containsKey(id)) _unresolvable.add(id);
        }
      } catch (e) {
        // Best-effort only: a card renders fine without an author line, so a
        // failure here must never take the list down with it. Nothing is
        // marked unresolvable, so a later call can retry.
        debugPrint('Could not resolve route authors: $e');
      } finally {
        _inFlight.removeAll(wanted);
      }
    }

    if (uids.isNotEmpty) {
      await UserAppearanceService.instance.ensureLoaded(uids);
    }
    notifyListeners();
  }

  Future<Map<String, String>> _fetchBatch(List<String> sessionIds) async {
    final snap = await _db
        .collection('runningSessions')
        .where(FieldPath.documentId, whereIn: sessionIds)
        .get();

    final owners = <String, String>{};
    for (final doc in snap.docs) {
      final uid = doc.data()['userId'] as String?;
      if (uid != null && uid.isNotEmpty) owners[doc.id] = uid;
    }
    return owners;
  }

  /// App-lifetime singleton — never disposed. Mirrors
  /// [UserAppearanceService.dispose].
  @override
  void dispose() {
    assert(false, 'RouteAuthorService is an app-lifetime singleton');
    super.dispose();
  }

  @visibleForTesting
  void clearForTest() {
    _ownerBySession.clear();
    _unresolvable.clear();
    _inFlight.clear();
    firestoreOverride = null;
  }
}
