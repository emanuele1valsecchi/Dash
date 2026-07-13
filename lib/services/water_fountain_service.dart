import 'dart:async';
import 'dart:convert';

import 'package:flutter_map/flutter_map.dart' show LatLngBounds, MapCamera;
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../models/water_fountain.dart';

/// Fetches nearby drinking-water points of interest from OpenStreetMap's
/// Overpass API (`amenity=drinking_water` nodes) — the same free, keyless
/// data source the app's OSM-based routing/search already relies on.
///
/// In-memory cached by a fine lat/lon grid cell — just enough to absorb
/// floating-point/pixel jitter between near-identical repeat queries, not to
/// meaningfully expand the queried area (see [WaterFountainViewportLoader]
/// for the thing that actually controls how much area gets queried). Once an
/// area has been fetched successfully it stays cached for the rest of the
/// app session — returning to it later (even after the layer's been hidden
/// by zooming out) is instant, no re-fetch.
class WaterFountainService {
  static const String _overpassUrl = 'https://overpass-api.de/api/interpreter';

  /// Below this zoom level the viewport is too large for a fountain layer to
  /// stay fast — the query area (and Overpass's own processing time over it)
  /// grows with it, and so does the marker count `MarkerLayer` has to lay
  /// out every frame. ~1.5-2km wide at this zoom, which is "near what I'm
  /// looking at", not "the whole city".
  static const double minZoomToLoad = 10.0;

  /// ~200m grid — fine enough that the snapped/expanded query area barely
  /// grows past what was actually asked for, coarse enough to still dedupe
  /// near-identical repeat queries.
  static const double _gridDegrees = 0.002;

  final Map<String, List<WaterFountain>> _cache = {};

  /// Fetches fountains within [radiusMeters] of [center] — for a single
  /// point-in-time lookup (e.g. the run-tracking screen's starting position,
  /// which deliberately fetches once and doesn't track the viewport, so the
  /// radius needs to be generous enough to cover a run that wanders from the
  /// start point without ever re-fetching).
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

  /// Fetches fountains within the given map viewport. [bounds] is snapped
  /// outward to the nearest (fine) grid cell purely to stabilize the cache
  /// key — how much area actually gets queried is controlled by the caller
  /// (see [WaterFountainViewportLoader]'s padding), not by this snap.
  ///
  /// Returns `null` on failure — see [fetchNearby].
  Future<List<WaterFountain>?> fetchInBounds(LatLngBounds bounds) {
    final south = (bounds.south / _gridDegrees).floor() * _gridDegrees;
    final west = (bounds.west / _gridDegrees).floor() * _gridDegrees;
    final north = (bounds.north / _gridDegrees).ceil() * _gridDegrees;
    final east = (bounds.east / _gridDegrees).ceil() * _gridDegrees;
    return _query(
      '$south,$west,$north,$east',
      'bbox:$south,$west,$north,$east',
    );
  }

  Future<List<WaterFountain>?> _query(
    String overpassFilter,
    String cacheKey,
  ) async {
    final cached = _cache[cacheKey];
    if (cached != null) return cached;

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

      _cache[cacheKey] = fountains;
      return fountains;
    } catch (_) {
      // Network error, timeout, or a non-JSON (e.g. Overpass's HTML error
      // page) body failing to parse — all transient, not "zero results".
      return null;
    }
  }

  double _snap(double v) => (v / _gridDegrees).round() * _gridDegrees;
}

/// Fetches fountains near a fixed real-world point (typically the user's GPS
/// position) rather than tracking the map viewport. This is the current,
/// active loading strategy for explore/route create/route search — simpler
/// and more reliable than viewport tracking turned out to be in practice
/// (see [WaterFountainViewportLoader]'s doc for the specific failure modes
/// that kept surfacing: tuning the zoom/query-area tradeoff, Overpass
/// rate-limiting, stuck-forever state). The tradeoff accepted for now:
/// fountains only ever reflect where the user physically is, not wherever
/// they've panned the map to — revisit viewport-based loading once it's
/// worth the added complexity again.
///
/// Only refetches once the GPS position has moved more than
/// [refetchThresholdMeters], so a stream of GPS fixes a few metres apart
/// doesn't each trigger a new Overpass request.
class WaterFountainGpsLoader {
  WaterFountainGpsLoader(this._service);

  final WaterFountainService _service;
  LatLng? _lastFetchCenter;

  static const double refetchThresholdMeters = 800;

  /// Call whenever the current position updates (initial fix, and every
  /// subsequent GPS update). Invokes [onResult] only when a fetch actually
  /// happens and succeeds.
  void handlePositionChanged(
    LatLng center,
    void Function(List<WaterFountain> fountains) onResult,
  ) {
    final last = _lastFetchCenter;
    if (last != null &&
        const Distance()(last, center) < refetchThresholdMeters) {
      return;
    }

    _service.fetchNearby(center).then((fountains) {
      // Failed (network error / rate-limited) — leave _lastFetchCenter
      // alone (rather than committing this center as "done") so the next
      // GPS update, even a small one, naturally retries instead of getting
      // permanently stuck with nothing loaded.
      if (fountains == null) return;
      _lastFetchCenter = center;
      onResult(fountains);
    });
  }
}

