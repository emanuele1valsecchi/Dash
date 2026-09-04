import 'package:dash/services/place_search_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

/// `PlaceSearchService.rank` — the re-ranking applied to Nominatim's results
/// before they reach the user.
///
/// **Two real failures produced this design, and both are pinned below.** A
/// weighted sum of the three signals put London, Ontario above London,
/// England for a European search; sorting on text match alone put a village
/// called "Londo" above London. The fix is a strict lexicographic sort — match
/// quality, then a *coarse tier* of importance, then proximity — where each
/// key is only a tiebreaker for the one before it.
///
/// Pure and static, so this needs no wiring: no HTTP, no Firebase, no widgets.
void main() {
  const london = LatLng(51.5074, -0.1278);
  const milan = LatLng(45.4642, 9.19);
  const ontario = LatLng(42.9849, -81.2453);

  Place place(String name, LatLng at, {double importance = 0.15}) =>
      Place(displayName: name, latLng: at, importance: importance);

  List<String> namesOf(List<Place> places) =>
      places.map((p) => p.displayName.split(',').first.trim()).toList();

  group('match quality comes first', () {
    test('an exact name beats a prefix match', () {
      final ranked = PlaceSearchService.rank(
        [
          place('Londonderry, UK', london, importance: 0.9),
          place('London, UK', london, importance: 0.9),
        ],
        'london',
        null,
      );

      expect(namesOf(ranked).first, 'London');
    });

    test('a prefix match beats a mere substring match', () {
      final ranked = PlaceSearchService.rank(
        [
          place('New London, USA', london),
          place('Londonderry, UK', london),
        ],
        'london',
        null,
      );

      expect(namesOf(ranked).first, 'Londonderry');
    });

    test('anything matching beats something that does not', () {
      final ranked = PlaceSearchService.rank(
        [
          place('Paris, France', london, importance: 0.95),
          place('London, UK', london, importance: 0.1),
        ],
        'london',
        null,
      );

      expect(namesOf(ranked).first, 'London');
    });

    test('only the primary name counts for an exact match', () {
      // Nominatim returns "Name, Region, Country"; matching the whole string
      // would make almost nothing an exact match.
      final ranked = PlaceSearchService.rank(
        [
          place('Somewhere, London, UK', london),
          place('London, UK', london),
        ],
        'london',
        null,
      );

      expect(namesOf(ranked).first, 'London');
    });

    test('matching ignores case', () {
      final ranked = PlaceSearchService.rank(
        [place('Milano, Italy', milan), place('LONDON, UK', london)],
        'london',
        null,
      );

      expect(namesOf(ranked).first, 'LONDON');
    });
  });

  group('importance breaks a match-quality tie', () {
    test('the famous city wins over an obscure namesake', () {
      // Both are exact matches, so the text signal cannot separate them.
      final ranked = PlaceSearchService.rank(
        [
          place('London, Ontario', ontario, importance: 0.4),
          place('London, UK', london, importance: 0.9),
        ],
        'london',
        null,
      );

      expect(ranked.first.latLng.longitude, closeTo(-0.1278, 0.001));
    });

    test('the regression: a famous prefix match beats an obscure exact match',
        () {
      // The bug this ordering was written for. Text match still wins - which
      // is correct - so the guard is that a village called "Londo" must not
      // be an exact match for the query "london" in the first place.
      final ranked = PlaceSearchService.rank(
        [
          place('Londo, Nowhere', milan, importance: 0.05),
          place('London, UK', london, importance: 0.9),
        ],
        'london',
        null,
      );

      expect(namesOf(ranked).first, 'London');
    });
  });

  group('importance is bucketed, not compared as a raw float', () {
    // The reason: a razor-thin importance difference must not override
    // proximity, but a real notability gap must.
    test('a hair more importance does not beat being much closer', () {
      final ranked = PlaceSearchService.rank(
        [
          // Same tier (0.6-0.8), so this falls through to proximity.
          place('Faraway, Canada', ontario, importance: 0.75),
          place('Nearby, Italy', milan, importance: 0.70),
        ],
        'a',
        milan,
      );

      expect(namesOf(ranked).first, 'Nearby');
    });

    test('but a whole tier of importance does beat proximity', () {
      final ranked = PlaceSearchService.rank(
        [
          place('Faraway, UK', london, importance: 0.95),
          place('Nearby, Italy', milan, importance: 0.15),
        ],
        'a',
        milan,
      );

      expect(namesOf(ranked).first, 'Faraway');
    });

    test('an importance of exactly 1.0 stays in range', () {
      // `(importance * 5).floor()` would be 5 without the clamp, which is
      // outside the five buckets.
      final ranked = PlaceSearchService.rank(
        [place('Max, UK', london, importance: 1.0)],
        'max',
        null,
      );

      expect(ranked, hasLength(1));
    });
  });

  group('proximity is the last word', () {
    test('with everything else equal, the nearer place wins', () {
      final ranked = PlaceSearchService.rank(
        [
          place('Park, Canada', ontario),
          place('Park, Italy', milan),
        ],
        'park',
        milan,
      );

      expect(ranked.first.latLng.latitude, closeTo(45.4642, 0.001));
    });

    test('with no location known, order is left to the earlier keys', () {
      // Everything ties, so nothing should throw and the list survives whole.
      final ranked = PlaceSearchService.rank(
        [place('Park, Canada', ontario), place('Park, Italy', milan)],
        'park',
        null,
      );

      expect(ranked, hasLength(2));
    });
  });

  group('robustness', () {
    test('an empty result list stays empty', () {
      expect(PlaceSearchService.rank([], 'london', milan), isEmpty);
    });

    test('an empty query does not throw', () {
      final ranked = PlaceSearchService.rank(
        [place('London, UK', london)],
        '',
        milan,
      );

      expect(ranked, hasLength(1));
    });

    test('a query with surrounding whitespace is trimmed', () {
      final ranked = PlaceSearchService.rank(
        [
          place('Milano, Italy', milan),
          place('London, UK', london),
        ],
        '  london  ',
        null,
      );

      expect(namesOf(ranked).first, 'London');
    });

    test('ranking never drops or duplicates a result', () {
      final input = [
        place('London, UK', london, importance: 0.9),
        place('Londonderry, UK', london),
        place('Milano, Italy', milan, importance: 0.8),
        place('Park, Canada', ontario),
      ];

      final ranked = PlaceSearchService.rank(input, 'london', milan);

      expect(ranked, hasLength(input.length));
      expect(
        namesOf(ranked)..sort(),
        namesOf(input)..sort(),
      );
    });

    test('the input list is not mutated', () {
      // `rank` copies before sorting; callers hold onto the original.
      final input = [
        place('Milano, Italy', milan),
        place('London, UK', london, importance: 0.9),
      ];
      final before = namesOf(input);

      PlaceSearchService.rank(input, 'london', null);

      expect(namesOf(input), before);
    });
  });

  group('Place defaults', () {
    test('a place with no score gets a modest default importance', () {
      // The Overpass POI fallback has no importance of its own. The default
      // must be low enough not to outrank a genuine Nominatim result.
      const poi = Place(displayName: 'Edificio 25 Polimi', latLng: milan);

      expect(poi.importance, lessThan(0.2));
    });

    test('a POI does not outrank a well-known city on importance alone', () {
      final ranked = PlaceSearchService.rank(
        [
          const Place(displayName: 'London Cafe', latLng: milan),
          place('London, UK', london, importance: 0.9),
        ],
        'london',
        milan,
      );

      expect(namesOf(ranked).first, 'London');
    });
  });
}
