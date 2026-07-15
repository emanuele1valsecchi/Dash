import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/water_fountain.dart';

/// Fetches nearby drinking-water points of interest from OpenStreetMap's
/// Overpass API (`amenity=drinking_water` nodes) — the same free, keyless
/// data source the app's OSM-based routing/search already relies on.
///
/// Deliberately used from **only one screen**, [RunTrackingPage], via
/// [fetchNearby] once at a run's starting position — not from the map
/// browsing screens (explore, route create, route search). An earlier
/// version also loaded fountains on those screens, tracking the map camera
/// as the user panned around; that turned into exactly the problem this
/// service's caching exists to avoid — casually browsing the map across many
/// areas kept the in-memory/disk cache growing and sent a steady stream of
/// Overpass requests just from looking around, not from anything
/// running-related. Removed rather than tuned further. Revisit
/// fountains-while-browsing as a deliberate, separately-scoped feature if
/// it's wanted again, rather than re-enabling this code path as-is.
///
/// A single app-wide instance ([instance]), mirroring `LocationService`'s
/// singleton pattern — mainly so a runner who repeatedly starts from the
/// same spot (very common) benefits from the cache across separate runs, not
/// just within one. The cache is also seeded from disk (see [warmUp]) so it
/// survives an app restart too — revisiting a previously-seen starting
/// point is instant even on a cold start, not just within a session.
///
/// Zoom has nothing to do with fetching here — [RunTrackingPage] fetches
/// once per run, unconditionally, regardless of what zoom the map is at.
/// Whether the fetched fountains are actually *drawn* is a separate, purely
/// client-side decision made by `WaterFountainMarkerLayer` from an explicit
/// zoom flag the screen passes it — "always loaded, just hidden below a
/// zoom threshold."
class WaterFountainService {
  static final WaterFountainService instance = WaterFountainService._();
  WaterFountainService._();

  static const String _overpassUrl = 'https://overpass-api.de/api/interpreter';

  /// ~2km grid, deliberately close to the default [fetchNearby] query radius
  /// (3km) rather than tight enough to only dedupe GPS jitter. A cache *key*
  /// this coarse relative to the query radius is what makes "come back to an
  /// area you already viewed" actually hit the cache: two query centers a
  /// kilometre or two apart already return near-identical fountain sets (their
  /// 3km-radius circles overlap heavily), so snapping them to the same grid
  /// cell trades a little positional precision for reliably avoiding a
  /// pointless repeat Overpass round-trip. A ~200m grid was tried first and
  /// was too fine for this: panning back to roughly the same neighbourhood
  /// almost never lands in the exact same tiny cell as before, so it missed
  /// the cache and re-fetched from scratch nearly every time.
  static const double _gridDegrees = 0.02;

  static const String _diskCacheKey = 'water_fountain_cache_v1';

  /// Fountains are static infrastructure — this is a hedge against drift
  /// (a fountain removed/moved in OSM) rather than an expectation that
  /// they change often. Only checked when loading from disk; an entry that
  /// crosses this age while resident in a long-lived in-memory session isn't
  /// evicted mid-session, which is fine at realistic app-session lengths.
  static const Duration _diskCacheTtl = Duration(days: 30);

  /// Caps the persisted blob's worst-case size (Overpass responses are
  /// themselves capped at 300 fountains each — see [_doQuery]) rather than
  /// letting it grow unboundedly as a user visits more areas over time.
  /// Eviction is by oldest [_CacheEntry.fetchedAt] first.
  static const int _maxCachedEntries = 150;

  final Map<String, _CacheEntry> _cache = {};

  /// Coalesces concurrent requests for the same [cacheKey] into a single
  /// HTTP call — without this, several GPS ticks arriving before the first
  /// request resolves would each fire their own Overpass request. Entries
  /// are removed the instant their request settles (success *or* failure,
  /// since [_doQuery] resolves to `null` on failure rather than throwing) —
  /// leaving a completed future mapped here would permanently block retries
  /// for that key.
  final Map<String, Future<List<WaterFountain>?>> _inFlight = {};

  Future<void>? _warmUpFuture;

  /// Loads the on-disk cache into memory, if present. Safe to call multiple
  /// times (memoized) and not required — [fetchNearby] awaits it internally
  /// regardless. Calling it early (e.g. from `HomeScreen`, alongside
  /// `LocationService.instance.start()`) just lets the disk read happen in
  /// parallel with GPS acquisition instead of only starting on the first
  /// fountain fetch.
  Future<void> warmUp() => _warmUpFuture ??= _loadFromDisk();

