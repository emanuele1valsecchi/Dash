import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';

import 'package:dash/services/place_search_service.dart';

/// Covers `search`'s two-stage streaming. The ranking it applies is tested
/// separately in `place_search_ranking_test.dart`; this file is about *when*
/// results are emitted and what happens when either backend misbehaves.
void main() {
  const milan = LatLng(45.4642, 9.1900);

  tearDown(() => PlaceSearchService.clientOverride = null);

  String nominatimJson(List<Map<String, Object>> places) => jsonEncode([
        for (final p in places)
          {
            'display_name': p['name'],
            'lat': '${p['lat']}',
            'lon': '${p['lon']}',
            'importance': p['importance'] ?? 0.5,
          }
      ]);

  String overpassJson(List<Map<String, Object>> elements) => jsonEncode({
        'elements': [
          for (final e in elements)
            {
              'lat': e['lat'],
              'lon': e['lon'],
              'tags': {'name': e['name']},
            }
        ]
      });

  /// Serves Nominatim and Overpass separately. Either may be null, which
  /// makes that backend fail.
  void serve({String? nominatim, String? overpass, int status = 200}) {
    PlaceSearchService.clientOverride = MockClient((request) async {
      final isOverpass = request.url.host.contains('overpass');
      final body = isOverpass ? overpass : nominatim;
      if (body == null) return http.Response('boom', 500);
      return http.Response(body, status, headers: {
        'content-type': 'application/json; charset=utf-8',
      });
    });
  }

  group('the first emission', () {
    test('carries Nominatim\'s own results', () async {
      serve(nominatim: nominatimJson([
        {'name': 'Milano, Italy', 'lat': 45.46, 'lon': 9.19},
      ]));

      final emissions =
          await PlaceSearchService.search('Milano', near: milan).toList();

      expect(emissions.first, hasLength(1));
      expect(emissions.first.single.displayName, 'Milano, Italy');
    });

    test('arrives even when Nominatim fails outright', () async {
      // The stream must always produce something; a caller showing a
      // spinner until the first emission would otherwise hang forever.
      serve(nominatim: null, overpass: overpassJson([]));

      final emissions =
          await PlaceSearchService.search('Milano', near: milan).toList();

      expect(emissions.first, isEmpty);
    });

    test('a malformed payload is treated as no results, not an error',
        () async {
      serve(nominatim: 'this is not json', overpass: overpassJson([]));

      final emissions =
          await PlaceSearchService.search('Milano', near: milan).toList();

      expect(emissions.first, isEmpty);
    });

    test('is capped by limit', () async {
      serve(nominatim: nominatimJson([
        for (var i = 0; i < 12; i++)
          {'name': 'Place $i', 'lat': 45.0 + i / 100, 'lon': 9.0},
      ]));

      final emissions = await PlaceSearchService.search(
        'Place',
        near: milan,
        limit: 3,
      ).toList();

      expect(emissions.first, hasLength(3));
    });
  });

  group('the Overpass fallback', () {
    test('runs when Nominatim found too little', () async {
      // Fewer than three results is the trigger — the informally-named
      // places Nominatim's address search misses are exactly the case.
      serve(
        nominatim: nominatimJson([
          {'name': 'Politecnico', 'lat': 45.478, 'lon': 9.227},
        ]),
        overpass: overpassJson([
          {'name': 'Edificio 25', 'lat': 45.479, 'lon': 9.228},
        ]),
      );

      final emissions =
          await PlaceSearchService.search('Edificio 25', near: milan).toList();

      expect(emissions, hasLength(2));
      expect(emissions.last.length, greaterThan(emissions.first.length));
    });

    test('does not run when Nominatim already answered well', () async {
      serve(
        nominatim: nominatimJson([
          {'name': 'A', 'lat': 45.1, 'lon': 9.1},
          {'name': 'B', 'lat': 45.2, 'lon': 9.2},
          {'name': 'C', 'lat': 45.3, 'lon': 9.3},
        ]),
        overpass: overpassJson([
          {'name': 'Extra', 'lat': 45.4, 'lon': 9.4},
        ]),
      );

      final emissions =
          await PlaceSearchService.search('thing', near: milan).toList();

      expect(emissions, hasLength(1),
          reason: 'three results is enough; do not spend a slow POI query');
    });

    test('does not run without a location to search around', () async {
      // The Overpass query is bounded to a radius, so it needs a centre.
      serve(
        nominatim: nominatimJson([
          {'name': 'Only one', 'lat': 45.1, 'lon': 9.1},
        ]),
        overpass: overpassJson([
          {'name': 'Extra', 'lat': 45.4, 'lon': 9.4},
        ]),
      );

      final emissions = await PlaceSearchService.search('thing').toList();

      expect(emissions, hasLength(1));
    });

    test('a failure leaves the first emission standing', () async {
      // Overpass has been measured anywhere from 7s to 37s and is often
      // rate-limited; it must never take the good results down with it.
      serve(
        nominatim: nominatimJson([
          {'name': 'Politecnico', 'lat': 45.478, 'lon': 9.227},
        ]),
        overpass: null,
      );

      final emissions =
          await PlaceSearchService.search('Politecnico', near: milan).toList();

      expect(emissions, hasLength(1));
      expect(emissions.single, hasLength(1));
    });

    test('adds no second emission when it finds nothing new', () async {
      serve(
        nominatim: nominatimJson([
          {'name': 'Politecnico', 'lat': 45.478, 'lon': 9.227},
        ]),
        overpass: overpassJson([]),
      );

      final emissions =
          await PlaceSearchService.search('Politecnico', near: milan).toList();

      expect(emissions, hasLength(1));
    });

    test('a POI at the same spot as a Nominatim hit is not repeated',
        () async {
      // Both backends describe the same building; showing it twice would
      // read as a bug.
      serve(
        nominatim: nominatimJson([
          {'name': 'Politecnico', 'lat': 45.4780, 'lon': 9.2270},
        ]),
        overpass: overpassJson([
          {'name': 'Politecnico di Milano', 'lat': 45.47801, 'lon': 9.22701},
        ]),
      );

      final emissions =
          await PlaceSearchService.search('Politecnico', near: milan).toList();

      expect(emissions, hasLength(1),
          reason: 'the only POI was a duplicate, so nothing new to emit');
    });
  });

  group('the request', () {
    test('biases Nominatim toward the given location', () async {
      Uri? seen;
      PlaceSearchService.clientOverride = MockClient((request) async {
        seen ??= request.url;
        return http.Response(nominatimJson([]), 200);
      });

      await PlaceSearchService.search('Via Roma', near: milan).toList();

      expect(seen!.query, contains('viewbox'));
    });

    test('sends no viewbox when there is no location', () async {
      Uri? seen;
      PlaceSearchService.clientOverride = MockClient((request) async {
        seen ??= request.url;
        return http.Response(nominatimJson([]), 200);
      });

      await PlaceSearchService.search('Via Roma').toList();

      expect(seen!.query, isNot(contains('viewbox')));
    });

    test('over-fetches raw candidates beyond what it will show', () async {
      // Nominatim's own ordering can bury a famous place outside a small
      // window, so ranking needs more candidates than the list shows.
      Uri? seen;
      PlaceSearchService.clientOverride = MockClient((request) async {
        seen ??= request.url;
        return http.Response(nominatimJson([]), 200);
      });

      await PlaceSearchService.search('London', limit: 10, rawLimit: 15)
          .toList();

      expect(seen!.queryParameters['limit'], '15');
    });

    test('identifies the app, as Nominatim\'s policy requires', () async {
      String? agent;
      PlaceSearchService.clientOverride = MockClient((request) async {
        agent ??= request.headers['User-Agent'];
        return http.Response(nominatimJson([]), 200);
      });

      await PlaceSearchService.search('Milano').toList();

      expect(agent, contains('Dash'));
    });
  });

  group('parsing', () {
    test('a place with no importance gets a low default', () async {
      PlaceSearchService.clientOverride = MockClient((request) async =>
          http.Response(
              jsonEncode([
                {
                  'display_name': 'Somewhere',
                  'lat': '45.0',
                  'lon': '9.0',
                }
              ]),
              200));

      final emissions = await PlaceSearchService.search('Somewhere').toList();

      expect(emissions.first.single.importance, 0.1);
    });

    test('coordinates arrive as strings and become numbers', () async {
      serve(nominatim: nominatimJson([
        {'name': 'Milano', 'lat': 45.4642, 'lon': 9.19},
      ]));

      final emissions = await PlaceSearchService.search('Milano').toList();

      expect(emissions.first.single.latLng.latitude, closeTo(45.4642, 1e-9));
      expect(emissions.first.single.latLng.longitude, closeTo(9.19, 1e-9));
    });

    test('a non-200 response yields no results rather than throwing',
        () async {
      PlaceSearchService.clientOverride =
          MockClient((request) async => http.Response('rate limited', 429));

      final emissions = await PlaceSearchService.search('Milano').toList();

      expect(emissions.first, isEmpty);
    });
  });
}
