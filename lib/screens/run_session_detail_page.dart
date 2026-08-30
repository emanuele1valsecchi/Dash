import 'dart:math' as math;

import 'package:dash/extensions/dash_snackbar.dart';
import 'package:dash/extensions/responsive_spacing.dart';
import 'package:dash/services/favorite_route_repository.dart';
import 'package:dash/services/profile_service.dart';
import 'package:dash/services/run_session_repository.dart';
import 'package:dash/widgets/dash_navigation_top_bar.dart';
import 'package:dash/widgets/dash_stat_tile.dart';
import 'package:dash/widgets/map/route_preview_map.dart';
import 'package:dash/widgets/units_scope.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

String _formatDate(DateTime date) =>
    '${_months[date.month - 1]} ${date.day}, ${date.year}';

String _formatDuration(Duration d) {
  final totalSeconds = d.inSeconds;
  final h = totalSeconds ~/ 3600;
  final m = (totalSeconds % 3600) ~/ 60;
  final s = totalSeconds % 60;
  if (h > 0) return '${h}h ${m}m';
  if (m > 0) return '${m}m ${s}s';
  return '${s}s';
}

/// Full-page detail view for a single run — reached by tapping a row in
/// `AreaDetailsSheet`'s "Built from N runs" contribution list on the Explore
/// map, or a card in a profile's "Runs" row.
///
/// Deliberately the **same layout as [SavedRouteDetailPage]**: title bar, one
/// line of context, a large interactive map of the whole path
/// ([RoutePreviewMap]), a grid of [DashStatTile]s, and one primary action at
/// the bottom. The only real difference is that a run has more numbers to show
/// and its action turns the run into a route rather than starting one.
///
/// Shows the *whole* running session, not just the loop that happened to claim
/// the area it was reached from — a run can close a small loop partway through
/// a much longer route, so the loop alone would misrepresent the session (e.g.
/// a 10 km run showing up as a tiny few-hundred-metre shape). Fetches the full
/// `runningSessions` doc itself, by id, rather than relying on anything
/// denormalized onto the `AreaContribution` that led here — firestore.rules
/// allows any signed-in user to read any session (a deliberate exposure:
/// reading another user's already-completed run to copy into a route of your
/// own isn't the same trust boundary as writing one). Distinct from
/// `session_detail_page.dart` (reached from the calendar, always the signed-in
/// user's own session, no runner header or favourite button needed there).
class RunSessionDetailPage extends StatefulWidget {
  final String sessionId;
  final String userId;

  const RunSessionDetailPage({
    super.key,
    required this.sessionId,
    required this.userId,
  });

  @override
  State<RunSessionDetailPage> createState() => _RunSessionDetailPageState();
}

class _RunSessionDetailPageState extends State<RunSessionDetailPage> {
  RunSession? _session;
  String? _username;

  /// Heart rate, read from the session's owner-only `private` subcollection —
  /// never from the session document, which every signed-in user can read.
  /// Only fetched for your own run; for anyone else's the rule would deny it
  /// anyway, which is the point.
  RunPrivateMetrics? _privateMetrics;

  /// Held as state rather than driven by a `FutureBuilder` so the app bar's
  /// title — the run's own name — can come from it. A builder around the body
  /// alone can't reach the `Scaffold.appBar` above it.
  bool _loadingSession = true;

  /// Whether the signed-in user has already turned this run into a route.
  ///
  /// A favourite's route ID *is* the session ID (see
  /// `FavoriteRouteRepository`), so this is a single direct document read
  /// rather than a scan of the user's whole route list for a matching
  /// `sourceSessionId` — which is both cheaper and immune to that list's
  /// cache being stale.
  bool _isFavorited = false;
  bool _loadingFavoriteState = true;
  bool _togglingFavorite = false;

  /// Whether the viewer is the person who ran this. Gates the body metrics
  /// (energy, heart rate) — see [_buildStats].
  bool get _isOwnRun =>
      FirebaseAuth.instance.currentUser?.uid == widget.userId;

  @override
  void initState() {
    super.initState();
    _loadSession();
    _loadUsername();
    _loadFavoriteState();
    _loadPrivateMetrics();
  }

  Future<void> _loadSession() async {
    RunSession? session;
    try {
      session =
          await RunSessionRepository.instance.fetchSessionById(widget.sessionId);
    } catch (e) {
      debugPrint('Could not load session ${widget.sessionId}: $e');
    }
    if (!mounted) return;
    setState(() {
      _session = session;
      _loadingSession = false;
    });
  }

  /// Only ever asked for on your own run. The rule would deny anyone else, so
  /// not asking keeps a guaranteed-denied read off the wire rather than
  /// relying on it failing.
  Future<void> _loadPrivateMetrics() async {
    if (!_isOwnRun) return;
    final metrics =
        await RunSessionRepository.instance.fetchPrivateMetrics(widget.sessionId);
    if (mounted) setState(() => _privateMetrics = metrics);
  }

