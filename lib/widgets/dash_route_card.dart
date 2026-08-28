import 'package:dash/config/map_style.dart';
import 'package:dash/decorations/card_decorations.dart';
import 'package:dash/extensions/responsive_spacing.dart';
import 'package:dash/services/cached_tile_provider.dart';
import 'package:dash/services/route_repository.dart';
import 'package:dash/widgets/profile/route_source.dart';
import 'package:dash/widgets/units_scope.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:material_symbols_icons/symbols.dart';

class DashRouteCard extends StatelessWidget{
  final double heightFactor;

  final RouteEntry entry;
  final VoidCallback onTap;
  final VoidCallback onActionTap;

  const DashRouteCard({
    super.key, 
    this.heightFactor = 0.28,
    required this.entry, 
    required this.onTap, 
    required this.onActionTap
  });

  @override
  Widget build(BuildContext context) {
    final SavedRoute route = entry.route;

    final bool hasValidPolyline = route.routePolyline.length >= 2;

    return Container(
      height: MediaQuery.heightOf(context) * heightFactor,
      width: MediaQuery.widthOf(context),
      decoration: getDashCardDecoration(context),
      child: ClipRRect(
        borderRadius: getDashCardDecorationBorderRadius(context),
        child: Material(
          color: Theme.of(context).cardColor,
          child: InkWell(
            onTap: onTap,
            child: Stack(
              children: [
                Positioned.fill(
                  child: IgnorePointer(
                    child: Container(
                      color: Theme.of(context).cardColor,
                      child: hasValidPolyline 
                        ? FlutterMap(
                            options: MapOptions(
                              initialCameraFit: CameraFit.bounds(
                                bounds: LatLngBounds.fromPoints(route.routePolyline),
                                padding: context.paddingXl + context.paddingMd, 
                              ),
                              minZoom: MapStyle.minZoom,
                              interactionOptions: const InteractionOptions(
                                flags: InteractiveFlag.none,
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
                                    points: route.routePolyline,
                                    color: Theme.of(context).colorScheme.tertiary,
                                    strokeWidth: 4.0,
                                  ),
                                ],
                              ),
                            ],
                          )
                        : Center(
                          child: Icon(
                            Symbols.route_rounded,
                            fill: 1,
                            size: Theme.of(context).textTheme.displayLarge!.fontSize, 
                            color: Theme.of(context).colorScheme.outline
                          )
                        ),
                    ),
                  ),
                ),

                _buildTopLeftName(context, route.name),

                _buildTopRightActions(context),

                _buildBottomLeftData(context, route),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTopLeftName(BuildContext context, String routeName){
    final TextStyle textStyle = Theme.of(context).textTheme.bodyMedium!;

    return _OverlayContainer(
      position: _OverlayContainerPosition.topLeft,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        mainAxisAlignment: MainAxisAlignment.center,
        spacing: ResponsiveSpacing().sm,
        children: [
          Icon(
            Symbols.edit, 
            size: textStyle.fontSize,
          ),
          Text(
            routeName,
            style: textStyle,
          ),
        ],
      )
    );
  }

  Widget _buildTopRightActions(BuildContext context){
    return _OverlayContainer(
      position: _OverlayContainerPosition.topRight, 
      child: GestureDetector(
        onTap: onActionTap,
        child: Icon(
          Symbols.favorite_rounded,
        )
      )
    );
  }

  Widget _buildBottomLeftData(BuildContext context, SavedRoute route){
    final distLabel = Units.of(context).distance(route.distanceKm * 1000);
    final timeMin = route.estimatedTimeMin;
    final timeLabel = timeMin < 60
        ? '${timeMin.round()} min'
        : '${(timeMin / 60).floor()}h ${(timeMin % 60).round()}min';

    return _OverlayContainer(
      position: _OverlayContainerPosition.bottomLeft, 
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.straighten_rounded, size: 18),
          const SizedBox(width: 4),
          Text(distLabel, style: const TextStyle(fontWeight: FontWeight.w500)),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 6.0),
            child: Text("·", style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          const Icon(Icons.timer_outlined, size: 18),
          const SizedBox(width: 4),
          Text(timeLabel, style: const TextStyle(fontWeight: FontWeight.w500)),
          
          if (route.isLoop) ...[
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 6.0),
              child: Text("·", style: TextStyle(fontWeight: FontWeight.bold)),
            ),
            const Icon(Icons.loop_rounded, size: 18, color: Color(0xFF4A8C52)),
            const SizedBox(width: 4),
            const Text('Loop', style: TextStyle(fontWeight: FontWeight.w500, color: Color(0xFF4A8C52))),
          ],
        ]
      ) 
    );
  }
}

enum _OverlayContainerPosition{
  topLeft,
  topRight,
  bottomLeft,
  bottomRight,
}

class _OverlayContainer extends StatelessWidget{
  final Widget child;
  final _OverlayContainerPosition position;

  const _OverlayContainer({ 
    required this.position,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {

    final bool isTop = (position == _OverlayContainerPosition.topLeft) ||
      (position == _OverlayContainerPosition.topRight);
    
    final bool isBottom = (position == _OverlayContainerPosition.bottomLeft) ||
      (position == _OverlayContainerPosition.bottomRight);

    final bool isRight = (position == _OverlayContainerPosition.bottomRight) ||
      (position == _OverlayContainerPosition.topRight);

    final bool isLeft = (position == _OverlayContainerPosition.bottomLeft) ||
      (position == _OverlayContainerPosition.topLeft);

    final edgeDistance = ResponsiveSpacing().sm;

    return Positioned(
      top: isTop ? edgeDistance : null,
      left: isLeft ? edgeDistance : null,
      bottom: isBottom ? edgeDistance : null,
      right: isRight ? edgeDistance : null,
      child: Container(
        padding: context.paddingMd,
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor.withAlpha(238),
          borderRadius: getDashCardDecorationBorderRadius(context) / 2,
        ),
        child: child,
      )
    );
  }
}