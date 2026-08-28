/// The default order leaderboards appear in on the home screen, shared by the
/// home screen itself and by the "Customize Home" settings page.
///
/// It lives here rather than in either screen because the two must agree: the
/// settings page seeds its reorderable list from this, and the home screen
/// falls back to it for a user who has never opened that page. If they
/// disagreed, opening settings once would silently rearrange the home screen.
class LeaderboardOrder {
  LeaderboardOrder._();

  /// The global board's title, which doubles as its identity in the saved
  /// config — both screens match on this exact string, so it must not be
  /// spelled out separately in either of them.
  static const String globalTitle = 'Global Leaderboard';

  /// [globalTitle] first, then the runner's metropolitan area, then every
  /// other territory in the order given (the callers pass them most recently
  /// scored-in first).
  ///
  /// The metro area earns second place because it is the board a runner
  /// actually competes on day to day — the curated coverage polygons exist
  /// precisely so that everyone around Milano shares one board instead of
  /// splitting into a board per village. Territories from the broad region
  /// fallback are ordinary entries and get no such promotion.
  ///
  /// [metroTerritory] may be null (nobody has run inside a curated polygon
  /// yet) and may also already appear in [territories]; it is emitted once
  /// either way. Order is stable and duplicates are dropped, so a caller can
  /// pass its raw list without pre-filtering.
  static List<String> defaultOrder(
    Iterable<String> territories, {
    String? metroTerritory,
  }) {
    final ordered = <String>[globalTitle];

    if (metroTerritory != null &&
        metroTerritory.isNotEmpty &&
        metroTerritory != globalTitle) {
      ordered.add(metroTerritory);
    }

    for (final territory in territories) {
      if (territory.isEmpty || ordered.contains(territory)) continue;
      ordered.add(territory);
    }

    return ordered;
  }
}
