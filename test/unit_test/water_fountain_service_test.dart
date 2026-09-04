import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dash/services/water_fountain_service.dart';

/// The service exists to keep Overpass requests rare: fountains are static
/// infrastructure, the public instance is slow and aggressively rate-limited,
/// and this runs on a phone mid-workout. Most of what matters is what it
/// avoids fetching, and that a failure is never mistaken for "none here".
void main() {
  final service = WaterFountainService.instance;

  const milan = LatLng(45.4642, 9.1900);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    service.resetForTest();
  });

  tearDown(service.resetForTest);

  String overpass(List<Map<String, Object>> nodes) => jsonEncode({
        'elements': [
          for (final n in nodes)
            {
              'type': 'node',
              'id': n['id'],
              'lat': n['lat'],
              'lon': n['lon'],
            }
        ]
      });

  /// Counts how many Overpass requests actually went out.
  var requests = 0;

  void serve(String? body, {int status = 200}) {
    requests = 0;
    service.clientOverride = MockClient((request) async {
      requests++;
      if (body == null) return http.Response('boom', 500);
      return http.Response(body, status);
    });
  }

  group('fetching', () {
    test('returns the fountains found', () async {
      serve(overpass([
        {'id': 1, 'lat': 45.465, 'lon': 9.19},
        {'id': 2, 'lat': 45.466, 'lon': 9.20},
      ]));

      final found = await service.fetchNearby(milan);

      expect(found, hasLength(2));
      expect(found!.first.position.latitude, closeTo(45.465, 1e-9));
    });

    test('ids identify the OSM node, so markers can be keyed by them',
        () async {
      // flutter_map culls off-screen markers every frame and reconciles the
      // rest by list position unless they are keyed.
      serve(overpass([
        {'id': 42, 'lat': 45.465, 'lon': 9.19},
      ]));

      final found = await service.fetchNearby(milan);

      expect(found!.single.id, 'node/42');
    });

    test('a node with no coordinates is skipped, not crashed on', () async {
      service.clientOverride = MockClient((request) async => http.Response(
            jsonEncode({
              'elements': [
                {'type': 'node', 'id': 1},
                {'type': 'node', 'id': 2, 'lat': 45.465, 'lon': 9.19},
              ]
            }),
            200,
          ));

      final found = await service.fetchNearby(milan);

      expect(found, hasLength(1));
    });

    test('identifies the app, which Overpass requires', () async {
      // Overpass answers 406 to a request with no User-Agent.
      String? agent;
      service.clientOverride = MockClient((request) async {
        agent ??= request.headers['User-Agent'];
        return http.Response(overpass([]), 200);
      });

      await service.fetchNearby(milan);

      expect(agent, contains('Dash'));
    });

    test('an area with genuinely no fountains returns an empty list',
        () async {
      serve(overpass([]));

      expect(await service.fetchNearby(milan), isEmpty);
    });
  });

  group('failure is not "none here"', () {
    // The distinction callers depend on: null means "leave whatever is
    // already showing", empty means "checked, there are none".
    test('a non-200 response returns null', () async {
      serve(null);

      expect(await service.fetchNearby(milan), isNull);
    });

    test('a rate-limited HTML body returns null, not zero results', () async {
      // Overpass answers 200 with an HTML error page when busy, so status
      // alone is not enough — the parse failure is what catches this.
      service.clientOverride = MockClient((request) async =>
          http.Response('<html>rate_limited</html>', 200));

      expect(await service.fetchNearby(milan), isNull);
    });

    test('an unreachable server returns null', () async {
      service.clientOverride =
          MockClient((request) async => throw Exception('offline'));

      expect(await service.fetchNearby(milan), isNull);
    });

    test('a failure is not cached, so the next attempt tries again',
        () async {
      service.clientOverride = MockClient((request) async {
        requests++;
        return requests == 1
            ? http.Response('boom', 500)
            : http.Response(overpass([
                {'id': 1, 'lat': 45.465, 'lon': 9.19},
              ]), 200);
      });
      requests = 0;

      expect(await service.fetchNearby(milan), isNull);
      expect(await service.fetchNearby(milan), hasLength(1));
    });
  });

  group('caching', () {
    test('a second call for the same area sends no request', () async {
      serve(overpass([
        {'id': 1, 'lat': 45.465, 'lon': 9.19},
      ]));

      await service.fetchNearby(milan);
      await service.fetchNearby(milan);

      expect(requests, 1);
    });

    test('a starting point a few streets away hits the same entry', () async {
      // The key snaps to a ~2km grid, deliberately close to the 3km query
      // radius, so a runner starting a few hundred metres away reuses the
      // answer rather than paying for a near-identical one.
      //
      // The second point is chosen to sit inside the same cell rather than
      // merely near the first: grid snapping is by definition discontinuous
      // at a cell edge, and 9.19 lands almost exactly on one (9.19 / 0.02 is
      // 459.49999… in binary floating point, so it rounds down while 9.191
      // rounds up). Two points 100 m apart across that seam legitimately
      // miss each other's cache entry.
      serve(overpass([
        {'id': 1, 'lat': 45.465, 'lon': 9.19},
      ]));

      await service.fetchNearby(milan);
      await service.fetchNearby(const LatLng(45.4680, 9.1880));

      expect(requests, 1);
    });

    test('a genuinely different city does send a request', () async {
      serve(overpass([
        {'id': 1, 'lat': 45.465, 'lon': 9.19},
      ]));

      await service.fetchNearby(milan);
      await service.fetchNearby(const LatLng(41.9028, 12.4964));

      expect(requests, 2);
    });

    test('concurrent callers for the same area share one request', () async {
      // A burst of near-simultaneous callers must not each fire their own
      // duplicate query.
      serve(overpass([
        {'id': 1, 'lat': 45.465, 'lon': 9.19},
      ]));

      final results = await Future.wait([
        service.fetchNearby(milan),
        service.fetchNearby(milan),
        service.fetchNearby(milan),
      ]);

      expect(requests, 1);
      expect(results.every((r) => r != null && r.length == 1), isTrue);
    });
  });

  group('the disk cache', () {
    test('a fetch is written to disk', () async {
      serve(overpass([
        {'id': 1, 'lat': 45.465, 'lon': 9.19},
      ]));

      await service.fetchNearby(milan);
      await Future<void>.delayed(Duration.zero);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('water_fountain_cache_v1'), isNotNull);
    });

    test('survives a cold start, so a familiar start point loads instantly',
        () async {
      serve(overpass([
        {'id': 1, 'lat': 45.465, 'lon': 9.19},
      ]));
      await service.fetchNearby(milan);
      await Future<void>.delayed(Duration.zero);
      final prefs = await SharedPreferences.getInstance();
      final blob = prefs.getString('water_fountain_cache_v1')!;

      // A fresh launch: memory gone, disk intact.
      service.resetForTest();
      SharedPreferences.setMockInitialValues(
          {'water_fountain_cache_v1': blob});
      serve(overpass([]));

      final found = await service.fetchNearby(milan);

      expect(found, hasLength(1));
      expect(requests, 0, reason: 'answered from disk, no network at all');
    });

    test('a corrupt blob is ignored rather than fatal', () async {
      SharedPreferences.setMockInitialValues(
          {'water_fountain_cache_v1': 'not json'});
      serve(overpass([
        {'id': 1, 'lat': 45.465, 'lon': 9.19},
      ]));

      final found = await service.fetchNearby(milan);

      expect(found, hasLength(1));
    });

    test('a stale entry is not served', () async {
      // Fountains barely change, but the TTL is a hedge against drift.
      final old = DateTime.now().subtract(const Duration(days: 40));
      SharedPreferences.setMockInitialValues({
        'water_fountain_cache_v1': jsonEncode({
          'radius:45.46,9.18,3000': {
            'fetchedAt': old.millisecondsSinceEpoch,
            'fountains': [
              {'id': 'node/9', 'lat': 45.465, 'lon': 9.19},
            ],
          }
        }),
      });
      serve(overpass([
        {'id': 1, 'lat': 45.465, 'lon': 9.19},
      ]));

      final found = await service.fetchNearby(milan);

      expect(requests, 1, reason: 'the stale entry should not have been used');
      expect(found!.single.id, 'node/1');
    });

    test('warmUp reads disk only once', () async {
      serve(overpass([]));

      await service.warmUp();
      await service.warmUp();

      expect(requests, 0);
    });
  });
}
