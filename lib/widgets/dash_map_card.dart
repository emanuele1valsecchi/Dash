import 'package:dash/config/map_style.dart';
import 'package:dash/decorations/card_decorations.dart';
import 'package:dash/extensions/responsive_spacing.dart';
import 'package:dash/services/cached_tile_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:material_symbols_icons/symbols.dart';

/// One measurement in a [DashMapCard]'s bottom-left strip.
class DashMapCardStat {
  final IconData icon;
  final String label;

  /// Overrides the default text/icon colour — used to make a loop badge stand
  /// out. Always a palette colour from the caller, never a literal.
  final Color? color;

  const DashMapCardStat({
    required this.icon,
    required this.label,
    this.color,
  });
}

/// The card treatment shared by every "here is a path, with some numbers on
/// it" surface: a non-interactive map preview of the path, the name in the
/// top-left, an optional action button in the top-right, and a strip of
/// measurements along the bottom.
///
/// Exists so a planned route ([DashRouteCard]) and a completed run
/// ([DashRunCard]) look identical without either of them owning a second copy
/// of the map/overlay plumbing — the two differ only in which numbers they
/// put in [stats] and what tapping them does.
class DashMapCard extends StatelessWidget {
  /// Fraction of the screen's height the card occupies. **Null means "fill
  /// whatever height the parent gives me"**, which is what a horizontally
  /// scrolling list wants — there the cross axis is already tightly
  /// constrained by the viewport, so a self-imposed height would just fight
  /// it.
  final double? heightFactor;

  /// Fraction of the screen's width. 1.0 (a full-width card in a vertical
  /// list) is clamped by the incoming constraints, so list padding still
  /// applies.
  final double widthFactor;

  final List<LatLng> polyline;
  final String title;

  /// Optional second line under [title] — e.g. crediting the original runner
  /// of a favourited route, or a run's date.
  final String? subtitle;

  final List<DashMapCardStat> stats;

  final VoidCallback onTap;

  /// Makes the name itself tappable and puts a pencil beside it — used where
  /// the viewer may rename the thing without opening it. Null (the default)
  /// leaves the name inert, so a card never advertises an edit the viewer
  /// cannot perform.
  final VoidCallback? onTitleTap;

  /// A small glyph between the name and the pencil — used to mark one of your
  /// own routes as private, which is otherwise invisible from a list.
  final IconData? titleBadge;

  /// The top-right overlay button. Omitted entirely when null, so a list with
  /// no per-card action doesn't show a button that does nothing.
  final VoidCallback? onActionTap;
  final IconData actionIcon;
  final double actionIconFill;

  const DashMapCard({
    super.key,
    this.heightFactor,
    this.widthFactor = 1.0,
    required this.polyline,
    required this.title,
    this.subtitle,
    this.stats = const [],
    required this.onTap,
    this.onTitleTap,
    this.titleBadge,
    this.onActionTap,
    this.actionIcon = Symbols.favorite_rounded,
    this.actionIconFill = 0,
  });

