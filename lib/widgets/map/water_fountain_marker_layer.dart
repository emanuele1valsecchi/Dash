import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

import '../../models/water_fountain.dart';

/// Blue drinking-water markers, mirroring how Strava surfaces water-fountain
/// POIs on its map.
class WaterFountainMarkerLayer extends StatelessWidget {
  final List<WaterFountain> fountains;

  const WaterFountainMarkerLayer({super.key, required this.fountains});

  static const Color _iconColor = Color(0xFF1E88E5);

  @override
  Widget build(BuildContext context) {
    return MarkerLayer(
      markers: fountains
          .map(
            (f) => Marker(
              point: f.position,
              width: 26,
              height: 26,
              child: const Icon(
                Icons.water_drop_rounded,
                color: _iconColor,
                size: 24,
                shadows: [Shadow(color: Colors.black38, blurRadius: 3)],
              ),
            ),
          )
          .toList(),
    );
  }
}