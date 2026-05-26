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

  /// Straight-line fallback used when ORS is unreachable or returns no route.
  static RouteSegment straightLine(LatLng from, LatLng to) {
    final meters = const Distance()(from, to);
    return RouteSegment(polyline: [from, to], distanceMeters: meters);
  }
}