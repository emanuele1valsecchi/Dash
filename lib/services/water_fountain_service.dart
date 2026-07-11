import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../models/water_fountain.dart';

/// Fetches nearby drinking-water points of interest from OpenStreetMap's
/// Overpass API (`amenity=drinking_water` nodes) — the same free, keyless
/// data source the app's OSM-based routing/search already relies on.
///
/// In-memory cached by a coarse lat/lon grid cell so panning the map by a
/// few metres (or a GPS breadcrumb update during a run) reuses the last
/// result instead of re-hitting Overpass on every frame.
class WaterFountainService {
  static const String _overpassUrl = 'https://overpass-api.de/api/interpreter';

  /// ~500m grid at mid-latitudes — coarse enough to make nearby lookups
  /// cache-hit, fine enough that the cached radius still covers the query.
  static const double _gridDegrees = 0.005;

  final Map<String, List<WaterFountain>> _cache = {};

  Future<List<WaterFountain>> fetchNearby(
    LatLng center, {
    double radiusMeters = 1500,
  }) async {
    final cacheKey = _cacheKeyFor(center, radiusMeters);
    final cached = _cache[cacheKey];
    if (cached != null) return cached;

    final query = '[out:json][timeout:10];'
        'node["amenity"="drinking_water"]'
        '(around:${radiusMeters.round()},${center.latitude},${center.longitude});'
        'out body;';

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
      if (response.statusCode != 200) return [];

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
      // Overpass is a best-effort public service — a fountain layer that
      // fails to load silently is preferable to breaking the map.
      return [];
    }
  }

  String _cacheKeyFor(LatLng center, double radiusMeters) {
    final lat = (center.latitude / _gridDegrees).round() * _gridDegrees;
    final lon = (center.longitude / _gridDegrees).round() * _gridDegrees;
    return '${lat.toStringAsFixed(3)},${lon.toStringAsFixed(3)},${radiusMeters.round()}';
  }
}