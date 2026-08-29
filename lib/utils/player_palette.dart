import 'package:flutter/painting.dart';

/// The fixed set of colours a player's claimed territory can be drawn in.
///
/// **Colours are stored as an index, never as a hex string.** `profiles/{uid}`
/// carries `areaColorIndex` (an int), and this class is the only place that
/// maps it to an actual `Color`. That indirection is what lets the palette be
/// re-tuned later — for dark mode, for accessibility, or just because a hue
/// reads badly on the terrain basemap — without migrating a single document.
/// It also means the same player is the same colour on every device, since
/// nothing about the rendering depends on who is looking.
///
/// Pure and dependency-free (no Firestore, no context) so the assignment and
/// fallback rules are unit-testable — see `test/player_palette_test.dart`.
class PlayerPalette {
  PlayerPalette._();

  /// **Keep in step with `PALETTE_SIZE` in `functions/index.js`.** The Cloud
  /// Function picks a random index in `[0, PALETTE_SIZE)` when a profile is
  /// created, so the two must agree or the server can hand out an index this
  /// palette cannot render (which [colorForIndex] survives, but only by
  /// falling back).
  static const int size = 10;

  /// Ten hues spread as widely around the wheel as ten categories reasonably
  /// allow, at a saturation that still reads as a distinct colour when drawn
  /// as a translucent fill over the terrain basemap.
  ///
  /// Ordered so that adjacent indices are also *visually* far apart: a small
  /// player base tends to occupy low indices if assignment is ever changed
  /// from random to sequential, and neighbouring indices colliding would be
  /// the worst case. Green is first because it is the app's own accent — it
  /// stays in the set rather than being reserved for "you", since ownership
  /// is signalled by weight rather than hue (see `ClaimedAreasLayer`).
  static const List<Color> colors = [
    Color(0xFF43A047), // green
    Color(0xFF1E88E5), // blue
    Color(0xFFE53935), // red
    Color(0xFF8E24AA), // purple
    Color(0xFFF57C00), // orange
    Color(0xFF00897B), // teal
    Color(0xFFD81B60), // pink
    Color(0xFF3949AB), // indigo
    Color(0xFF6D4C41), // brown
    Color(0xFFF9A825), // amber
  ];

  /// Human-readable names, same order as [colors] — for a future "your
  /// colour" row in settings, and useful in debugging ("why is this purple").
  static const List<String> names = [
    'Green',
    'Blue',
    'Red',
    'Purple',
    'Orange',
    'Teal',
    'Pink',
    'Indigo',
    'Brown',
    'Amber',
  ];

  /// The colour for a player, given their stored [colorIndex] and [uid].
  ///
  /// [colorIndex] wins when it is a valid index. When it is null or out of
  /// range — a profile created before this feature existed, one the backfill
  /// has not reached, or a value written by a future palette with more
  /// entries — this falls back to [indexForUid], a stable hash of the uid.
  ///
  /// **The fallback is what makes this shippable without a migration**: every
  /// existing area gets a stable, sensible colour the moment the feature
  /// lands, and the backfill script then merely persists what was already
  /// being shown. It also means a failed or partial backfill degrades to
  /// "slightly different colours" rather than "everyone is grey".
  static Color colorFor({required String uid, int? colorIndex}) =>
      colors[resolveIndex(uid: uid, colorIndex: colorIndex)];

  /// The palette index actually used for a player — [colorIndex] if valid,
  /// otherwise the uid-derived fallback.
  static int resolveIndex({required String uid, int? colorIndex}) {
    if (colorIndex != null && colorIndex >= 0 && colorIndex < size) {
      return colorIndex;
    }
    return indexForUid(uid);
  }

  /// A deterministic index derived from the uid — the same everywhere, on
  /// every device, forever, with no storage.
  ///
  /// FNV-1a rather than `uid.hashCode`: Dart's string hash is not guaranteed
  /// stable across runs or platform implementations, so a player could change
  /// colour between an app restart or between Android and iOS. This is a
  /// fixed algorithm over the uid's code units, so it cannot drift.
  static int indexForUid(String uid) {
    if (uid.isEmpty) return 0;
    // 32-bit FNV-1a. Masked to 32 bits at each step so the arithmetic stays
    // identical on the web's 53-bit ints and native 64-bit ints.
    int hash = 0x811C9DC5;
    for (var i = 0; i < uid.length; i++) {
      hash ^= uid.codeUnitAt(i);
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash % size;
  }
}
