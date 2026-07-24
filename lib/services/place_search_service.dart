import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

/// A ranked place suggestion for "search for a place" fields — shared by
/// every screen with one (route creation's top-bar search, route search's
/// start/destination/stop fields) via [PlaceSearchService] below, so they
/// stay identical instead of drifting into subtly different behaviour.
class Place {
  final String displayName;
  final LatLng latLng;

  /// Nominatim's own 0–1 "how globally significant is this place" score
  /// (roughly population/notability). Used to break ties in
  /// [PlaceSearchService.rank] so a famous city wins over an obscure
  /// same-name village even when the latter is an exact text match and the
  /// former only a prefix match. Places without a real score (the Overpass
  /// POI fallback) get a modest default, low enough that it won't outrank a
  /// genuine well-known Nominatim result.
  final double importance;

  const Place({
    required this.displayName,
    required this.latLng,
    this.importance = 0.15,
  });
}

/// Nominatim (primary) + Overpass POI (fallback) place search, re-ranked by
/// text-match quality, then a coarse importance tier, then proximity — see
/// [rank] for why a weighted score doesn't work here.
class PlaceSearchService {
  PlaceSearchService._();

  /// Half-width/height (in degrees) of the "viewbox" sent to Nominatim
  /// around [near] — roughly a 75km-wide box, generous enough to cover an
  /// entire metro area. Nominatim treats an unbounded viewbox (no
  /// `bounded=1`) as a *preference*, not a hard filter — a well-known match
  /// elsewhere can still outrank a low-importance local one, but an
  /// otherwise-ambiguous query like "Via Roma" gets nudged toward [near],
  /// matching how Google Maps-style search biases by location without
  /// excluding everything else.
  static const double _viewboxDegrees = 0.35;

  /// Searches for [query], biased toward [near] if given, yielding ranked
  /// (see [rank]) result lists as they become available:
  ///
  ///  1. Nominatim's own results, the moment they arrive — a plain search
  ///     like this typically resolves in well under a second, so callers
  ///     shouldn't wait on anything slower before showing *something*.
  ///  2. If Nominatim came up thin (fewer than 3 results) and [near] is
  ///     known, a second, merged list once the much slower Overpass POI
  ///     fallback (measured at ~10s before even timing out, on the public
  ///     instance) resolves — Nominatim indexes street addresses well but
  ///     often misses informally named places (campus buildings, landmarks)
  ///     that only carry a `name` tag in OSM, not a postal address (e.g.
  ///     "Edificio 25 Polimi").
  ///
  /// Only ever adds a second emission on top of the first — never blocks
  /// showing Nominatim's own results on the slower fallback. Never throws;
  /// a network failure at either stage just means no more emissions (an
  /// empty first emission on total Nominatim failure, or no second emission
  /// if only the Overpass fallback fails).
  static Stream<List<Place>> search(
    String query, {
    LatLng? near,
    int limit = 10,
  }) async* {
    List<Place> places = [];

    try {
      final viewbox = near != null
          ? '&viewbox=${near.longitude - _viewboxDegrees},'
                '${near.latitude + _viewboxDegrees},'
                '${near.longitude + _viewboxDegrees},'
                '${near.latitude - _viewboxDegrees}'
          : '';
      // Over-fetch (15, not the ~10 we'll actually show) — Nominatim's own
      // ranking for an ambiguous query (e.g. plain "London", which also
      // matches London, Ontario and a handful of small US towns) can bury a
      // globally-famous place outside a small results window; the more raw
      // candidates pulled in, the better chance [rank] actually has the
      // right one to promote.
      final uri = Uri.parse(
        'https://nominatim.openstreetmap.org/search'
        '?q=${Uri.encodeComponent(query)}&format=json&limit=15$viewbox',
      );
      final res = await http
          .get(uri, headers: {'User-Agent': 'DashApp/1.0'})
          .timeout(const Duration(seconds: 5));
      if (res.statusCode == 200) {
        final list = jsonDecode(res.body) as List<dynamic>;
        places = list.map((item) {
          final m = item as Map<String, dynamic>;
          return Place(
            displayName: m['display_name'] as String,
            latLng: LatLng(
              double.parse(m['lat'] as String),
              double.parse(m['lon'] as String),
            ),
            importance: (m['importance'] as num?)?.toDouble() ?? 0.1,
          );
        }).toList();
      }
    } catch (_) {
      // Network error/timeout — fall through to the POI fallback below
      // rather than yielding nothing at all.
    }

    yield rank(places, query, near).take(limit).toList();

    if (places.length >= 3 || near == null) return;

    try {
      final poiPlaces = await _fetchPoiFallback(query, near);
      final seen = places.map((p) => _roundedKey(p.latLng)).toSet();
      final newPlaces = [
        for (final p in poiPlaces)
          if (seen.add(_roundedKey(p.latLng))) p,
      ];
      if (newPlaces.isNotEmpty) {
        yield rank([...places, ...newPlaces], query, near).take(limit).toList();
      }
    } catch (_) {
      // Slow/unreachable/rate-limited — the Nominatim results already
      // yielded above stand on their own.
    }
  }

  static String _roundedKey(LatLng p) =>
      '${p.latitude.toStringAsFixed(4)},${p.longitude.toStringAsFixed(4)}';

