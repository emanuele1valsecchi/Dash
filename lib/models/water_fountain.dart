import 'package:latlong2/latlong.dart';

/// A drinking-water point of interest sourced from OpenStreetMap.
class WaterFountain {
  final String id;
  final LatLng position;

  const WaterFountain({required this.id, required this.position});

  Map<String, dynamic> toJson() => {
        'i': id,
        'lat': position.latitude,
        'lon': position.longitude,
      };

  /// Returns `null` if [json] is missing/malformed fields, rather than
  /// throwing — a corrupt disk-cache entry should be dropped, not crash the
  /// whole cache load.
  static WaterFountain? fromJson(Map<String, dynamic> json) {
    final id = json['i'] as String?;
    final lat = (json['lat'] as num?)?.toDouble();
    final lon = (json['lon'] as num?)?.toDouble();
    if (id == null || lat == null || lon == null) return null;
    return WaterFountain(id: id, position: LatLng(lat, lon));
  }
}