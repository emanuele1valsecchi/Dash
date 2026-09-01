import 'package:dash/extensions/dash_snackbar.dart';
import 'package:dash/extensions/responsive_spacing.dart';
import 'package:dash/screens/run_session_detail_page.dart';
import 'package:dash/screens/run_tracking_page.dart';
import 'package:dash/screens/saved_route_detail_page.dart';
import 'package:dash/services/route_repository.dart';
import 'package:dash/services/run_session_repository.dart';
import 'package:dash/widgets/dash_route_card.dart';
import 'package:dash/widgets/dash_run_card.dart';
import 'package:dash/widgets/dash_section_container.dart';
import 'package:dash/widgets/profile/route_source.dart';
import 'package:dash/widgets/rename_route_dialog.dart';
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:material_symbols_icons/symbols.dart';

/// A profile's **Runs** and **Routes** rows, shared verbatim by the signed-in
/// user's own profile and by another user's public one — the only difference
/// between the two is the [userId] whose data is loaded, and the wording of
/// the empty states ([displayName]).
///
/// Both rows scroll horizontally rather than stacking vertically, so a
/// profile stays one screen tall however much the person has run.
///
/// Runs open [RunSessionDetailPage] (the same page the Explore map's area
/// contributions lead to); routes open [SavedRouteDetailPage] (the same page
/// the route library leads to). Neither is a new screen.
///
/// **Reads are one-time, not listeners**, unlike the `snapshots()` streams
/// this replaced — a profile's run and route lists change rarely, and a
/// standing stream per profile visit costs reads for nothing.
class ProfileActivitySections extends StatefulWidget {
  final String userId;

  /// Whether [userId] is the signed-in user, which decides whose voice the
  /// empty states speak in ("You haven't…" vs "Name hasn't…").
  final bool isCurrentUser;

  /// Used in the empty states of another user's profile.
  final String displayName;

  const ProfileActivitySections({
    super.key,
    required this.userId,
    required this.isCurrentUser,
    required this.displayName,
  });

  @override
  State<ProfileActivitySections> createState() =>
      ProfileActivitySectionsState();
}

class ProfileActivitySectionsState extends State<ProfileActivitySections> {
  /// Fraction of the screen each row occupies. The cards fill this height
  /// rather than setting their own, since inside a horizontal list the cross
  /// axis is already tightly constrained.
  static const double _rowHeightFactor = 0.24;

  /// Cards are deliberately narrower than the screen so the next one peeks in
  /// from the right — the only cue that the row scrolls at all.
  static const double _cardWidthFactor = 0.78;

  bool _loading = true;

  /// Failure is tracked **per row, not per widget**. The two come from
  /// different collections with different rules, so one of them being
  /// unreadable (most likely `routes`, if the widened read rule has not been
  /// deployed yet) must not blank out the other — the previous shared flag,
  /// combined with a fail-fast `Future.wait`, meant a single permission error
  /// reported "Could not load" under *both* headings even though the runs had
  /// come back fine.
  bool _runsFailed = false;
  bool _routesFailed = false;

