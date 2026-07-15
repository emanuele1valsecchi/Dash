import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

import '../../models/water_fountain.dart';

/// Blue drinking-water markers, mirroring how Strava surfaces water-fountain
/// POIs on its map. A solid white badge behind the icon (rather than a blur
/// filter) keeps rendering cheap and the icon unambiguously blue against any
/// basemap tile underneath it.
///
/// Fountains are fetched independently of zoom (see `WaterFountainService`) —
/// this widget is what actually decides whether they're drawn, via the
/// explicit [visible] flag the embedding screen computes from its own
/// `MapOptions.onPositionChanged` (compared against [minZoomToShow]) and
/// passes down, rather than this widget reading the ambient map camera
/// itself. No fetch/network is involved in flipping [visible] — it's a pure
/// redraw, so zooming back in shows already-loaded fountains instantly.
class WaterFountainMarkerLayer extends StatelessWidget {
  final List<WaterFountain> fountains;

  /// Whether fountains should currently be drawn at all — the embedding
  /// screen owns this, computed from its live map zoom vs [minZoomToShow].
  final bool visible;

  const WaterFountainMarkerLayer({
    super.key,
    required this.fountains,
    required this.visible,
  });

  static const Color _iconColor = Color(0xFF1E88E5);

  /// Below this zoom, fountains hide. The previous value (10.0) was picked
  /// from a bad distance estimate in the original comment here — in slippy
  /// map terms z10 is actually a ~40km-wide viewport on a phone screen (most
  /// of the way to Milan-to-Como distances), so "zoom out" had to mean
  /// "almost the whole region" before anything disappeared. z13 is roughly a
  /// 5km-wide viewport — "the neighbourhood/town I'm looking at", not "every
  /// fountain in the province" — which is what was actually wanted. Every
  /// screen's default zoom (14 and up) is comfortably above this, so
  /// fountains are always visible on first opening a map.
  static const double minZoomToShow = 13.0;

  @override
  Widget build(BuildContext context) {
    if (!visible) return const SizedBox.shrink();

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