import 'package:dash/utils/player_palette.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('palette', () {
    test('size matches the number of colours and names', () {
      // PALETTE_SIZE in functions/index.js and _backfill_area_colors.js is
      // written against this number; a mismatch means the server can hand out
      // an index the client cannot render.
      expect(PlayerPalette.colors.length, PlayerPalette.size);
      expect(PlayerPalette.names.length, PlayerPalette.size);
    });

    test('every colour is distinct', () {
      expect(PlayerPalette.colors.toSet().length, PlayerPalette.size);
    });
  });

  group('index resolution', () {
    test('a valid stored index wins over the hash', () {
      for (var i = 0; i < PlayerPalette.size; i++) {
        expect(
          PlayerPalette.resolveIndex(uid: 'anything', colorIndex: i),
          i,
        );
      }
    });

    test('null or out-of-range falls back to the uid hash', () {
      const uid = 'LxK9mQ2pRfTgYhUj';
      final hashed = PlayerPalette.indexForUid(uid);
      for (final bad in <int?>[null, -1, PlayerPalette.size, 9999]) {
        expect(PlayerPalette.resolveIndex(uid: uid, colorIndex: bad), hashed);
      }
    });

    test('colorFor never throws and always returns a palette colour', () {
      for (final uid in ['', 'a', 'user-42', 'ÀÉîøü']) {
        for (final idx in <int?>[null, -5, 0, 3, 42]) {
          final c = PlayerPalette.colorFor(uid: uid, colorIndex: idx);
          expect(PlayerPalette.colors, contains(c));
        }
      }
    });
  });

  group('uid hash', () {
    test('is stable and in range', () {
      for (final uid in ['', 'a', 'abc', 'user-42', 'ÀÉîøü']) {
        final first = PlayerPalette.indexForUid(uid);
        expect(first, PlayerPalette.indexForUid(uid));
        expect(first, inInclusiveRange(0, PlayerPalette.size - 1));
      }
    });

    test('matches the JS port used by the backfill script, exactly', () {
      // These are the values produced by `indexForUid` in
      // functions/_backfill_area_colors.js. The script writes down the colour
      // the client was *already* showing via this fallback, so if the two
      // implementations ever diverge, running the backfill would silently
      // change every un-backfilled player's colour on the map.
      const expected = <String, int>{
        '': 0,
        'a': 0,
        'abc': 1,
        'LxK9mQ2pRfTgYhUj': 8,
        '0': 3,
        'zzzzzzzzzzzzzzzzzzzzzzzzzzzz': 7,
        'user-42': 9,
        'ÀÉîøü': 8,
      };
      expected.forEach((uid, index) {
        expect(PlayerPalette.indexForUid(uid), index, reason: 'uid "$uid"');
      });
    });

    test('spreads uids across the whole palette', () {
      // Not a uniformity proof — just a guard against a broken hash that
      // collapses everyone onto one or two colours.
      final seen = <int>{};
      for (var i = 0; i < 200; i++) {
        seen.add(PlayerPalette.indexForUid('firebase-uid-$i'));
      }
      expect(seen.length, PlayerPalette.size);
    });
  });
}
