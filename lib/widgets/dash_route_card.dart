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

  /// The top-right overlay button. Omitted entirely when [onActionTap] is
  /// null, so a list with no per-card action doesn't show a button that
  /// does nothing.
  final VoidCallback? onActionTap;
  final IconData actionIcon;
  final double actionIconFill;

  /// Optional second line under the route's name — used by the favourites
  /// list to credit whoever originally ran the route (see
  /// `RouteAuthorService`). Null when there is no one to credit.
  final String? subtitle;

  const DashRouteCard({
    super.key,
    this.heightFactor = 0.28,
    required this.entry,
    required this.onTap,
    this.onActionTap,
    this.actionIcon = Symbols.favorite_rounded,
    this.actionIconFill = 0,
    this.subtitle,
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

                if (onActionTap != null) _buildTopRightActions(context),

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
    final String? creditLine = subtitle;

    return _OverlayContainer(
      position: _OverlayContainerPosition.topLeft,
      // A long name (or an author line) must not run under the action button
      // in the opposite corner, so the overlay is bounded rather than sized
      // purely to its text.
      maxWidthFactor: 0.6,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Name only — deliberately no leading glyph. It used to carry one
          // per route source (a pencil for your own, a heart for a
          // favourite), which read as an affordance for something this card
          // does not offer: renaming happens on the detail page, and the
          // top-right button is already the favourite/delete action.
          Text(
            routeName,
            style: textStyle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          if (creditLine != null)
            Text(
              creditLine,
              style: Theme.of(context).textTheme.bodySmall!.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
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
          actionIcon,
          fill: actionIconFill,
          color: Theme.of(context).colorScheme.secondary,
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
    final loopColor = Theme.of(context).colorScheme.tertiary;

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
            Icon(Icons.loop_rounded, size: 18, color: loopColor),
            const SizedBox(width: 4),
            Text('Loop', style: TextStyle(fontWeight: FontWeight.w500, color: loopColor)),
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

  /// Caps the overlay's width to this fraction of the screen, so its text
  /// ellipsizes instead of colliding with the overlay in the opposite
  /// corner. Null leaves it sized to its content, as every overlay was
  /// before this existed.
  final double? maxWidthFactor;

  const _OverlayContainer({
    required this.position,
    required this.child,
    this.maxWidthFactor,
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
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: maxWidthFactor == null
              ? double.infinity
              : MediaQuery.widthOf(context) * maxWidthFactor!,
        ),
        child: Container(
          padding: context.paddingMd,
          decoration: BoxDecoration(
            color: Theme.of(context).cardColor.withAlpha(238),
            borderRadius: getDashCardDecorationBorderRadius(context) / 2,
          ),
          child: child,
        ),
      )
    );
  }
}
