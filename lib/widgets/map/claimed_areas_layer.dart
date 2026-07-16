import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

import '../../services/claimed_area_repository.dart';

/// Renders claimed-area polygons, colored by whether the signed-in user owns
/// them — not by the (currently unused) per-area `colorHex` Firestore field,
/// since "mine vs. someone else's" is relative to whoever's looking, not a
/// fixed property of the area itself. Deliberately a single flat color for
/// "someone else's" rather than one per owner: this is a placeholder scheme,
/// expected to change once there's an actual design for distinguishing
/// multiple other players.
///
/// Pass [hitNotifier] (and the same instance to `MapOptions.onTap` via
/// `handleAreaTap`/`showAreaDetailsSheet` in area_details_sheet.dart) to make
/// polygons tappable; omit it on screens where tapping shouldn't open area
/// details (currently everywhere except the Explore/Area page).
class ClaimedAreasLayer extends StatelessWidget {
  final List<ClaimedArea> areas;
  final LayerHitNotifier<String>? hitNotifier;

  const ClaimedAreasLayer({super.key, required this.areas, this.hitNotifier});

  /// The app's established green accent — used for the signed-in user's own
  /// areas.
  static const Color myColor = Color(0xFF4A8C52);

  /// Placeholder single color for every other user's areas.
  static const Color otherColor = Color(0xFFE53935);

  @override
  Widget build(BuildContext context) {
    final myUid = FirebaseAuth.instance.currentUser?.uid;
    return PolygonLayer<String>(
      hitNotifier: hitNotifier,
      // An area can be more than one disconnected piece (a steal that cuts
      // straight through leaves two remaining fragments) — each piece
      // becomes its own Polygon, but all share the same hitValue, so
      // tapping any fragment opens the same area's details.
      polygons: areas.expand((area) {
        final color = area.userId == myUid ? myColor : otherColor;
        return area.polygons.map((piece) {
          return Polygon<String>(
            points: piece.outer,
            holePointsList: piece.holes.isEmpty ? null : piece.holes,
            color: color.withValues(alpha: 0.25),
            borderColor: color.withValues(alpha: 0.8),
            borderStrokeWidth: 2.0,
            hitValue: area.id,
          );
        });
      }).toList(),
    );
  }
}