  /// Re-ranks Nominatim/Overpass results instead of trusting their raw
  /// order. Nominatim's own ranking weighs a *worse* text match (e.g. a
  /// truncated "londo" only fuzzy-matching "London") so heavily that a tiny,
  /// obscure place with an exact name match ("Londo" the village) can
  /// outrank a globally-famous city that's merely a prefix match — which is
  /// backwards for what a user typing an incomplete name actually wants.
  ///
  /// The fix: sort by three keys in strict priority order — match quality
  /// (does the primary place name start with/equal the query?), then a
  /// *coarse tier* of Nominatim's `importance` (population/notability), then
  /// proximity — each only a tiebreaker for the one before it. Importance is
  /// bucketed into tiers rather than compared as a raw 0–1 float so a real
  /// gap (a major world capital vs. a minor same-name town) always wins
  /// outright, while two similarly-significant places (both merely "a
  /// notable town", say) land in the same tier and fall through to
  /// proximity — otherwise a purely-numeric comparison would let *any*
  /// razor-thin importance difference override proximity too, which is just
  /// as wrong as the opposite (weighted-sum) failure mode: a Europe-based
  /// search for "London" outranking London, England with London, Ontario
  /// merely for scoring a hair higher/closer on one term or the other.
  static List<Place> rank(List<Place> places, String query, LatLng? near) {
    final q = query.trim().toLowerCase();
    int matchTier(Place p) {
      final name = p.displayName.toLowerCase();
      final primaryName = name.split(',').first.trim();
      if (primaryName == q) return 3;
      if (primaryName.startsWith(q)) return 2;
      if (name.contains(q)) return 1;
      return 0;
    }

    // 5 buckets (0–0.2, 0.2–0.4, … 0.8–1.0) — coarse enough that only a
    // real notability gap crosses a tier, not day-to-day noise in
    // Nominatim's own score.
    int importanceTier(Place p) => (p.importance * 5).floor().clamp(0, 4);

    double proximityScore(Place p) {
      if (near == null) return 0;
      final distanceKm = const Distance().as(
        LengthUnit.Kilometer,
        near,
        p.latLng,
      );
      return 1 / (1 + distanceKm / 200);
    }

    final sorted = List<Place>.of(places)
      ..sort((a, b) {
        final tierCompare = matchTier(b).compareTo(matchTier(a));
        if (tierCompare != 0) return tierCompare;
        final importanceCompare = importanceTier(
          b,
        ).compareTo(importanceTier(a));
        if (importanceCompare != 0) return importanceCompare;
        return proximityScore(b).compareTo(proximityScore(a));
      });
    return sorted;
  }

  /// Searches OpenStreetMap-tagged places by name via the Overpass API (the
  /// same free, keyless data source `WaterFountainService` already uses) —
  /// a fallback for named POIs Nominatim's address search misses. Restricted
  /// to within [radiusMeters] of [pos] both to keep the query fast and
  /// because a "place near me" bias is exactly what's wanted here.
  ///
  /// The public Overpass instance is slow and often overloaded — measured
  /// directly, a query in this shape took ~10s before failing with a 504,
  /// and a repeat at a smaller radius still didn't return within 30s. A
  /// smaller radius and a short client timeout are damage control, not a
  /// fix for that — the actual fix is that [search] treats this purely as a
  /// background enhancement to results already yielded, never something the
  /// caller waits on before showing anything.
  static Future<List<Place>> _fetchPoiFallback(
    String query,
    LatLng pos,
  ) async {
    const radiusMeters = 20000;
    final escaped = _escapeForOverpassRegex(query);
    final ql =
        '[out:json][timeout:5];'
        '('
        'node["name"~"$escaped",i](around:$radiusMeters,${pos.latitude},${pos.longitude});'
        'way["name"~"$escaped",i](around:$radiusMeters,${pos.latitude},${pos.longitude});'
        ');'
        'out center 6;';

    final res = await http
        .post(
          Uri.parse('https://overpass-api.de/api/interpreter'),
          headers: {'User-Agent': 'DashApp/1.0'},
          body: {'data': ql},
        )
        .timeout(const Duration(seconds: 4));
    if (res.statusCode != 200) return [];

    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final elements = data['elements'] as List<dynamic>? ?? [];
    return elements
        .map((e) {
          final m = e as Map<String, dynamic>;
          final tags = m['tags'] as Map<String, dynamic>? ?? {};
          final name = tags['name'] as String?;
          if (name == null) return null;
          var lat = (m['lat'] as num?)?.toDouble();
          var lon = (m['lon'] as num?)?.toDouble();
          if (lat == null || lon == null) {
            final center = m['center'] as Map<String, dynamic>?;
            lat = (center?['lat'] as num?)?.toDouble();
            lon = (center?['lon'] as num?)?.toDouble();
          }
          if (lat == null || lon == null) return null;
          return Place(displayName: name, latLng: LatLng(lat, lon));
        })
        .whereType<Place>()
        .toList();
  }

  /// Escapes [input] for safe embedding inside an Overpass QL `~"...",i`
  /// regex literal (both regex metacharacters and the QL string's own
  /// double-quote delimiter) so a user-typed query can only ever match
  /// itself literally, never alter the query's structure.
  static String _escapeForOverpassRegex(String input) {
    const special = r'\.*+?^${}()|[]"';
    final buffer = StringBuffer();
    for (final ch in input.split('')) {
      if (special.contains(ch)) buffer.write('\\');
      buffer.write(ch);
    }
    return buffer.toString();
  }
}
