import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

/// The bits of another player's profile the map needs in order to draw them:
/// what colour their territory is, and what to put in the bubble on top of it.
@immutable
class UserAppearance {
  const UserAppearance({
    required this.uid,
    required this.username,
    required this.photoUrl,
    required this.colorIndex,
  });

  final String uid;

  /// Null when the profile has no username yet (signup is a two-step flow —
  /// the auth account exists before `createProfile` runs).
  final String? username;

  /// Null or empty when the player has not uploaded a picture; the bubble
  /// falls back to their initial.
  final String? photoUrl;

  /// `profiles/{uid}.areaColorIndex`. Null for a profile the backfill has not
  /// reached — `PlayerPalette` falls back to a uid hash, so this being null is
  /// a normal, fully-supported state rather than an error.
  final int? colorIndex;

  bool get hasPhoto => photoUrl != null && photoUrl!.trim().isNotEmpty;

  /// The single letter shown in the bubble when there is no photo.
  String get initial {
    final name = username?.trim();
    if (name == null || name.isEmpty) return '?';
    return name.substring(0, 1).toUpperCase();
  }
}

/// Caches the display identity of *other* players, keyed by uid, so the map
/// can colour territory and draw owner bubbles without a Firestore read per
/// polygon.
///
/// App-lifetime singleton (`UserAppearanceService.instance`), matching
/// `LocationService.instance` / `WaterFountainService.instance` /
/// `UnitPreferences.instance`.
///
/// **Read cost is the whole reason this exists.** A map viewport can easily
/// hold a few dozen areas, several of them the same owner; naively reading
/// `profiles/{uid}` per area would be dozens of reads per pan. Instead:
/// uids are fetched in batched `whereIn` queries, every result is cached for
/// the process's lifetime, and a uid is never fetched twice — including
/// concurrently, since in-flight uids are tracked separately from resolved
/// ones. That follows the same cache-and-don't-re-read rule as
/// `RouteRepository` and `ClaimedAreaRepository`.
///
/// It is a [ChangeNotifier] so a map layer can render immediately with
/// whatever is cached (falling back to the uid-hash colour and a blank
/// bubble) and repaint once the real values land — nothing ever blocks on
/// this.
class UserAppearanceService extends ChangeNotifier {
  UserAppearanceService._();

  static final UserAppearanceService instance = UserAppearanceService._();

  /// Firestore caps `whereIn` at 30 values per query, so a larger request is
  /// split across several queries run in parallel.
  static const int _batchSize = 30;

  final Map<String, UserAppearance> _cache = {};
  final Set<String> _inFlight = {};

  /// A uid that resolved to no profile document. Cached as a negative result
  /// so a deleted account is not re-queried on every single pan.
  final Set<String> _missing = {};

  /// The cached appearance for [uid], or null if it has not been loaded yet.
  /// Callers must render sensibly for null rather than waiting — see
  /// `PlayerPalette.colorFor`, which takes a nullable index for exactly this.
  UserAppearance? get(String uid) => _cache[uid];

  /// Loads any of [uids] not already cached or in flight. Safe to call on
  /// every rebuild: known uids cost nothing, and a uid already being fetched
  /// is not fetched again.
  Future<void> ensureLoaded(Iterable<String> uids) async {
    final wanted = <String>{};
    for (final uid in uids) {
      if (uid.isEmpty) continue;
      if (_cache.containsKey(uid)) continue;
      if (_missing.contains(uid)) continue;
      if (_inFlight.contains(uid)) continue;
      wanted.add(uid);
    }
    if (wanted.isEmpty) return;

    _inFlight.addAll(wanted);
    final batches = <List<String>>[];
    final all = wanted.toList();
    for (var i = 0; i < all.length; i += _batchSize) {
      batches.add(all.sublist(i, (i + _batchSize).clamp(0, all.length)));
    }

    try {
      final results = await Future.wait(batches.map(_fetchBatch));
      var changed = false;
      for (final batch in results) {
        for (final appearance in batch) {
          _cache[appearance.uid] = appearance;
          changed = true;
        }
      }
      // Anything asked for that came back with no document is a deleted or
      // never-created profile — remember that so it is not re-queried.
      for (final uid in wanted) {
        if (!_cache.containsKey(uid)) _missing.add(uid);
      }
      if (changed) notifyListeners();
    } catch (e) {
      // A failed lookup must never break the map: callers already render
      // correctly with no appearance at all, so this degrades to hash
      // colours and initial-less bubbles until the next attempt.
      debugPrint('UserAppearanceService.ensureLoaded failed: $e');
    } finally {
      _inFlight.removeAll(wanted);
    }
  }

  Future<List<UserAppearance>> _fetchBatch(List<String> uids) async {
    final snap = await FirebaseFirestore.instance
        .collection('profiles')
        .where(FieldPath.documentId, whereIn: uids)
        .get();

    return snap.docs.map((doc) {
      final d = doc.data();
      final rawIndex = d['areaColorIndex'];
      return UserAppearance(
        uid: doc.id,
        username: (d['username'] as String?)?.trim(),
        photoUrl: (d['profileImageUrl'] as String?)?.trim(),
        colorIndex: rawIndex is num ? rawIndex.toInt() : null,
      );
    }).toList();
  }

  /// Drops a single uid so the next [ensureLoaded] re-reads it — for after the
  /// signed-in user changes their own picture or colour.
  void invalidate(String uid) {
    if (_cache.remove(uid) != null || _missing.remove(uid)) {
      notifyListeners();
    }
  }

  /// App-lifetime singleton — never disposed, same contract as
  /// `UnitPreferences.instance`.
  @override
  void dispose() {
    assert(false, 'UserAppearanceService is an app-lifetime singleton');
    super.dispose();
  }

  @visibleForTesting
  void seedForTest(Iterable<UserAppearance> appearances) {
    for (final a in appearances) {
      _cache[a.uid] = a;
    }
    notifyListeners();
  }

  @visibleForTesting
  void clearForTest() {
    _cache.clear();
    _inFlight.clear();
    _missing.clear();
  }
}
