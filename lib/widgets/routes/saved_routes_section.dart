import 'package:dash/extensions/dash_snackbar.dart';
import 'package:dash/extensions/responsive_border_radius.dart';
import 'package:dash/extensions/responsive_spacing.dart';
import 'package:dash/screens/saved_route_detail_page.dart';
import 'package:dash/services/favorite_route_repository.dart';
import 'package:dash/services/route_author_service.dart';
import 'package:dash/services/route_repository.dart';
import 'package:dash/widgets/dash_route_card.dart';
import 'package:dash/widgets/dash_section_container.dart';
import 'package:dash/widgets/profile/route_source.dart';
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:material_symbols_icons/symbols.dart';

/// The route library's first section: every route the user built, then every
/// route they favourited from someone else's run.
///
/// Both lists come from the same cache-and-invalidate repositories the rest
/// of the app uses ([RouteRepository] / [FavoriteRouteRepository]) rather
/// than live listeners — a route list changes rarely, and a standing
/// snapshot stream would cost reads on every open. Pull-to-refresh is what
/// forces a re-read.
///
/// Kept out of the page itself so the page stays a thin two-section shell.
/// Its [State] is public so the page can call [SavedRoutesSectionState.reload]
/// through a [GlobalKey] when the user swipes back to it — same convention as
/// `FormState`/`ScaffoldState`.
class SavedRoutesSection extends StatefulWidget {
  /// Called with a route's polyline when the user chooses **Run** on its
  /// detail page. The page above forwards it to whoever pushed the library.
  final ValueChanged<List<LatLng>> onRunRoute;

  const SavedRoutesSection({super.key, required this.onRunRoute});

  @override
  State<SavedRoutesSection> createState() => SavedRoutesSectionState();
}

class SavedRoutesSectionState extends State<SavedRoutesSection> {
  /// Slightly shorter than [DashRouteCard]'s own default, so more than one
  /// card is visible at a time in a scrolling list.
  static const double _cardHeightFactor = 0.24;

  bool _loading = true;
  bool _failed = false;

  List<SavedRoute> _owned = const [];
  List<SavedRoute> _favorites = const [];

  @override
  void initState() {
    super.initState();
    // Authors resolve in the background and repaint the cards when they
    // land — nothing here ever waits on them.
    RouteAuthorService.instance.addListener(_onAuthorsResolved);
    _load();
  }

  @override
  void dispose() {
    RouteAuthorService.instance.removeListener(_onAuthorsResolved);
    super.dispose();
  }

