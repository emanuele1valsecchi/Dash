import 'dart:math' as math;

import 'package:dash/config/map_style.dart';
import 'package:dash/decorations/card_decorations.dart';
import 'package:dash/extensions/dash_snackbar.dart';
import 'package:dash/extensions/responsive_spacing.dart';
import 'package:dash/services/cached_tile_provider.dart';
import 'package:dash/services/favorite_route_repository.dart';
import 'package:dash/services/route_repository.dart';
import 'package:dash/utils/geometry_utils.dart';
import 'package:dash/widgets/dash_navigation_top_bar.dart';
import 'package:dash/widgets/map/enhanced_map_gestures.dart';
import 'package:dash/widgets/profile/route_source.dart';
import 'package:dash/widgets/units_scope.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:material_symbols_icons/symbols.dart';

/// Full view of one saved route — the user's own, or one they favourited —
/// reached by tapping a card in the route library's first section.
///
/// Pops with the route's polyline when the user chooses **Run**, and with
/// null when they cancel or go back. The caller is what decides what "run"
/// means: the library page forwards the polyline up to `HomeScreen`, which
/// pushes `RunTrackingPage` with it — the same shape route creation and
/// route search already use for their own "Run now" (see the route-search
/// bullet in CLAUDE.md), so finishing the run returns to the home screen
/// rather than back into a stale route list.
class SavedRouteDetailPage extends StatefulWidget {
  final SavedRoute route;

  /// Which list this route came from — it decides where a rename is written.
  /// An owned route's name lives on the `routes` doc itself; a favourite's is
  /// per-user and lives on that user's own `favoriteRoutes` link, since the
  /// shared route it points at is read by everyone who favourited the same
  /// run. See [_rename].
  final RouteSource source;

  /// Who originally ran this route, when it is a favourited run and the
  /// author could be resolved (see `RouteAuthorService`). Null for the
  /// user's own hand-planned routes, and for a route whose author is
  /// deliberately no longer knowable.
  final String? authorName;

  const SavedRouteDetailPage({
    super.key,
    required this.route,
    required this.source,
    this.authorName,
  });

  @override
  State<SavedRouteDetailPage> createState() => _SavedRouteDetailPageState();
}

class _SavedRouteDetailPageState extends State<SavedRouteDetailPage> {
  final MapController _mapController = MapController();

  /// Matches the cap the `favoriteSession` Cloud Function already applies to
  /// a favourite's name, so a rename can never exceed what a fresh favourite
  /// is allowed to store.
  static const int _maxNameLength = 120;

  /// Held in state rather than read from the widget, so a rename shows
  /// immediately instead of waiting for the list behind to re-read.
  late String _name = widget.route.name;

  /// How many direction arrows to space along the route. Same device as
  /// `RunSessionDetailPage`'s path preview — without them a closed loop
  /// gives no clue which way round it is meant to be run.
  static const int _arrowCount = 6;

  /// Start and finish are drawn as separate pins only when they are actually
  /// distinct. On a loop they are the same doorstep, and two markers stacked
  /// on one point read as a rendering bug rather than as information.
  static const double _distinctEndpointsMeters = 40;

  List<LatLng> get _polyline => widget.route.routePolyline;

  bool get _hasPath => _polyline.length >= 2;

  /// Only the two shapes the route library actually shows can be renamed:
  /// an owned route (the doc is the user's own) and a favourite (their own
  /// link carries the name). Anything else has nowhere to write one.
  bool get _canRename =>
      widget.source == RouteSource.owned ||
      widget.source == RouteSource.favorite;

