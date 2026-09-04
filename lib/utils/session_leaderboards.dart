/// Which leaderboards a completed run's XP counts toward, and which place name
/// to show for it.
///
/// **A run counts toward two boards, not one.** Both of these, deduplicated:
///
///  * its **locality** — `startLocality`, the raw reverse-geocoded place the
///    run actually started in ("Seregno"). Every real run has one, so this is
///    the board nobody can be missing from;
///  * its **territory** — the curated metropolitan area covering the start
///    point ("Milano"), or the broad region when no polygon does. Present only
///    when the server resolved one.
///
/// Filing a run under *only* its metro area was the earlier behaviour, and it
/// was wrong in the direction people actually notice: a run in Seregno
/// disappeared into a Milano board, so the place you ran had no scoreboard of
/// its own. Filing it under only the locality is the other failure — it
/// fragments every metro area into one board per village, which is exactly
/// what the curated coverage polygons exist to prevent. Counting it toward
/// both costs nothing and makes each board mean what its name says.
///
/// This lives in one place deliberately. The territory-vs-locality choice was
/// previously copy-pasted into four screens and the Cloud Function, and got
/// out of step in four of them (see CLAUDE.md's territory bullet) — a bug that
/// silently emptied city leaderboards. One function, called everywhere, is the
/// fix for the *class* of bug rather than each instance.
library;

/// Every board [session] contributes to, most specific first, deduplicated.
///
/// The order is for presentation only; accumulation is order-independent.
/// Returns empty when nothing could be resolved at all, which callers should
/// treat as "counts toward the global board only".
List<String> leaderboardsForSession({
  String? startLocality,
  String? territoryCity,
  String? territoryBroad,
}) {
  final locality = _clean(startLocality);
  final territory = _clean(territoryCity) ?? _clean(territoryBroad);

  final boards = <String>[];
  if (locality != null) boards.add(locality);
  // A locality inside no curated polygon resolves to its broad region, which
  // can legitimately equal neither; a village named the same as its metro area
  // (Milano in Milano) must still produce a single board.
  if (territory != null && territory != locality) boards.add(territory);
  return boards;
}

/// The place name to *display* for a session — the locality it started in.
///
/// Deliberately not the territory: "Vertemate con Minoprio" is where the run
/// happened, and showing "Northern Lombardy" instead reads as though the app
/// lost track of where you were. The territory still gets the XP (see
/// [leaderboardsForSession]); it just isn't the label.
///
/// Falls back to the territory, then null, for sessions written before
/// `startLocality` existed or whose reverse-geocode failed.
String? displayLocalityForSession({
  String? startLocality,
  String? territoryCity,
  String? territoryBroad,
}) {
  return _clean(startLocality) ??
      _clean(territoryCity) ??
      _clean(territoryBroad);
}

String? _clean(String? value) {
  final trimmed = value?.trim();
  return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
}