  List<RunSession> _runs = const [];
  List<SavedRoute> _routes = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(ProfileActivitySections oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.userId != widget.userId) _load();
  }

  Future<void> _load() async {
    // Run in parallel but settle independently: `Future.wait` fails fast, so
    // one rejected read would discard the other's result even after it had
    // already succeeded.
    final runs = _loadRuns();
    final routes = _loadRoutes();
    await Future.wait([runs, routes]);
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _loadRuns() async {
    try {
      final runs = await RunSessionRepository.instance
          .fetchUserSessions(userId: widget.userId);
      if (!mounted) return;
      setState(() {
        _runs = runs;
        _runsFailed = false;
      });
    } catch (e) {
      debugPrint('Could not load runs for ${widget.userId}: $e');
      if (mounted) setState(() => _runsFailed = true);
    }
  }

  Future<void> _loadRoutes() async {
    try {
      // The signed-in user's own routes go through the cached path and include
      // their private ones; anyone else's are a plain read restricted to what
      // they have published — which is not just a filter, it is what makes the
      // query permissible at all (see `fetchRoutesForUser`).
      final routes = widget.isCurrentUser
          ? await RouteRepository.instance.fetchUserRoutes()
          : await RouteRepository.instance
              .fetchRoutesForUser(widget.userId, publicOnly: true);
      if (!mounted) return;
      setState(() {
        _routes = routes;
        _routesFailed = false;
      });
    } catch (e) {
      debugPrint('Could not load routes for ${widget.userId}: $e');
      if (mounted) setState(() => _routesFailed = true);
    }
  }

  /// Re-reads both rows. Free when nothing invalidated the route cache.
  Future<void> reload() => _load();

  // ── Navigation ────────────────────────────────────────────────────────────

  void _openRun(RunSession session) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => RunSessionDetailPage(
          sessionId: session.id,
          userId: widget.userId,
        ),
      ),
    );
  }

  Future<void> _openRoute(SavedRoute route) async {
    final polyline = await Navigator.of(context).push<List<LatLng>>(
      MaterialPageRoute(
        builder: (_) => SavedRouteDetailPage(
          route: route,
          source: RouteSource.owned,
        ),
      ),
    );
    if (!mounted) return;

    // The detail page's Run button pops the polyline. Start the run right
    // here rather than routing it back through the home screen: unlike the
    // route library, a profile is a destination in the bottom-nav shell, not
    // a flow the user is passing through on their way to running something.
    // Someone else's route is as runnable as your own — that is much of the
    // point of showing it.
    if (polyline != null) {
      await pushRunTracking(context, plannedRoute: polyline);
      return;
    }

    // Otherwise the detail page may have renamed it (only possible on your
    // own route), which invalidates the cache — reloading is free when it
    // didn't.
    await reload();
  }

  /// Deletes a route from its card, after confirming.
  ///
  /// This is the only place in the app that deletes a route. It used to sit on
  /// the route library's cards too, but that list exists to pick something to
  /// *run* — a delete button on every card there is the wrong thing to have
  /// under your thumb. Your profile is where you manage what you own.
  Future<void> _deleteRoute(SavedRoute route) async {
    final theme = Theme.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Delete route?', style: theme.textTheme.titleMedium),
        content: Text(
          '"${route.name}" will be removed from your routes.',
          style: theme.textTheme.bodyMedium,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: theme.colorScheme.error,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      await RouteRepository.instance.deleteRoute(route.id);
      if (!mounted) return;
      setState(() => _routes = _routes.where((r) => r.id != route.id).toList());
    } catch (e) {
      debugPrint('Could not delete route ${route.id}: $e');
      if (mounted) context.showErrorSnackBar('Could not delete that route');
    }
  }

  /// Renames a route straight from its card, without opening it — offered
  /// only on your own profile, since `firestore.rules` lets only the owner
  /// update a route.
  Future<void> _renameRoute(SavedRoute route) async {
    final newName =
        await showRenameRouteDialog(context, initialName: route.name);
    if (newName == null || newName == route.name || !mounted) return;

    try {
      await RouteRepository.instance.renameRoute(route.id, newName);
      if (mounted) await reload();
    } catch (e) {
      debugPrint('Could not rename route ${route.id}: $e');
      if (mounted) context.showErrorSnackBar('Could not rename that route');
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: ResponsiveSpacing().md,
      children: [
        DashSectionContainer(
          title: 'Runs',
          leadingIcon: Symbols.directions_run_rounded,
          hasForwardIcon: false,
          child: _buildRow(
            context,
            failed: _runsFailed,
            isEmpty: _runs.isEmpty,
            emptyIcon: Symbols.directions_run_rounded,
            emptyTitle: 'No runs yet',
            emptyMessage: widget.isCurrentUser
                ? 'Complete a run to see it here.'
                : "${widget.displayName} hasn't completed a run yet.",
            itemCount: _runs.length,
            itemBuilder: (context, i) => DashRunCard(
              widthFactor: _cardWidthFactor,
              session: _runs[i],
              onTap: () => _openRun(_runs[i]),
            ),
          ),
        ),
        DashSectionContainer(
          title: 'Routes',
          leadingIcon: Symbols.route_rounded,
          hasForwardIcon: false,
          child: _buildRow(
            context,
            failed: _routesFailed,
            isEmpty: _routes.isEmpty,
            emptyIcon: Symbols.route_rounded,
            emptyTitle: 'No routes yet',
            emptyMessage: widget.isCurrentUser
                ? 'Create or save a route to see it here.'
                : "${widget.displayName} hasn't saved a route yet.",
            itemCount: _routes.length,
            itemBuilder: (context, i) => DashRouteCard(
              heightFactor: null,
              widthFactor: _cardWidthFactor,
              entry: RouteEntry(_routes[i], RouteSource.owned),
              onTap: () => _openRoute(_routes[i]),
              // Rename in place, without opening the route — but only on your
              // own profile, since only the owner may update a route.
              onTitleTap: widget.isCurrentUser
                  ? () => _renameRoute(_routes[i])
                  : null,
              // Your own list is the only one that contains private routes,
              // so it is the only one where the padlock says anything.
              showPrivateBadge: widget.isCurrentUser,
              // Deleting a route lives here rather than in the route library —
              // see [_deleteRoute]. Only on your own profile: the rules let
              // only an owner delete.
              actionIcon: Symbols.delete_rounded,
              onActionTap: widget.isCurrentUser
                  ? () => _deleteRoute(_routes[i])
                  : null,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildRow(
    BuildContext context, {
    required bool failed,
    required bool isEmpty,
    required IconData emptyIcon,
    required String emptyTitle,
    required String emptyMessage,
    required int itemCount,
    required IndexedWidgetBuilder itemBuilder,
  }) {
    if (_loading) {
      return SizedBox(
        height: MediaQuery.heightOf(context) * _rowHeightFactor,
        child: const Center(child: CircularProgressIndicator()),
      );
    }

    if (failed) {
      return _buildEmptyState(
        context,
        icon: Symbols.error_rounded,
        title: 'Could not load',
        message: 'Pull down to try again.',
      );
    }

    if (isEmpty) {
      return _buildEmptyState(
        context,
        icon: emptyIcon,
        title: emptyTitle,
        message: emptyMessage,
      );
    }

    return SizedBox(
      height: MediaQuery.heightOf(context) * _rowHeightFactor,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        // The section already sits inside the page's horizontal padding, so
        // the list itself needs none — the separator handles the gaps.
        itemCount: itemCount,
        separatorBuilder: (_, _) => SizedBox(width: ResponsiveSpacing().md),
        itemBuilder: itemBuilder,
      ),
    );
  }

  Widget _buildEmptyState(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String message,
  }) {
    final theme = Theme.of(context);
    final bodyStyle = theme.textTheme.bodyLarge!.copyWith(
      color: theme.colorScheme.outlineVariant,
    );

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        spacing: ResponsiveSpacing().sm,
        children: [
          Icon(
            icon,
            fill: 1,
            size: theme.textTheme.displaySmall!.fontSize,
            color: theme.colorScheme.outlineVariant,
          ),
          Text(title, style: bodyStyle.copyWith(fontWeight: FontWeight.bold)),
          SizedBox(
            width: MediaQuery.widthOf(context) * 2 / 3,
            child: Text(
              message,
              textAlign: TextAlign.center,
              style: bodyStyle,
            ),
          ),
        ],
      ),
    );
  }
}
