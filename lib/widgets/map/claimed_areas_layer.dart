import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

import '../../services/claimed_area_repository.dart';
import '../../services/user_appearance_service.dart';
import '../../utils/player_palette.dart';

/// Renders claimed-area polygons, **one colour per owner** rather than the
/// old two-tone "green = mine, red = everyone else".
///
/// The colour comes from the owner's own `profiles/{uid}.areaColorIndex` via
/// [PlayerPalette], so a given player looks the same to everybody — including
/// to themselves. That is deliberate and replaces the earlier viewer-relative
/// scheme: if you were green only in your own eyes, a friend saying "I took
/// your purple patch by the park" would refer to a colour you had never seen,
/// and screenshots would not survive being shared.
///
/// **Ownership is signalled off-hue instead.** Your own areas get a thicker,
/// more opaque, brighter-edged treatment ([myBorderStrokeWidth] /
/// [myFillAlpha]) while keeping your palette hue. Two reasons: "is this
/// mine?" is the highest-frequency read on the map and must never depend on
/// telling two similar hues apart; and the previous green-vs-red scheme hung
/// that same critical distinction on the single worst colour pair for the
/// ~8% of men with red/green colour vision deficiency.
///
/// Appearances are pulled from [UserAppearanceService] (cached, batched). The
/// layer renders immediately with whatever is cached and repaints when the
/// rest arrives — a player whose profile has not loaded, or has no stored
/// index, still gets a stable colour from `PlayerPalette`'s uid-hash
/// fallback, so nothing is ever grey or blank while waiting.
///
/// Pass [hitNotifier] (and the same instance to `MapOptions.onTap` via
/// `handleAreaTap`/`showAreaDetailsSheet` in area_details_sheet.dart) to make
/// polygons tappable; omit it on screens where tapping shouldn't open area
/// details (currently everywhere except the Explore/Area page).
class ClaimedAreasLayer extends StatefulWidget {
  final List<ClaimedArea> areas;
  final LayerHitNotifier<String>? hitNotifier;

  const ClaimedAreasLayer({super.key, required this.areas, this.hitNotifier});

  /// Fill/border opacity for other players' territory.
  static const double otherFillAlpha = 0.25;
  static const double otherBorderAlpha = 0.8;
  static const double otherBorderStrokeWidth = 2.0;

  /// Your own territory: same hue, heavier weight. This is the entire
  /// "is it mine?" signal now, so the gap has to be obvious at a glance on a
  /// phone screen in daylight — hence a near-double stroke rather than a
  /// subtle nudge.
  static const double myFillAlpha = 0.42;
  static const double myBorderAlpha = 1.0;
  static const double myBorderStrokeWidth = 3.5;

  @override
  State<ClaimedAreasLayer> createState() => _ClaimedAreasLayerState();
}

class _ClaimedAreasLayerState extends State<ClaimedAreasLayer> {
  final UserAppearanceService _appearances = UserAppearanceService.instance;

  @override
  void initState() {
    super.initState();
    _appearances.addListener(_onAppearancesChanged);
    _requestAppearances();
  }

  @override
  void didUpdateWidget(covariant ClaimedAreasLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Areas arrive incrementally (repository sync, live steals), so new owners
    // can appear without this widget being rebuilt from scratch.
    if (!identical(oldWidget.areas, widget.areas)) _requestAppearances();
  }

  @override
  void dispose() {
    _appearances.removeListener(_onAppearancesChanged);
    super.dispose();
  }

  void _onAppearancesChanged() {
    if (mounted) setState(() {});
  }

  /// Fire-and-forget: the service caches and de-duplicates, so calling this
  /// with an already-known set costs nothing and issues no query.
  void _requestAppearances() {
    _appearances.ensureLoaded(widget.areas.map((a) => a.userId));
  }

  @override
  Widget build(BuildContext context) {
    final myUid = FirebaseAuth.instance.currentUser?.uid;

    return PolygonLayer<String>(
      hitNotifier: widget.hitNotifier,
      // An area can be more than one disconnected piece (a steal that cuts
      // straight through leaves two remaining fragments) — each piece
      // becomes its own Polygon, but all share the same hitValue, so
      // tapping any fragment opens the same area's details.
      polygons: widget.areas.expand((area) {
        final isMine = area.userId == myUid;
        final color = PlayerPalette.colorFor(
          uid: area.userId,
          colorIndex: _appearances.get(area.userId)?.colorIndex,
        );

        return area.polygons.map((piece) {
          return Polygon<String>(
            points: piece.outer,
            holePointsList: piece.holes.isEmpty ? null : piece.holes,
            color: color.withValues(
              alpha: isMine
                  ? ClaimedAreasLayer.myFillAlpha
                  : ClaimedAreasLayer.otherFillAlpha,
            ),
            borderColor: color.withValues(
              alpha: isMine
                  ? ClaimedAreasLayer.myBorderAlpha
                  : ClaimedAreasLayer.otherBorderAlpha,
            ),
            borderStrokeWidth: isMine
                ? ClaimedAreasLayer.myBorderStrokeWidth
                : ClaimedAreasLayer.otherBorderStrokeWidth,
            hitValue: area.id,
          );
        });
      }).toList(),
    );
  }
}
