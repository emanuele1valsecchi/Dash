import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../services/claimed_area_repository.dart';
import '../../services/user_appearance_service.dart';
import '../../utils/geometry_utils.dart';
import '../../utils/player_palette.dart';

/// A circular profile-picture badge floating over each claimed area, ringed in
/// that owner's palette colour.
///
/// Colour alone tells you *that* two areas belong to the same person; the
/// bubble tells you *who*, without a tap. Together they turn "some red
/// territory" into "that whole block is Marco's", which is what makes a steal
/// a deliberate act rather than a random one.
///
/// Currently used only on the Explore page. The other four map screens are
/// task-focused (planning a route, running) where an extra layer of faces
/// would be clutter — see `ClaimedAreasLayer`'s own note about which screens
/// get tap-to-view.
class AreaOwnerBubblesLayer extends StatefulWidget {
  const AreaOwnerBubblesLayer({
    super.key,
    required this.areas,
    required this.visible,
    this.onTapArea,
  });

  final List<ClaimedArea> areas;

  /// Zoom-gated by the host screen, exactly like `WaterFountainMarkerLayer` —
  /// the screen computes this in `MapOptions.onPositionChanged` and passes it
  /// down, rather than this widget reading the ambient `MapCamera`, which has
  /// proven not to reliably trigger a rebuild in this app.
  final bool visible;

  /// Opens the area's details — the same sheet a polygon tap opens. The badge
  /// is small enough to be a fiddly target on its own, so this is a
  /// convenience on top of the polygon hit-test, not a replacement for it.
  final void Function(ClaimedArea area)? onTapArea;

  /// Below this the map is showing too wide a region for face-sized badges to
  /// be legible, and they would pile on top of each other.
  static const double minZoomToShow = 12.0;

  /// Hard cap on how many bubbles are drawn at once. Territory counts are
  /// small today, but a dense city viewport should degrade into "the biggest
  /// claims are labelled" rather than an unreadable wall of faces. The
  /// *largest* areas win, since those are the ones worth targeting.
  static const int maxBubbles = 40;

  @override
  State<AreaOwnerBubblesLayer> createState() => _AreaOwnerBubblesLayerState();
}

class _AreaOwnerBubblesLayerState extends State<AreaOwnerBubblesLayer> {
  final UserAppearanceService _appearances = UserAppearanceService.instance;

  @override
  void initState() {
    super.initState();
    _appearances.addListener(_onAppearancesChanged);
    _requestAppearances();
  }

  @override
  void didUpdateWidget(covariant AreaOwnerBubblesLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
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

  void _requestAppearances() {
    _appearances.ensureLoaded(widget.areas.map((a) => a.userId));
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.visible) return const SizedBox.shrink();

    // Biggest first, so the cap keeps the claims most worth naming.
    final ranked = [...widget.areas]
      ..sort((a, b) => b.totalAreaM2.compareTo(a.totalAreaM2));

    final markers = <Marker>[];
    for (final area in ranked) {
      if (markers.length >= AreaOwnerBubblesLayer.maxBubbles) break;
      final anchor = _anchorFor(area);
      if (anchor == null) continue;

      final appearance = _appearances.get(area.userId);
      markers.add(
        Marker(
          // Keyed by area id: flutter_map culls off-screen markers every
          // frame and reconciles the rest by list position when unkeyed,
          // which would swap one player's face onto another's territory
          // during a pan. Same reasoning as `WaterFountainMarkerLayer`.
          key: ValueKey(area.id),
          point: anchor,
          width: _OwnerBubble.diameter,
          height: _OwnerBubble.diameter,
          child: _OwnerBubble(
            color: PlayerPalette.colorFor(
              uid: area.userId,
              colorIndex: appearance?.colorIndex,
            ),
            appearance: appearance,
            onTap: widget.onTapArea == null
                ? null
                : () => widget.onTapArea!(area),
          ),
        ),
      );
    }

    return MarkerLayer(markers: markers);
  }

