import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

import '../../models/water_fountain.dart';

/// Blue drinking-water markers, mirroring how Strava surfaces water-fountain
/// POIs on its map. A solid white badge behind the icon (rather than a blur
/// filter) keeps rendering cheap and the icon unambiguously blue against any
/// basemap tile underneath it.
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
              // flutter_map culls off-screen markers every frame; without a
              // stable key here, panning can re-associate a Positioned with
              // the wrong fountain and leave a stale marker on screen.
              key: ValueKey(f.id),
              point: f.position,
              width: 24,
              height: 24,
              child: Container(
                decoration: const BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(color: Colors.black26, blurRadius: 2),
                  ],
                ),
                padding: const EdgeInsets.all(3),
                child: const Icon(
                  Icons.water_drop_rounded,
                  color: _iconColor,
                  size: 16,
                ),
              ),
            ),
          )
          .toList(),
    );
  }
}