  /// Fetches fountains within [radiusMeters] of [center] — a single
  /// point-in-time lookup, called once at the run-tracking screen's starting
  /// position and never again for that run, so the radius needs to be
  /// generous enough to cover a run that wanders from the start point
  /// without ever re-fetching.
  ///
  /// Returns `null` on failure (network error, timeout, rate-limited, etc.)
  /// — distinct from a successful fetch that just found nothing, so callers
  /// can tell "genuinely no fountains here" apart from "try again".
  Future<List<WaterFountain>?> fetchNearby(
    LatLng center, {
    double radiusMeters = 3000,
  }) {
    final lat = _snap(center.latitude);
    final lon = _snap(center.longitude);
    return _query(
      'around:${radiusMeters.round()},${center.latitude},${center.longitude}',
      'radius:$lat,$lon,${radiusMeters.round()}',
    );
  }

  Future<List<WaterFountain>?> _query(
    String overpassFilter,
    String cacheKey,
  ) async {
    await warmUp();

    final cached = _cache[cacheKey];
    if (cached != null) return cached.fountains;

    final pending = _inFlight[cacheKey];
    if (pending != null) return pending;

    final future = _doQuery(overpassFilter, cacheKey);
    _inFlight[cacheKey] = future;
    unawaited(future.whenComplete(() => _inFlight.remove(cacheKey)));
    return future;
  }

  Future<List<WaterFountain>?> _doQuery(
    String overpassFilter,
    String cacheKey,
  ) async {
    // Capped output: a defensive ceiling against pathologically dense areas
    // (e.g. a big park's worth of drinking fountains) blowing past a
    // reasonable marker count regardless of how tight the query area is.
    final query = '[out:json][timeout:10];'
        'node["amenity"="drinking_water"]($overpassFilter);'
        'out body 300;';

    try {
      // Overpass's server rejects requests with no User-Agent (406) — same
      // requirement as the Nominatim calls elsewhere in the app.
      final response = await http
          .post(
            Uri.parse(_overpassUrl),
            headers: {'User-Agent': 'DashApp/1.0'},
            body: {'data': query},
          )
          .timeout(const Duration(seconds: 10));
      // Overpass's public instance rate-limits fairly aggressively (a plain
      // 429, or a 200 with an HTML "rate_limited"/"too busy" error body) —
      // either way this is a transient failure, not "zero results".
      if (response.statusCode != 200) return null;

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final elements = data['elements'] as List<dynamic>? ?? [];
      final fountains = elements
          .map((e) {
            final el = e as Map<String, dynamic>;
            final lat = (el['lat'] as num?)?.toDouble();
            final lon = (el['lon'] as num?)?.toDouble();
            if (lat == null || lon == null) return null;
            return WaterFountain(
              id: '${el['type']}/${el['id']}',
              position: LatLng(lat, lon),
            );
          })
          .whereType<WaterFountain>()
          .toList();

      _cache[cacheKey] = _CacheEntry(fetchedAt: DateTime.now(), fountains: fountains);
      unawaited(_persistCache());
      return fountains;
    } catch (_) {
      // Network error, timeout, or a non-JSON (e.g. Overpass's HTML error
      // page) body failing to parse — all transient, not "zero results".
      return null;
    }
  }

  double _snap(double v) => (v / _gridDegrees).round() * _gridDegrees;

  // ── Disk cache ────────────────────────────────────────────────────────────

  Future<void> _loadFromDisk() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_diskCacheKey);
      if (raw == null) return;

      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final cutoff = DateTime.now().subtract(_diskCacheTtl);
      decoded.forEach((key, value) {
        final entry = value as Map<String, dynamic>;
        final fetchedAtMs = entry['t'] as int?;
        final rawFountains = entry['f'] as List<dynamic>?;
        if (fetchedAtMs == null || rawFountains == null) return;

        final fetchedAt = DateTime.fromMillisecondsSinceEpoch(fetchedAtMs);
        if (fetchedAt.isBefore(cutoff)) return;

        final fountains = rawFountains
            .map((f) => WaterFountain.fromJson(f as Map<String, dynamic>))
            .whereType<WaterFountain>()
            .toList();
        _cache[key] = _CacheEntry(fetchedAt: fetchedAt, fountains: fountains);
      });
    } catch (_) {
      // Corrupt/unreadable cache — start cold rather than crash; the next
      // successful fetch overwrites it with a well-formed blob.
    }
  }

  Future<void> _persistCache() async {
    try {
      final entries = _cache.entries.toList()
        ..sort((a, b) => b.value.fetchedAt.compareTo(a.value.fetchedAt));
      final capped = entries.take(_maxCachedEntries);

      final encoded = <String, dynamic>{
        for (final e in capped)
          e.key: {
            't': e.value.fetchedAt.millisecondsSinceEpoch,
            'f': e.value.fountains.map((f) => f.toJson()).toList(),
          },
      };

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_diskCacheKey, jsonEncode(encoded));
    } catch (_) {
      // Best-effort — losing this write just means a future cold start
      // re-fetches this area instead of reading it from disk.
    }
  }
}

class _CacheEntry {
  final DateTime fetchedAt;
  final List<WaterFountain> fountains;
  const _CacheEntry({required this.fetchedAt, required this.fountains});
}
