import 'package:dash/extensions/dash_snackbar.dart';
import 'package:dash/extensions/responsive_spacing.dart';
import 'package:dash/services/favorite_route_repository.dart';
import 'package:dash/services/route_repository.dart';
import 'package:dash/widgets/dash_navigation_top_bar.dart';
import 'package:dash/widgets/dash_stat_tile.dart';
import 'package:dash/widgets/map/route_preview_map.dart';
import 'package:dash/widgets/profile/route_source.dart';
import 'package:dash/widgets/rename_route_dialog.dart';
import 'package:dash/widgets/save_route_dialog.dart';
import 'package:dash/widgets/units_scope.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
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
  /// Held in state rather than read from the widget, so a rename shows
  /// immediately instead of waiting for the list behind to re-read.
  late String _name = widget.route.name;

  List<LatLng> get _polyline => widget.route.routePolyline;

  bool get _hasPath => _polyline.length >= 2;

  /// Whether this viewer has somewhere to write a new name.
  ///
  /// A favourite always qualifies: the name lives on the viewer's *own*
  /// `favoriteRoutes` link. An owned route qualifies only if the viewer is
  /// actually the owner — any signed-in user can read any route now (profile
  /// pages show other people's), but `firestore.rules` still lets only the
  /// owner update one, so offering the pencil to a visitor would be an
  /// affordance for a write guaranteed to be denied.
  bool get _canRename => switch (widget.source) {
        RouteSource.favorite => true,
        RouteSource.owned => _isOwner,
        RouteSource.created => false,
      };

  bool get _isOwner =>
      widget.route.userId != null &&
      widget.route.userId == FirebaseAuth.instance.currentUser?.uid;


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
              Expanded(
                child: RoutePreviewMap(
                  path: _polyline,
                  isLoop: widget.route.isLoop,
                ),
              ),
              _buildStats(context),
              // Read-only: visibility is chosen once, when the route is saved,
              // and `firestore.rules` pins it thereafter. Shown only to the
              // owner of an owned route — a visitor only ever sees public
              // routes, so the line would say nothing, and a favourite points
              // at a shared document whose readability is not this user's.
              if (_isOwner && widget.source == RouteSource.owned)
                RouteVisibilityInfo(
                  isPublic: widget.route.isPublic,
                  showLabel: false,
                ),
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
    final newName = await showRenameRouteDialog(context, initialName: _name);
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

  // ── Stats ─────────────────────────────────────────────────────────────────

  Widget _buildStats(BuildContext context) {
    final units = Units.of(context);
    final route = widget.route;
    final timeMin = route.estimatedTimeMin;

    return Row(
      spacing: ResponsiveSpacing().sm,
      children: [
        Expanded(
          child: DashStatTile(
            icon: Symbols.straighten_rounded,
            label: 'Distance',
            value: units.distance(route.distanceMeters),
          ),
        ),
        Expanded(
          child: DashStatTile(
            icon: Symbols.timer_rounded,
            label: 'Est. time',
            value: timeMin < 60
                ? '${timeMin.round()} min'
                : '${(timeMin / 60).floor()}h ${(timeMin % 60).round()}min',
          ),
        ),
        Expanded(
          child: route.isLoop
              ? DashStatTile(
                  icon: Symbols.loop_rounded,
                  label: 'Area',
                  value: units.area(route.loopAreaM2),
                )
              : DashStatTile(
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