  void _onAuthorsResolved() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait([
        RouteRepository.instance.fetchUserRoutes(),
        FavoriteRouteRepository.instance.fetchFavorites(),
      ]);
      if (!mounted) return;
      setState(() {
        _owned = results[0];
        _favorites = results[1];
        _loading = false;
        _failed = false;
      });
      // Fire-and-forget: a card renders fine with no author line.
      RouteAuthorService.instance
          .ensureLoaded(_favorites.map((r) => r.sourceSessionId));
    } catch (e) {
      debugPrint('Could not load saved routes: $e');
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  /// Re-reads both lists without flashing a spinner over what is already on
  /// screen.
  ///
  /// Cheap to call speculatively: both repositories serve from an in-memory
  /// cache, so this costs Firestore reads only when something actually
  /// invalidated one — which is exactly the case worth catching (a route
  /// saved from the search section while this list sat kept-alive off
  /// screen).
  Future<void> reload() => _load();

  Future<void> _refresh() async {
    RouteRepository.instance.invalidateCache();
    FavoriteRouteRepository.instance.invalidateCache();
    await _load();
  }

  // ── Actions ───────────────────────────────────────────────────────────────

  Future<void> _openRoute(
    SavedRoute route,
    RouteSource source, {
    String? authorName,
  }) async {
    final polyline = await Navigator.of(context).push<List<LatLng>>(
      MaterialPageRoute(
        builder: (_) => SavedRouteDetailPage(
          route: route,
          source: source,
          authorName: authorName,
        ),
      ),
    );
    if (!mounted) return;

    if (polyline != null) {
      widget.onRunRoute(polyline);
      return;
    }

    // The detail page may have renamed the route, which invalidates the
    // repository cache. Reloading unconditionally is free when it didn't —
    // a warm cache costs no Firestore reads.
    await reload();
  }

  Future<void> _unfavoriteRoute(SavedRoute route) async {
    final confirmed = await _confirm(
      title: 'Remove from favourites?',
      message:
          '"${route.name}" will no longer appear here. The original run is '
          'not affected.',
      confirmLabel: 'Remove',
    );
    if (confirmed != true) return;

    try {
      await FavoriteRouteRepository.instance.unfavoriteRoute(route.id);
      if (!mounted) return;
      setState(
        () => _favorites = _favorites.where((r) => r.id != route.id).toList(),
      );
    } catch (e) {
      debugPrint('Could not un-favourite route ${route.id}: $e');
      if (mounted) context.showErrorSnackBar('Could not remove that favourite');
    }
  }

  Future<bool?> _confirm({
    required String title,
    required String message,
    required String confirmLabel,
  }) {
    final theme = Theme.of(context);

    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title, style: theme.textTheme.titleMedium),
        content: Text(message, style: theme.textTheme.bodyMedium),
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
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    final spacing = ResponsiveSpacing();

    return RefreshIndicator(
      onRefresh: _refresh,
      color: Theme.of(context).colorScheme.tertiary,
      child: ListView(
        padding: EdgeInsets.symmetric(horizontal: spacing.md),
        // Always scrollable so pull-to-refresh still works when both lists
        // are empty — which is exactly when a user is most likely to pull.
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          if (_failed) _buildFailureNotice(context),
          DashSectionContainer(
            title: 'My Routes',
            leadingIcon: Symbols.route_rounded,
            hasForwardIcon: false,
            child: _owned.isEmpty
                ? _buildEmptyState(
                    context,
                    icon: Symbols.route_rounded,
                    title: 'No routes yet',
                    message:
                        'Create a route or search for one to see it here.',
                  )
                : _buildList(
                    routes: _owned,
                    source: RouteSource.owned,
                  ),
          ),
          DashSectionContainer(
            title: 'Favourites',
            leadingIcon: Symbols.favorite_rounded,
            hasForwardIcon: false,
            child: _favorites.isEmpty
                ? _buildEmptyState(
                    context,
                    icon: Symbols.favorite_rounded,
                    title: 'No favourites yet',
                    message:
                        "Favourite someone else's run from the map to save it "
                        'as a route you can run.',
                  )
                : _buildList(
                    routes: _favorites,
                    source: RouteSource.favorite,
                  ),
          ),
          SizedBox(height: spacing.xl),
        ],
      ),
    );
  }

  Widget _buildList({
    required List<SavedRoute> routes,
    required RouteSource source,
  }) {
    final isFavorite = source == RouteSource.favorite;

    return ListView.separated(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: routes.length,
      separatorBuilder: (_, _) => SizedBox(height: ResponsiveSpacing().md),
      itemBuilder: (context, i) {
        final route = routes[i];
        final author = isFavorite
            ? RouteAuthorService.instance.authorNameFor(route.sourceSessionId)
            : null;

        return DashRouteCard(
          heightFactor: _cardHeightFactor,
          entry: RouteEntry(route, source),
          subtitle: author == null ? null : 'by $author',
          actionIcon: Symbols.favorite_rounded,
          actionIconFill: 1,
          // Both lists here are the signed-in user's own, so a padlock on a
          // private route is meaningful — this is where they would look to
          // check what they have published.
          showPrivateBadge: !isFavorite,
          onTap: () => _openRoute(route, source, authorName: author),
          // Only favourites carry an action here. **Deleting an owned route
          // lives on the profile's Routes row instead** — this page is where
          // you come to pick something to run, and a delete button sitting on
          // every card in a "choose a route" list is the wrong thing to have
          // under your thumb.
          onActionTap: isFavorite ? () => _unfavoriteRoute(route) : null,
        );
      },
    );
  }

  Widget _buildFailureNotice(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      margin: EdgeInsets.only(top: ResponsiveSpacing().md),
      padding: context.paddingMd,
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: context.radiusMd,
      ),
      child: Row(
        spacing: ResponsiveSpacing().sm,
        children: [
          Icon(
            Symbols.error_rounded,
            color: theme.colorScheme.onErrorContainer,
            size: theme.textTheme.bodyMedium!.fontSize,
          ),
          Expanded(
            child: Text(
              'Could not load your routes. Pull down to try again.',
              style: theme.textTheme.bodyMedium!.copyWith(
                color: theme.colorScheme.onErrorContainer,
              ),
            ),
          ),
        ],
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
          Text(
            title,
            style: bodyStyle.copyWith(fontWeight: FontWeight.bold),
          ),
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