  @override
  Widget build(BuildContext context) {
    final spacing = ResponsiveSpacing();

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: DashNavigationTopBar(
        title: _name,
        actions: [
          if (_canRename)
            IconButton(
              icon: const Icon(Symbols.edit_rounded),
              tooltip: 'Rename route',
              onPressed: _promptRename,
            ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: spacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: spacing.md,
            children: [
              if (widget.authorName != null) _buildAuthorLine(context),
              Expanded(child: _buildMap(context)),
              _buildStats(context),
              _buildActions(context),
              SizedBox(height: spacing.sm),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAuthorLine(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodyMedium!.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: ResponsiveSpacing().sm,
      children: [
        Icon(
          Symbols.directions_run_rounded,
          size: style.fontSize,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        Text('Originally run by ${widget.authorName}', style: style),
      ],
    );
  }

  // ── Rename ────────────────────────────────────────────────────────────────

  Future<void> _promptRename() async {
    final String? newName = await showDialog<String>(
      context: context,
      builder: (_) => _RenameRouteDialog(
        initialName: _name,
        maxLength: _maxNameLength,
      ),
    );

    if (newName == null || newName == _name || !mounted) return;
    await _rename(newName);
  }

  /// Writes the new name to whichever document actually owns it.
  ///
  /// **The two cases are not interchangeable.** An owned route's name lives
  /// on the `routes` doc; a favourite's lives on the user's own
  /// `favoriteRoutes` link, because the shared route it points at has no
  /// owner and is read by every user who favourited the same run — so two
  /// people can call it whatever they like, and `firestore.rules` denies the
  /// client every write to it regardless.
  Future<void> _rename(String newName) async {
    final previous = _name;
    // Optimistic: the write is a single field on a document the user owns,
    // and reverting on failure is cheaper than blocking the UI behind it.
    setState(() => _name = newName);

    try {
      switch (widget.source) {
        case RouteSource.owned:
          await RouteRepository.instance.renameRoute(widget.route.id, newName);
        case RouteSource.favorite:
          await FavoriteRouteRepository.instance
              .renameFavorite(widget.route.id, newName);
        case RouteSource.created:
          return;
      }
    } catch (e) {
      debugPrint('Could not rename route ${widget.route.id}: $e');
      if (!mounted) return;
      setState(() => _name = previous);
      context.showErrorSnackBar('Could not rename that route');
    }
  }

  // ── Map ───────────────────────────────────────────────────────────────────

  Widget _buildMap(BuildContext context) {
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
                    coordinates: _polyline,
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
                        points: _polyline,
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

    return GeometryUtils.arrowPositions(_polyline, count: _arrowCount)
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
    final start = _polyline.first;
    final end = _polyline.last;

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
    if (!widget.route.isLoop &&
        distance(start, end) > _distinctEndpointsMeters) {
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

  // ── Stats ─────────────────────────────────────────────────────────────────

  Widget _buildStats(BuildContext context) {
    final units = Units.of(context);
    final route = widget.route;
    final timeMin = route.estimatedTimeMin;

    return Row(
      spacing: ResponsiveSpacing().sm,
      children: [
        Expanded(
          child: _StatTile(
            icon: Symbols.straighten_rounded,
            label: 'Distance',
            value: units.distance(route.distanceMeters),
          ),
        ),
        Expanded(
          child: _StatTile(
            icon: Symbols.timer_rounded,
            label: 'Est. time',
            value: timeMin < 60
                ? '${timeMin.round()} min'
                : '${(timeMin / 60).floor()}h ${(timeMin % 60).round()}min',
          ),
        ),
        Expanded(
          child: route.isLoop
              ? _StatTile(
                  icon: Symbols.loop_rounded,
                  label: 'Area',
                  value: units.area(route.loopAreaM2),
                )
              : _StatTile(
                  icon: Symbols.local_fire_department_rounded,
                  label: 'Energy',
                  value: units.energy(route.estimatedCalories),
                ),
        ),
      ],
    );
  }

  // ── Actions ───────────────────────────────────────────────────────────────

  Widget _buildActions(BuildContext context) {
    final textStyle = Theme.of(context).textTheme.bodyMedium!;

    return Row(
      spacing: ResponsiveSpacing().md,
      children: [
        Expanded(
          child: OutlinedButton(
            style: OutlinedButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.secondary,
              textStyle: textStyle,
              padding: context.paddingMd,
            ),
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
        ),
        Expanded(
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.primary,
              foregroundColor: Theme.of(context).colorScheme.onPrimary,
              textStyle: textStyle,
              padding: context.paddingMd,
            ),
            // Nothing to run without a path — the run screen needs at least
            // two points to give guidance against.
            onPressed: _hasPath
                ? () => Navigator.of(context).pop<List<LatLng>>(_polyline)
                : null,
            icon: Icon(
              Symbols.play_arrow_rounded,
              fill: 1,
              size: textStyle.fontSize,
            ),
            label: const Text('Run'),
          ),
        ),
      ],
    );
  }
}

/// One labelled measurement under the map, in the same card treatment as
/// every other surface on this screen.
class _StatTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _StatTile({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final labelStyle = theme.textTheme.bodySmall!.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    return Container(
      padding: context.paddingMd,
      decoration: getDashCardDecoration(context),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: ResponsiveSpacing().sm / 2,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            spacing: ResponsiveSpacing().sm / 2,
            children: [
              Icon(
                icon,
                size: labelStyle.fontSize,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              Flexible(
                child: Text(
                  label,
                  style: labelStyle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          Text(
            value,
            style: theme.textTheme.titleMedium!.copyWith(
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.secondary,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

/// The rename prompt.
///
/// **It owns its own `TextEditingController`, and that is the whole reason it
/// is a widget rather than an inline `AlertDialog` in a builder.** The obvious
/// version — create the controller, `await showDialog(...)`, then dispose it —
/// disposes it the instant the future completes, which is when the dialog
/// *starts* its exit transition, not when it finishes. The `TextField` is
/// still mounted and still bound to that controller for the rest of the
/// animation, so tearing it down afterwards throws; the visible symptom is an
/// unrelated-looking `dependents.isEmpty` assertion in `framework.dart`,
/// because an exception during a subtree's deactivation leaves a dependent
/// registered on an ancestor `InheritedElement`, which asserts on its own
/// deactivation a moment later.
///
/// Owning the controller in a [State] ties its disposal to the dialog
/// subtree's actual unmount, which is the only correct moment.
class _RenameRouteDialog extends StatefulWidget {
  final String initialName;
  final int maxLength;

  const _RenameRouteDialog({
    required this.initialName,
    required this.maxLength,
  });

  @override
  State<_RenameRouteDialog> createState() => _RenameRouteDialogState();
}

class _RenameRouteDialogState extends State<_RenameRouteDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialName,
  )..selection = TextSelection(
      // Selects the existing name, so typing replaces it rather than
      // appending — a rename usually means replacing.
      baseOffset: 0,
      extentOffset: widget.initialName.length,
    );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final value = _controller.text.trim();
    if (value.isEmpty) return;
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: Text('Rename route', style: theme.textTheme.titleMedium),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLength: widget.maxLength,
        textInputAction: TextInputAction.done,
        style: theme.textTheme.bodyMedium,
        decoration: const InputDecoration(
          labelText: 'Name',
          border: OutlineInputBorder(),
        ),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        // A TextEditingController is a ValueNotifier, so Save can disable
        // itself on an empty field with no listener plumbing of its own —
        // and nothing to dispose beyond the controller above.
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: _controller,
          builder: (context, value, _) => TextButton(
            onPressed: value.text.trim().isEmpty ? null : _submit,
            child: const Text('Save'),
          ),
        ),
      ],
    );
  }
}
