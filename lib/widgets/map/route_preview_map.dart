import 'dart:math' as math;

import 'package:dash/config/map_style.dart';
import 'package:dash/decorations/card_decorations.dart';
import 'package:dash/extensions/responsive_spacing.dart';
import 'package:dash/services/cached_tile_provider.dart';
import 'package:dash/utils/geometry_utils.dart';
import 'package:dash/widgets/map/enhanced_map_gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:material_symbols_icons/symbols.dart';

/// An interactive card showing one whole path — a planned route, or the GPS
/// trail of a completed run — fitted to its bounds, with direction arrows
/// along it and pins at each end.
///
/// Shared by [SavedRouteDetailPage] and [RunSessionDetailPage] so the two
/// detail screens are the same screen with different numbers on it, rather
/// than two maps that drift apart.
///
/// Drawn as a plain polyline with **no fill**, even for a closed loop: a run's
/// path isn't guaranteed to be a simple closed shape, and `Polygon` always
/// draws closed, auto-connecting last point to first — which renders a
/// nonsensical self-intersecting fill for an ordinary point-to-point trip.
class RoutePreviewMap extends StatefulWidget {
  final List<LatLng> path;

  /// Suppresses the finish pin when the path is known to return to its own
  /// start (a loop). Endpoints are also compared directly, so this is only
  /// needed where the caller knows something the geometry doesn't.
  final bool isLoop;

  const RoutePreviewMap({
    super.key,
    required this.path,
    this.isLoop = false,
  });

  @override
  State<RoutePreviewMap> createState() => _RoutePreviewMapState();
}

class _RoutePreviewMapState extends State<RoutePreviewMap> {
  final MapController _mapController = MapController();

  /// How many direction arrows to space along the path. Without them a closed
  /// loop gives no clue which way round it was run, or should be.
  static const int _arrowCount = 6;

  /// Start and finish get separate pins only when they are actually distinct.
  /// On a loop they are the same doorstep, and two markers stacked on one
  /// point read as a rendering bug rather than as information.
  static const double _distinctEndpointsMeters = 40;

  bool get _hasPath => widget.path.length >= 2;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      decoration: getDashCardDecoration(context),
      clipBehavior: Clip.antiAlias,
      child: !_hasPath
          ? Center(
              child: Icon(
                Symbols.route_rounded,
                fill: 1,
                size: theme.textTheme.displayLarge!.fontSize,
                color: theme.colorScheme.outline,
              ),
            )
          : EnhancedMapGestures(
              mapController: _mapController,
              child: FlutterMap(
                mapController: _mapController,
                options: MapOptions(
                  initialCameraFit: CameraFit.coordinates(
                    coordinates: widget.path,
                    padding: context.paddingXl,
                  ),
                  minZoom: MapStyle.minZoom,
                  cameraConstraint: CameraConstraint.contain(
                    bounds: MapStyle.safeCameraBounds,
                  ),
                  // Rotation is handled by the wrapping EnhancedMapGestures
                  // (dead-zoned two-finger twist + zoom inertia), shared with
                  // every other interactive map screen.
                  interactionOptions: const InteractionOptions(
                    flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
                  ),
                ),
                children: [
                  TileLayer(
                    urlTemplate: MapStyle.terrainTileUrl,
                    userAgentPackageName: 'com.dash',
                    retinaMode: RetinaMode.isHighDensity(context),
                    tileProvider: CachedTileProvider.instance,
                  ),
                  PolylineLayer(
                    polylines: [
                      Polyline(
                        points: widget.path,
                        color: theme.colorScheme.tertiary,
                        strokeWidth: 5,
                      ),
                    ],
                  ),
                  MarkerLayer(markers: _directionArrows(context)),
                  MarkerLayer(markers: _endpointMarkers(context)),
                ],
              ),
            ),
    );
  }

  List<Marker> _directionArrows(BuildContext context) {
    final color = Theme.of(context).colorScheme.tertiary;

    return GeometryUtils.arrowPositions(widget.path, count: _arrowCount)
        .map(
          (a) => Marker(
            point: a.point,
            width: 20,
            height: 20,
            child: Transform.rotate(
              // arrowPositions reports a compass bearing (0° = north); the
              // glyph points north at 0 rad, so it only needs converting to
              // radians.
              angle: a.bearingDegrees * math.pi / 180,
              child: Icon(
                Symbols.navigation_rounded,
                fill: 1,
                size: 18,
                color: color,
              ),
            ),
          ),
        )
        .toList();
  }

  List<Marker> _endpointMarkers(BuildContext context) {
    final theme = Theme.of(context);
    final start = widget.path.first;
    final end = widget.path.last;

    final markers = <Marker>[
      Marker(
        point: start,
        width: 34,
        height: 34,
        // The pin's tip, not its centre, is what sits on the coordinate.
        alignment: Alignment.topCenter,
        child: Icon(
          Symbols.location_on_rounded,
          fill: 1,
          size: 34,
          color: theme.colorScheme.primary,
        ),
      ),
    ];

    const distance = Distance();
    if (!widget.isLoop && distance(start, end) > _distinctEndpointsMeters) {
      markers.add(
        Marker(
          point: end,
          width: 30,
          height: 30,
          alignment: Alignment.topCenter,
          child: Icon(
            Symbols.sports_score_rounded,
            fill: 1,
            size: 28,
            color: theme.colorScheme.secondary,
          ),
        ),
      );
    }

    return markers;
  }
}