  Future<void> _loadUsername() async {
    String? username;
    try {
      username = await ProfileService().fetchUsername(widget.userId);
    } catch (e) {
      debugPrint('Could not resolve username ${widget.userId}: $e');
    }
    if (mounted) setState(() => _username = username);
  }

  Future<void> _loadFavoriteState() async {
    // Never let a failure here leave the button spinning forever: this runs
    // on page load, and an unhandled throw would skip the setState that
    // clears [_loadingFavoriteState], which the button reads as "still
    // loading" with nothing left to finish it. Falling back to "not
    // favourited" leaves the button usable — an attempt reports its own
    // errors, and re-favouriting an already-favourited run is harmless (the
    // Cloud Function writes the same link ID either way).
    var favorited = false;
    try {
      favorited =
          await FavoriteRouteRepository.instance.isFavorited(widget.sessionId);
    } catch (e) {
      debugPrint('Could not resolve favourite state: $e');
    }
    if (!mounted) return;
    setState(() {
      _isFavorited = favorited;
      _loadingFavoriteState = false;
    });
  }

  Future<void> _toggleFavorite(RunSession session) async {
    if (_togglingFavorite || session.path.length < 2) return;
    setState(() => _togglingFavorite = true);
    try {
      if (_isFavorited) {
        await FavoriteRouteRepository.instance.unfavoriteRoute(session.id);
        if (!mounted) return;
        setState(() => _isFavorited = false);
      } else {
        // Only the ID is sent: the server copies the geometry out of the
        // session itself rather than trusting anything from this client.
        await FavoriteRouteRepository.instance.favoriteSession(
          session.id,
          routeName: _username != null ? "$_username's run" : 'Favourited run',
        );
        if (!mounted) return;
        setState(() => _isFavorited = true);
      }
    } catch (e) {
      if (mounted) context.showErrorSnackBar("Something went wrong");
    } finally {
      if (mounted) setState(() => _togglingFavorite = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: DashNavigationTopBar(title: session?.name ?? 'Run'),
      body: SafeArea(
        top: false,
        child: _loadingSession
            ? const Center(child: CircularProgressIndicator())
            : session == null
                ? _buildMissing(context)
                : _buildContent(context, session),
      ),
    );
  }

  Widget _buildMissing(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodyLarge!.copyWith(
      color: theme.colorScheme.outlineVariant,
    );

    return Center(
      child: Padding(
        padding: context.paddingLg,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          spacing: ResponsiveSpacing().sm,
          children: [
            Icon(
              Symbols.running_with_errors_rounded,
              fill: 1,
              size: theme.textTheme.displaySmall!.fontSize,
              color: theme.colorScheme.outlineVariant,
            ),
            Text(
              'This run is no longer available.',
              textAlign: TextAlign.center,
              style: style,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContent(BuildContext context, RunSession session) {
    final spacing = ResponsiveSpacing();

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: spacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: spacing.md,
        children: [
          _buildRunnerLine(context, session),
          Expanded(
            child: RoutePreviewMap(
              path: session.path,
              // A run's path is a recorded trail, not a declared loop, so the
              // finish pin is decided purely by how far apart the endpoints
              // actually are.
              isLoop: false,
            ),
          ),
          _buildStats(context, session),
          _buildAction(context, session),
          SizedBox(height: spacing.sm),
        ],
      ),
    );
  }

  Widget _buildRunnerLine(BuildContext context, RunSession session) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodyMedium!.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    final runner = _username ?? 'Unknown runner';
    final loops = session.loopsCompleted;
    final loopText =
        loops > 0 ? '  ·  $loops loop${loops == 1 ? '' : 's'}' : '';

    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: ResponsiveSpacing().sm,
      children: [
        Icon(
          Symbols.directions_run_rounded,
          size: style.fontSize,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        Flexible(
          child: Text(
            '$runner  ·  ${_formatDate(session.createdAt)}$loopText',
            style: style,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  /// More than the route page's single row: a completed run has measurements
  /// a planned route simply doesn't (what was actually burned, climbed, and
  /// claimed), and some of them are only shown to the person who ran it.
  ///
  /// **Body metrics are owner-only.** Energy and heart rate describe the
  /// runner rather than the route, so a visitor sees distance, time, pace,
  /// elevation and area — the shape of the run — and not what it cost the
  /// person who ran it. Heart rate additionally only appears when a watch
  /// actually reported it (see [RunSession.avgHeartRateBpm]).
  ///
  /// Note this is a **display** rule, not an enforced one: `runningSessions`
  /// docs are readable in full by any signed-in user, so hiding a tile does
  /// not stop someone reading the field directly. Making it genuinely private
  /// needs the fields moved somewhere with its own rule — see CLAUDE.md.
  Widget _buildStats(BuildContext context, RunSession session) {
    final units = Units.of(context);
    final pace = session.avgPaceMinPerKm;
    final avgSpeedKmh = pace > 0 ? 60 / pace : null;

    // Prefer the private subcollection; fall back to the session's own legacy
    // fields for runs written before heart rate moved there. **The fallback,
    // and `RunSession.legacyAvgHeartRateBpm`/`legacyMaxHeartRateBpm` with it,
    // should be deleted once `functions/_migrate_private_metrics.js` has run
    // against production** — until then those old runs are still exposing
    // heart rate on a world-readable document, which is exactly what the
    // migration fixes.
    final avgHeartRate =
        _privateMetrics?.avgHeartRateBpm ?? session.legacyAvgHeartRateBpm;
    final maxHeartRate =
        _privateMetrics?.maxHeartRateBpm ?? session.legacyMaxHeartRateBpm;

    final tiles = <Widget>[
      DashStatTile(
        icon: Symbols.straighten_rounded,
        label: 'Distance',
        value: units.distance(session.distanceMeters),
      ),
      DashStatTile(
        icon: Symbols.timer_rounded,
        label: 'Time',
        value: _formatDuration(session.duration),
      ),
      DashStatTile(
        icon: Symbols.speed_rounded,
        label: 'Avg ${units.rateLabel.toLowerCase()}',
        value: avgSpeedKmh != null
            ? units.rateValueFromSpeedKmh(avgSpeedKmh)
            : '—',
      ),
      DashStatTile(
        icon: Symbols.altitude_rounded,
        label: 'Elevation',
        value: units.elevation(session.elevationDifferenceMeters),
      ),
      DashStatTile(
        icon: Symbols.square_foot_rounded,
        label: 'Area',
        value: units.area(session.totalAreaM2),
      ),
      if (_isOwnRun) ...[
        DashStatTile(
          icon: Symbols.local_fire_department_rounded,
          label: 'Energy',
          value: units.energy(session.caloriesBurned),
        ),
        if (avgHeartRate != null)
          DashStatTile(
            icon: Symbols.ecg_heart_rounded,
            label: 'Avg HR',
            value: '$avgHeartRate bpm',
          ),
        if (maxHeartRate != null)
          DashStatTile(
            icon: Symbols.cardiology_rounded,
            label: 'Max HR',
            value: '$maxHeartRate bpm',
          ),
      ],
    ];

    return _buildTileGrid(context, tiles);
  }

  /// Lays [tiles] out three to a row, padding the last row with empty
  /// [Expanded]s so a partial row's tiles keep the same width as a full one's
  /// instead of stretching to fill it.
  Widget _buildTileGrid(BuildContext context, List<Widget> tiles) {
    const perRow = 3;
    final spacing = ResponsiveSpacing();
    final rows = <Widget>[];

    for (var i = 0; i < tiles.length; i += perRow) {
      final slice = tiles.sublist(i, math.min(i + perRow, tiles.length));
      rows.add(
        Row(
          spacing: spacing.sm,
          children: [
            for (final tile in slice) Expanded(child: tile),
            for (var pad = slice.length; pad < perRow; pad++)
              const Expanded(child: SizedBox.shrink()),
          ],
        ),
      );
    }

    return Column(spacing: spacing.sm, children: rows);
  }

  /// The one action, in the same slot the route page puts Run in.
  ///
  /// "Turn into a Route" rather than "Add to favourites": favouriting a run
  /// *is* copying its path into a route the viewer can go and run, and the old
  /// wording described the bookkeeping rather than the outcome.
  Widget _buildAction(BuildContext context, RunSession session) {
    final theme = Theme.of(context);
    final textStyle = theme.textTheme.bodyMedium!;
    final canFavorite = session.path.length >= 2;
    final busy = _togglingFavorite || _loadingFavoriteState;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: ResponsiveSpacing().sm,
      children: [
        FilledButton.icon(
          style: FilledButton.styleFrom(
            backgroundColor: _isFavorited
                ? theme.colorScheme.secondaryContainer
                : theme.colorScheme.primary,
            foregroundColor: _isFavorited
                ? theme.colorScheme.onSecondaryContainer
                : theme.colorScheme.onPrimary,
            textStyle: textStyle,
            padding: context.paddingMd,
          ),
          onPressed:
              (canFavorite && !busy) ? () => _toggleFavorite(session) : null,
          icon: busy
              ? SizedBox(
                  width: textStyle.fontSize,
                  height: textStyle.fontSize,
                  child: const CircularProgressIndicator(strokeWidth: 2),
                )
              // The same route glyph in both states, filled once the route
              // exists — the button is about one thing, and swapping in an
              // "unsave" bookmark for the second state made it look like a
              // different, unrelated action.
              : Icon(
                  Symbols.route_rounded,
                  fill: _isFavorited ? 1 : 0,
                  size: textStyle.fontSize,
                ),
          label: Text(_isFavorited ? 'Remove from Routes' : 'Turn into a Route'),
        ),
        if (!canFavorite)
          Text(
            "This run has no recorded path, so it can't become a route.",
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall!.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
      ],
    );
  }
}
