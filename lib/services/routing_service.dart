import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

class RouteSegment {
  final List<LatLng> polyline;
  final double distanceMeters;

  const RouteSegment({required this.polyline, required this.distanceMeters});
}

/// Calls the OpenRouteService foot-walking endpoint and returns a road-snapped
/// polyline plus the walking distance in metres between [origin] and [destination].
///
///   ORS uses a dedicated foot-walking profile that honours OSM tags such as
///   highway=footway/path/pedestrian and access=yes on park paths.
///
/// Returns null on any failure; callers fall back to a straight-line segment.
class RoutingService {

  static const String _apiKey = 'eyJvcmciOiI1YjNjZTM1OTc4NTExMTAwMDFjZjYyNDgiLCJpZCI6IjI5NDdiMWY0YTA2ZDQ4N2M5MGY2ZGY3ZTg4YWRkYTdiIiwiaCI6Im11cm11cjY0In0=';

  static const String _baseUrl =
      'https://api.openrouteservice.org/v2/directions/foot-walking';

  static Future<RouteSegment?> fetchRoute(
      LatLng origin, LatLng destination) async {
    // ORS GET endpoint: start and end are longitude,latitude (GeoJSON order).
    final uri = Uri.parse(
      '$_baseUrl'
      '?api_key=$_apiKey'
      '&start=${origin.longitude},${origin.latitude}'
      '&end=${destination.longitude},${destination.latitude}',
    );

    try {
      final response =
          await http.get(uri).timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) return null;

      // ORS returns a GeoJSON FeatureCollection.
      // Structure:
      //   features[0].geometry.coordinates  → List<[lon, lat]>
      //   features[0].properties.summary.distance → metres (double)
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final features = json['features'] as List<dynamic>;
      if (features.isEmpty) return null;

      final feature = features[0] as Map<String, dynamic>;
      final props = feature['properties'] as Map<String, dynamic>;
      final summary = props['summary'] as Map<String, dynamic>;
      final double distance = (summary['distance'] as num).toDouble();

      final geometry = feature['geometry'] as Map<String, dynamic>;
      final rawCoords = geometry['coordinates'] as List<dynamic>;

      // GeoJSON coordinates are [longitude, latitude] — flip to LatLng(lat, lng).
      final polyline = rawCoords
          .map((c) => LatLng(
                (c[1] as num).toDouble(),
                (c[0] as num).toDouble(),
              ))
          .toList();

      return RouteSegment(polyline: polyline, distanceMeters: distance);
    } catch (_) {
      return null;
    }
  }

  /// Requests up to [targetCount] alternative foot-walking routes from ORS
  /// using the POST endpoint (the GET endpoint does not support alternatives).
  ///
  /// Returns a non-empty list; falls back to a single straight-line segment
  /// if the network or API is unreachable.
  static Future<List<RouteSegment>> fetchAlternatives(
    LatLng origin,
    LatLng destination, {
    int targetCount = 3,
  }) async {
    final uri = Uri.parse(
        'https://api.openrouteservice.org/v2/directions/foot-walking/geojson');

    final body = jsonEncode({
      'coordinates': [
        [origin.longitude, origin.latitude],
        [destination.longitude, destination.latitude],
      ],
      'alternative_routes': {
        'share_factor': 0.6,
        'target_count': targetCount,
        'weight_factor': 1.4,
      },
    });

    try {
      final response = await http
          .post(
            uri,
            headers: {
              'Authorization': _apiKey,
              'Content-Type': 'application/json; charset=UTF-8',
              'Accept': 'application/json, application/geo+json',
            },
            body: body,
          )
          .timeout(const Duration(seconds: 12));

      if (response.statusCode != 200) {
        return [straightLine(origin, destination)];
      }

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final features = json['features'] as List<dynamic>;
      if (features.isEmpty) return [straightLine(origin, destination)];

      return features.map((f) {
        final feature = f as Map<String, dynamic>;
        final props = feature['properties'] as Map<String, dynamic>;
        final summary = props['summary'] as Map<String, dynamic>;
        final dist = (summary['distance'] as num).toDouble();
        final coords =
            (feature['geometry'] as Map<String, dynamic>)['coordinates']
                as List<dynamic>;
        final poly = coords
            .map((c) => LatLng(
                  (c[1] as num).toDouble(),
                  (c[0] as num).toDouble(),
                ))
            .toList();
        return RouteSegment(polyline: poly, distanceMeters: dist);
      }).toList();
    } catch (_) {
      return [straightLine(origin, destination)];
    }
  }

  /// Straight-line fallback used when ORS is unreachable or returns no route.
  static RouteSegment straightLine(LatLng from, LatLng to) {
    final meters = const Distance()(from, to);
    return RouteSegment(polyline: [from, to], distanceMeters: meters);
  }
}