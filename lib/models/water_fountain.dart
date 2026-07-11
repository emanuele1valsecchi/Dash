import 'package:latlong2/latlong.dart';

/// A drinking-water point of interest sourced from OpenStreetMap.
class WaterFountain {
  final String id;
  final LatLng position;

  const WaterFountain({required this.id, required this.position});
}