/// Caches viewport-based fountain lookups for a single map screen — wraps a
/// [WaterFountainService] with the "what's currently on screen" policy so
/// screens don't each reimplement it.
///
/// **Not currently wired into any screen** — parked after repeated tuning
/// attempts (query-area size, zoom cutoff, Overpass rate-limiting/stuck
/// state) kept surfacing new problems faster than they got resolved; see
/// [WaterFountainGpsLoader], the simpler strategy currently in use instead.
/// Kept here rather than deleted since the plan is to revisit it later, not
/// abandon it.
///
/// Four things this guards against:
///  - Too much area per query: below [WaterFountainService.minZoomToLoad]
///    fountains aren't fetched or shown at all (zoomed out to city/region
///    scale, "every fountain in view" is both slow to query and too dense to
///    render), and even at valid zoom levels the padded query area is kept
///    modest (see [_paddingFactor]) rather than many screen-widths wide —
///    both the Overpass round-trip and `MarkerLayer`'s per-frame layout cost
///    scale with query area, which is what made this feel slow before.
///  - Re-fetching on every pan/zoom event: a fetch only fires once the
///    visible viewport is no longer covered by the last *successfully*
///    fetched (padded) area, so most panning shows already-loaded markers
///    instantly instead of clearing and waiting on a new request — and
///    revisiting anywhere already covered this session (even after zooming
///    out past the layer's visibility threshold and back in) is instant too,
///    since [WaterFountainService]'s own cache never gets cleared.
///  - A failed fetch getting permanently "stuck": the covered area is only
///    marked as such *after* a fetch actually succeeds. Earlier this was set
///    optimistically before the request resolved, so a single rate-limited
///    or dropped request (Overpass's public instance rate-limits fairly
///    readily) would permanently mark that area as "loaded" with nothing to
///    show, and no further pan/zoom event would ever retry it — the only way
///    out was leaving and re-entering the screen, which threw the whole
///    loader away. A failed fetch now retries itself once, shortly after.
///  - Stale, out-of-order responses: if a slower request resolves after a
///    newer one (e.g. a fast pan fires two fetches back to back), the older
///    result is discarded instead of overwriting the newer markers — without
///    this, fountains could flicker away as an outdated response lands.
class WaterFountainViewportLoader {
  WaterFountainViewportLoader(this._service);

  final WaterFountainService _service;
  LatLngBounds? _fetchedBounds;
  int _requestId = 0;

  /// How far beyond the visible viewport to fetch, as a multiple of the
  /// viewport's own width/height — e.g. 0.5 fetches a 2x2 area centred on
  /// what's visible: a "slightly bigger radius" buffer so panning a modest
  /// amount doesn't need a new network request, without ballooning the
  /// query (and marker count) far past what's actually being looked at.
  static const double _paddingFactor = 0.5;

  /// Call from `MapOptions.onPositionChanged` (and once from `onMapReady`
  /// for the initial view). Invokes [onResult] with the fountains for the
  /// padded area around [camera] whenever a fetch is actually needed.
  void handlePositionChanged(
    MapCamera camera,
    void Function(List<WaterFountain> fountains) onResult,
  ) {
    if (camera.zoom < WaterFountainService.minZoomToLoad) {
      if (_fetchedBounds != null) {
        _fetchedBounds = null;
        _requestId++;
        onResult(const []);
      }
      return;
    }

    if (_fetchedBounds?.containsBounds(camera.visibleBounds) ?? false) {
      return;
    }

    _fetch(camera, onResult, retryOnFailure: true);
  }

  void _fetch(
    MapCamera camera,
    void Function(List<WaterFountain> fountains) onResult, {
    required bool retryOnFailure,
  }) {
    final padded = _pad(camera.visibleBounds);
    final requestId = ++_requestId;
    _service.fetchInBounds(padded).then((fountains) {
      if (requestId != _requestId) return; // superseded by a newer request

      if (fountains == null) {
        // Failed (network error / rate-limited) — don't mark this area as
        // covered, so a real pan/zoom will naturally retry it; also give it
        // one unprompted retry shortly, in case the user's just sitting
        // still looking at an empty map.
        if (retryOnFailure) {
          Timer(const Duration(seconds: 3), () {
            if (requestId != _requestId) return;
            _fetch(camera, onResult, retryOnFailure: false);
          });
        }
        return;
      }

      _fetchedBounds = padded;
      onResult(fountains);
    });
  }

  LatLngBounds _pad(LatLngBounds bounds) {
    final latPad = (bounds.north - bounds.south) * _paddingFactor;
    final lonPad = (bounds.east - bounds.west) * _paddingFactor;
    return LatLngBounds(
      LatLng(bounds.south - latPad, bounds.west - lonPad),
      LatLng(bounds.north + latPad, bounds.east + lonPad),
    );
  }
}
