import 'package:dash/extensions/responsive_border_radius.dart';
import 'package:dash/extensions/responsive_spacing.dart';
import 'package:dash/screens/route_search_page.dart';
import 'package:dash/widgets/routes/saved_routes_section.dart';
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:material_symbols_icons/symbols.dart';

/// Tells a descendant which of the route library's two sections is currently
/// on screen.
///
/// [RouteSearchPage] is the library's second section as well as being usable
/// on its own, and the two contexts differ in exactly two ways: embedded, it
/// must not draw its own back arrow (the library header already has one), and
/// its `PopScope` must stand down while it is not the visible section — a
/// route's pop is refused if *any* registered `PopScope` refuses it, so an
/// off-screen search form sitting on step 2 would otherwise swallow the back
/// gesture on the "My Routes" section.
///
/// **It has to be an inherited widget rather than a constructor flag.** The
/// sections are kept alive across swipes (see [_KeepAlivePage]), and a
/// kept-alive but off-screen child does not receive rebuilt widget
/// configurations from its parent — so a plain `active: _index == 1` field
/// would go stale at exactly the moment it matters. Inherited-widget
/// dependency marks the dependent *element* dirty directly, wherever it sits,
/// which is the same reason `UnitsScope` is one.
///
/// [maybeOf] returning null is the "not embedded" case, and every reader must
/// treat it as full standalone behaviour.
class RouteLibraryScope extends InheritedWidget {
  /// Index of the section currently on screen — see
  /// [RouteLibraryPage.savedRoutesSection] / [RouteLibraryPage.searchSection].
  final int activeSection;

  const RouteLibraryScope({
    super.key,
    required this.activeSection,
    required super.child,
  });

  static RouteLibraryScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<RouteLibraryScope>();

  /// Whether the caller is inside the library at all, rather than being
  /// shown as a standalone page.
  static bool isEmbedded(BuildContext context) => maybeOf(context) != null;

  /// Whether [section] is the one the user is currently looking at. True when
  /// there is no scope at all, so a standalone page behaves exactly as it did
  /// before it could be embedded.
  static bool isSectionVisible(BuildContext context, int section) {
    final scope = maybeOf(context);
    return scope == null || scope.activeSection == section;
  }

  @override
  bool updateShouldNotify(RouteLibraryScope oldWidget) =>
      oldWidget.activeSection != activeSection;
}

/// The entry point behind the home screen's "Search for a route" action.
///
/// Two swipeable sections:
///  1. **My Routes** — every route the user built, plus the ones they
///     favourited from other people's runs. Tapping a card opens it, with a
///     Run button.
///  2. **Find a Route** — the existing parametrized [RouteSearchPage],
///     unchanged.
///
/// Pops with a `List<LatLng>` when the user chooses to run something, from
/// either section — the same contract `RouteSearchPage` already had on its
/// own, so `HomeScreen._searchRoute` needed no change beyond which page it
/// pushes.
///
/// **The tab header is not decoration.** Section 2 is a full-screen map, and
/// flutter_map claims horizontal drags for panning, so a swipe cannot get
/// back out of it — only from its bottom sheet. Tapping a tab always works.
class RouteLibraryPage extends StatefulWidget {
  static const int savedRoutesSection = 0;
  static const int searchSection = 1;

  const RouteLibraryPage({super.key});

  @override
  State<RouteLibraryPage> createState() => _RouteLibraryPageState();
}

class _RouteLibraryPageState extends State<RouteLibraryPage> {
  final PageController _pageController = PageController();

  /// Lets the page nudge the saved-routes list to re-read when the user
  /// swipes back to it — see [_onPageChanged].
  final GlobalKey<SavedRoutesSectionState> _savedRoutesKey =
      GlobalKey<SavedRoutesSectionState>();

  int _activeSection = RouteLibraryPage.savedRoutesSection;

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _onPageChanged(int section) {
    setState(() => _activeSection = section);

    // The saved-routes list is kept alive off screen, so a route saved from
    // the search section would otherwise not appear until the next
    // pull-to-refresh. Reloading costs nothing when nothing invalidated the
    // repository caches — see `SavedRoutesSectionState.reload`.
    if (section == RouteLibraryPage.savedRoutesSection) {
      _savedRoutesKey.currentState?.reload();
    }
  }

