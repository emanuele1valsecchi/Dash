import 'package:flutter_test/flutter_test.dart';

import 'package:dash/utils/leaderboard_order.dart';

void main() {
  group('LeaderboardOrder.defaultOrder', () {
    const global = LeaderboardOrder.globalTitle;

    test('puts the global board first and the metro area second', () {
      final order = LeaderboardOrder.defaultOrder(
        ['Northern Lombardy', 'Roma'],
        metroTerritory: 'Milano',
      );

      expect(order, [global, 'Milano', 'Northern Lombardy', 'Roma']);
    });

    test('promotes the metro area out of the territory list, not alongside it',
        () {
      // The metro area is normally also one of the territories the runner has
      // scored in, so it arrives in both arguments. It must appear once.
      final order = LeaderboardOrder.defaultOrder(
        ['Northern Lombardy', 'Milano', 'Roma'],
        metroTerritory: 'Milano',
      );

      expect(order, [global, 'Milano', 'Northern Lombardy', 'Roma']);
      expect(order.where((t) => t == 'Milano').length, 1);
    });

    test('keeps the caller\'s order for everything below the metro area', () {
      // Callers pass territories most recently scored in first; that ordering
      // has to survive.
      final order = LeaderboardOrder.defaultOrder(
        ['Roma', 'Torino', 'Napoli'],
        metroTerritory: 'Milano',
      );

      expect(order.sublist(2), ['Roma', 'Torino', 'Napoli']);
    });

    group('when there is no metro area', () {
      test('null leaves the territories directly under global', () {
        expect(
          LeaderboardOrder.defaultOrder(['Northern Lombardy']),
          [global, 'Northern Lombardy'],
        );
      });

      test('an empty string is treated as absent, not as a blank row', () {
        expect(
          LeaderboardOrder.defaultOrder(['Roma'], metroTerritory: ''),
          [global, 'Roma'],
        );
      });

      test('a runner with no runs at all still gets the global board', () {
        expect(LeaderboardOrder.defaultOrder(const []), [global]);
      });
    });

    test('drops duplicates and blanks from the territory list', () {
      final order = LeaderboardOrder.defaultOrder(
        ['Roma', '', 'Roma', 'Torino'],
      );

      expect(order, [global, 'Roma', 'Torino']);
    });

    test('never lists the global board twice', () {
      // Defensive: the global title should never arrive as a territory, but
      // if it did, promoting or appending it again would produce two rows
      // competing for the same saved-config identity.
      final order = LeaderboardOrder.defaultOrder(
        [global, 'Roma'],
        metroTerritory: global,
      );

      expect(order, [global, 'Roma']);
    });
  });
}