  /// Where the bubble sits: the **northernmost point on the boundary** of the
  /// area's largest piece, with the badge centred on it so it straddles the
  /// edge — half over the territory, half outside it.
  ///
  /// On the perimeter rather than in the middle so the badge never covers the
  /// ground it is labelling: a claimed area is something you read (its shape,
  /// what streets it spans, how it overlaps yours), and a disc parked in the
  /// centre hides exactly that.
  ///
  /// Anchoring to a real vertex also removes a whole failure mode the earlier
  /// centroid approach had — a centroid can land *outside* a strongly concave
  /// or horseshoe-shaped polygon, leaving the bubble floating over someone
  /// else's ground. A boundary vertex is on the shape by definition, so no
  /// containment check or fallback is needed.
  ///
  /// Northernmost specifically because it reads as a label pinned to the top
  /// of the shape, and because it is deterministic — the same area anchors to
  /// the same spot on every device and never shifts as the map is panned.
  ///
  /// Largest piece rather than first, because a steal can split a claim into a
  /// big remainder and a tiny sliver, and the label belongs on the part that
  /// actually reads as the territory.
  LatLng? _anchorFor(ClaimedArea area) {
    if (area.polygons.isEmpty) return null;

    var bestArea = -1.0;
    List<LatLng>? bestRing;
    for (final piece in area.polygons) {
      if (piece.outer.length < 3) continue;
      final size = GeometryUtils.polygonAreaM2(piece.outer);
      if (size > bestArea) {
        bestArea = size;
        bestRing = piece.outer;
      }
    }
    final ring = bestRing;
    if (ring == null) return null;

    var top = ring.first;
    for (final p in ring) {
      // Longitude breaks ties so a flat top edge (common on road-snapped
      // claims following a straight street) always picks the same vertex
      // rather than whichever happened to come first in the ring.
      if (p.latitude > top.latitude ||
          (p.latitude == top.latitude && p.longitude < top.longitude)) {
        top = p;
      }
    }
    return top;
  }
}

/// The badge itself: the owner's picture in a circle, ringed in their colour.
class _OwnerBubble extends StatelessWidget {
  const _OwnerBubble({
    required this.color,
    required this.appearance,
    required this.onTap,
  });

  final Color color;
  final UserAppearance? appearance;
  final VoidCallback? onTap;

  /// Deliberately small: the badge is an identity cue sitting on top of the
  /// map, not a control. It only has to be recognisable at a glance, and a
  /// larger disc starts to obscure neighbouring territory once several
  /// adjacent areas each carry one. The polygon itself remains a large tap
  /// target for the same details sheet, so shrinking this costs no reachable
  /// affordance.
  static const double diameter = 26.0;
  static const double _ringWidth = 2.5;

  @override
  Widget build(BuildContext context) {
    final a = appearance;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color,
          border: Border.all(color: Colors.white, width: 1.2),
          // A `BoxShadow` on a Container repaints with the marker every
          // frame. `Icon.shadows` does not — it paints through TextStyle's
          // shadow mechanism, which flutter_map leaves stranded at the
          // marker's original screen position during a pan (see the
          // `_SearchResultPin` note in explore_page.dart). Hence a boxy
          // decoration rather than a shadowed glyph.
          boxShadow: const [
            BoxShadow(
              color: Color(0x40000000),
              blurRadius: 4,
              offset: Offset(0, 2),
            ),
          ],
        ),
        padding: const EdgeInsets.all(_ringWidth),
        child: ClipOval(
          child: (a != null && a.hasPhoto)
              ? CachedNetworkImage(
                  imageUrl: a.photoUrl!,
                  fit: BoxFit.cover,
                  width: double.infinity,
                  height: double.infinity,
                  placeholder: (_, _) => _Initial(color: color, text: null),
                  // A broken or expired photo URL must still leave a readable
                  // badge, not an error glyph on the map.
                  errorWidget: (_, _, _) =>
                      _Initial(color: color, text: a.initial),
                )
              : _Initial(color: color, text: a?.initial),
        ),
      ),
    );
  }
}

/// Fallback face: the owner's first initial on a white disc. Shown while the
/// profile or photo is still loading (with no letter) and permanently for
/// players who never uploaded a picture.
class _Initial extends StatelessWidget {
  const _Initial({required this.color, required this.text});

  final Color color;
  final String? text;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white,
      alignment: Alignment.center,
      child: text == null
          ? null
          : Text(
              text!,
              style: TextStyle(
                color: color,
                fontSize: 11,
                fontWeight: FontWeight.w800,
                height: 1,
              ),
            ),
    );
  }
}