  void _goToSection(int section) {
    if (section == _activeSection) return;
    _pageController.animateToPage(
      section,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  /// Forwards a chosen route up to whoever pushed this page (the home
  /// screen), which starts run tracking with it.
  void _runRoute(List<LatLng> polyline) =>
      Navigator.of(context).pop<List<LatLng>>(polyline);

  @override
  Widget build(BuildContext context) {
    return RouteLibraryScope(
      activeSection: _activeSection,
      child: Scaffold(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        body: SafeArea(
          // The search section's bottom sheet runs to the very bottom edge,
          // exactly as it does standalone.
          bottom: false,
          child: Column(
            children: [
              _buildHeader(context),
              Expanded(
                child: PageView(
                  controller: _pageController,
                  onPageChanged: _onPageChanged,
                  children: [
                    _KeepAlivePage(
                      child: SavedRoutesSection(
                        key: _savedRoutesKey,
                        onRunRoute: _runRoute,
                      ),
                    ),
                    const _KeepAlivePage(child: RouteSearchPage()),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    final spacing = ResponsiveSpacing();

    return Padding(
      padding: EdgeInsets.fromLTRB(spacing.sm, spacing.sm, spacing.sm, 0),
      child: Row(
        spacing: spacing.sm,
        children: [
          IconButton(
            icon: const Icon(Symbols.arrow_back_rounded),
            color: Theme.of(context).colorScheme.primary,
            tooltip: 'Back',
            onPressed: () => Navigator.of(context).pop(),
          ),
          Expanded(
            child: _SectionTabs(
              activeSection: _activeSection,
              onSelected: _goToSection,
            ),
          ),
          // Balances the back arrow so the tabs sit centred on the screen
          // rather than pushed right by it — the same leading/trailing
          // symmetry an AppBar keeps for its own centred title. An IconButton
          // sizes itself to kMinInteractiveDimension, so this matches it
          // exactly without hardcoding a width.
          const SizedBox(width: kMinInteractiveDimension),
        ],
      ),
    );
  }
}

/// The two-segment switcher in the header.
class _SectionTabs extends StatelessWidget {
  final int activeSection;
  final ValueChanged<int> onSelected;

  const _SectionTabs({
    required this.activeSection,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: EdgeInsets.all(ResponsiveSpacing().sm / 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainer,
        borderRadius: context.radiusXl,
      ),
      child: Row(
        children: [
          Expanded(
            child: _Tab(
              label: 'My Routes',
              icon: Symbols.route_rounded,
              selected: activeSection == RouteLibraryPage.savedRoutesSection,
              onTap: () => onSelected(RouteLibraryPage.savedRoutesSection),
            ),
          ),
          Expanded(
            child: _Tab(
              label: 'Find a Route',
              icon: Symbols.search_rounded,
              selected: activeSection == RouteLibraryPage.searchSection,
              onTap: () => onSelected(RouteLibraryPage.searchSection),
            ),
          ),
        ],
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  const _Tab({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textStyle = theme.textTheme.bodyMedium!;

    final Color foreground = selected
        ? theme.colorScheme.secondary
        : theme.colorScheme.onSurfaceVariant;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        padding: EdgeInsets.symmetric(
          vertical: ResponsiveSpacing().sm,
          horizontal: ResponsiveSpacing().sm,
        ),
        decoration: BoxDecoration(
          color: selected
              ? theme.colorScheme.primaryContainer
              : Colors.transparent,
          borderRadius: context.radiusXl,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          spacing: ResponsiveSpacing().sm / 2,
          children: [
            Icon(icon, size: textStyle.fontSize, color: foreground),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textStyle.copyWith(
                  color: foreground,
                  fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Keeps a section's state (and, for the search section, its map, GPS
/// subscription and half-filled form) alive across swipes.
///
/// Without this a `PageView` disposes the off-screen section, so swiping away
/// from a search mid-way through and back again would silently reset it.
/// Note that a kept-alive child is still built lazily — the search section
/// costs nothing until it is first scrolled to.
class _KeepAlivePage extends StatefulWidget {
  final Widget child;

  const _KeepAlivePage({required this.child});

  @override
  State<_KeepAlivePage> createState() => _KeepAlivePageState();
}

class _KeepAlivePageState extends State<_KeepAlivePage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}
