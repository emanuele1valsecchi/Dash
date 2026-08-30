import 'package:dash/services/route_repository.dart';
import 'package:dash/widgets/dash_map_card.dart';
import 'package:dash/widgets/profile/route_source.dart';
import 'package:dash/widgets/units_scope.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

/// A saved route as a card: map preview, name, distance/time/loop.
///
/// The card treatment itself lives in [DashMapCard], shared with
/// [DashRunCard] — this class only decides which numbers a *route* shows and
/// how they are formatted.
class DashRouteCard extends StatelessWidget {
  /// See [DashMapCard.heightFactor] — null fills the height the parent gives,
  /// which is what the horizontally scrolling profile sections want.
  final double? heightFactor;
  final double widthFactor;

  final RouteEntry entry;
  final VoidCallback onTap;

  /// See [DashMapCard.onTitleTap] — set only where the viewer may rename this
  /// route without opening it.
  final VoidCallback? onTitleTap;

  /// Marks the card with a padlock when the route is private. Only meaningful
  /// on your own list — a visitor never sees a private route at all, so a
  /// badge there would be noise.
  final bool showPrivateBadge;

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
    this.widthFactor = 1.0,
    required this.entry,
    required this.onTap,
    this.onTitleTap,
    this.showPrivateBadge = false,
    this.onActionTap,
    this.actionIcon = Symbols.favorite_rounded,
    this.actionIconFill = 0,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final SavedRoute route = entry.route;
    final timeMin = route.estimatedTimeMin;

    return DashMapCard(
      heightFactor: heightFactor,
      widthFactor: widthFactor,
      polyline: route.routePolyline,
      title: route.name,
      subtitle: subtitle,
      onTap: onTap,
      onTitleTap: onTitleTap,
      titleBadge: showPrivateBadge && !route.isPublic
          ? Symbols.lock_rounded
          : null,
      onActionTap: onActionTap,
      actionIcon: actionIcon,
      actionIconFill: actionIconFill,
      stats: [
        DashMapCardStat(
          icon: Icons.straighten_rounded,
          label: Units.of(context).distance(route.distanceMeters),
        ),
        DashMapCardStat(
          icon: Icons.timer_outlined,
          label: timeMin < 60
              ? '${timeMin.round()} min'
              : '${(timeMin / 60).floor()}h ${(timeMin % 60).round()}min',
        ),
        if (route.isLoop)
          DashMapCardStat(
            icon: Icons.loop_rounded,
            label: 'Loop',
            color: Theme.of(context).colorScheme.tertiary,
          ),
      ],
    );
  }
}