  @override
  Widget build(BuildContext context) {
    final bool hasValidPolyline = polyline.length >= 2;

    return Container(
      height: heightFactor == null
          ? null
          : MediaQuery.heightOf(context) * heightFactor!,
      width: MediaQuery.widthOf(context) * widthFactor,
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
                          ? _buildMap(context)
                          : _buildPlaceholder(context),
                    ),
                  ),
                ),
                _buildTitle(context),
                if (onActionTap != null) _buildAction(context),
                if (stats.isNotEmpty) _buildStats(context),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMap(BuildContext context) {
    return FlutterMap(
      options: MapOptions(
        initialCameraFit: CameraFit.bounds(
          bounds: LatLngBounds.fromPoints(polyline),
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
              points: polyline,
              color: Theme.of(context).colorScheme.tertiary,
              strokeWidth: 4.0,
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildPlaceholder(BuildContext context) {
    return Center(
      child: Icon(
        Symbols.route_rounded,
        fill: 1,
        size: Theme.of(context).textTheme.displayLarge!.fontSize,
        color: Theme.of(context).colorScheme.outline,
      ),
    );
  }

  Widget _buildTitle(BuildContext context) {
    final TextStyle textStyle = Theme.of(context).textTheme.bodyMedium!;
    final String? creditLine = subtitle;

    return _OverlayContainer(
      position: _OverlayContainerPosition.topLeft,
      // A long name (or a subtitle) must not run under the action button in
      // the opposite corner, so the overlay is bounded rather than sized
      // purely to its text.
      maxWidth: MediaQuery.widthOf(context) * widthFactor * 0.6,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // A pencil appears only when [onTitleTap] is wired up. Cards used to
          // carry a leading glyph per route source unconditionally (a pencil
          // for your own, a heart for a favourite), which advertised an edit
          // they did not offer — the glyph is now the affordance itself, and
          // is absent wherever the viewer cannot rename.
          GestureDetector(
            onTap: onTitleTap,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              spacing: ResponsiveSpacing().sm / 2,
              children: [
                Flexible(
                  child: Text(
                    title,
                    style: textStyle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (titleBadge != null)
                  Icon(
                    titleBadge,
                    fill: 1,
                    size: textStyle.fontSize,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                if (onTitleTap != null)
                  Icon(
                    Symbols.edit_rounded,
                    size: textStyle.fontSize,
                    color: Theme.of(context).colorScheme.secondary,
                  ),
              ],
            ),
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
      ),
    );
  }

  Widget _buildAction(BuildContext context) {
    return _OverlayContainer(
      position: _OverlayContainerPosition.topRight,
      child: GestureDetector(
        onTap: onActionTap,
        child: Icon(
          actionIcon,
          fill: actionIconFill,
          color: Theme.of(context).colorScheme.secondary,
        ),
      ),
    );
  }

  Widget _buildStats(BuildContext context) {
    final spacing = ResponsiveSpacing();
    // Deliberately `bodySmall`, not the ambient body style: three stats plus
    // their icons and separators do not fit across a card that is only ~78%
    // of the screen wide (the profile rows), and this strip is supporting
    // detail rather than something to read at a glance.
    final textStyle = Theme.of(context).textTheme.bodySmall!.copyWith(
          fontWeight: FontWeight.w500,
        );

    final children = <Widget>[];

    for (final stat in stats) {
      if (children.isNotEmpty) {
        children.add(
          Padding(
            padding: EdgeInsets.symmetric(horizontal: spacing.sm / 2),
            child: Text('·', style: textStyle),
          ),
        );
      }
      children
        ..add(Icon(stat.icon, size: 16, color: stat.color))
        ..add(const SizedBox(width: 3))
        // Flexible + ellipsis is the actual guarantee against an overflow:
        // the sizes above make it fit in practice, but an unusually long
        // value (or a large text-scale setting) must degrade rather than
        // paint the debug stripes.
        ..add(
          Flexible(
            child: Text(
              stat.label,
              style: stat.color == null
                  ? textStyle
                  : textStyle.copyWith(color: stat.color),
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        );
    }

    return _OverlayContainer(
      position: _OverlayContainerPosition.bottomLeft,
      maxWidth: MediaQuery.widthOf(context) * widthFactor,
      padding: EdgeInsets.symmetric(
        horizontal: spacing.md * 0.75,
        vertical: spacing.sm,
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: children),
    );
  }
}

enum _OverlayContainerPosition {
  topLeft,
  topRight,
  bottomLeft,
  bottomRight,
}

class _OverlayContainer extends StatelessWidget {
  final Widget child;
  final _OverlayContainerPosition position;

  /// Caps the overlay's width so its text ellipsizes instead of colliding
  /// with the overlay in the opposite corner. Null leaves it sized to its
  /// content.
  final double? maxWidth;

  /// Defaults to the card's usual [SpacingContext.paddingMd]; the stats strip
  /// runs tighter, since it is the widest thing on the card.
  final EdgeInsetsGeometry? padding;

  const _OverlayContainer({
    required this.position,
    required this.child,
    this.maxWidth,
    this.padding,
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
          // The overlay sits inset from both edges, so its own cap has to
          // leave room for those insets or a full-width strip would overflow
          // the card it floats on.
          maxWidth: maxWidth == null
              ? double.infinity
              : (maxWidth! - edgeDistance * 2).clamp(0.0, double.infinity),
        ),
        child: Container(
          padding: padding ?? context.paddingMd,
          decoration: BoxDecoration(
            color: Theme.of(context).cardColor.withAlpha(238),
            borderRadius: getDashCardDecorationBorderRadius(context) / 2,
          ),
          child: child,
        ),
      ),
    );
  }
}
