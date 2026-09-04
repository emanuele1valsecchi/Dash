import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mockito/mockito.dart';

import 'package:dash/services/routing_service.dart';

import '../mocks.mocks.dart';

/// `RoutingService` is entirely static, so it is seamed with
/// `functionsOverride` rather than a constructor. Every test resets it —
/// a leaked override would point later tests at a previous one's stub.
void main() {
  late MockFirebaseFunctions functions;
  late MockHttpsCallable callable;

  const origin = LatLng(45.4642, 9.1900);
  const destination = LatLng(45.4700, 9.2000);

  setUp(() {
    functions = MockFirebaseFunctions();
    callable = MockHttpsCallable();
    when(functions.httpsCallable(any, options: anyNamed('options')))
        .thenReturn(callable);
    RoutingService.functionsOverride = functions;
  });

  tearDown(() => RoutingService.functionsOverride = null);

  /// Makes the backend answer with `data`.
  void respondWith(Map<String, dynamic> data) {
    final result = MockHttpsCallableResult<dynamic>();
    when(result.data).thenReturn(data);
    when(callable.call(any)).thenAnswer((_) async => result);
  }

  /// Makes the call fail outright — an unreachable function or a timeout.
  /// `thenAnswer`, never `thenThrow`: the latter throws synchronously at the
  /// call site instead of completing the future with an error.
  void respondWithFailure([Object? error]) {
    when(callable.call(any))
        .thenAnswer((_) async => throw error ?? Exception('unreachable'));
  }

  /// One ORS GeoJSON feature. Coordinates are `[lon, lat]` — that is the
  /// GeoJSON order, and flipping it is the whole point of several tests here.
  Map<String, dynamic> feature({
    required List<List<double>> lonLat,
    required double distance,
  }) =>
      {
        'properties': {
          'summary': {'distance': distance},
        },
        'geometry': {'coordinates': lonLat},
      };

  Map<String, dynamic> okBody(List<Map<String, dynamic>> features) => {
        'status': 200,
        'body': {'features': features},
      };

  /// The argument map the service actually sent.
  Map<String, dynamic> sentPayload() =>
      verify(callable.call(captureAny)).captured.single as Map<String, dynamic>;

  group('straightLine', () {
    test('joins the two points directly', () {
      final seg = RoutingService.straightLine(origin, destination);

      expect(seg.polyline, [origin, destination]);
    });

    test('measures the real great-circle distance between them', () {
      final seg = RoutingService.straightLine(origin, destination);

      expect(seg.distanceMeters,
          closeTo(const Distance()(origin, destination), 0.001));
    });

    test('a zero-length line is zero metres, not an error', () {
      final seg = RoutingService.straightLine(origin, origin);

      expect(seg.distanceMeters, 0);
    });
  });

  group('fetchRoute', () {
    test('returns the road-snapped polyline and distance', () async {
      respondWith(okBody([
        feature(lonLat: [
          [9.19, 45.4642],
          [9.20, 45.4700],
        ], distance: 812.5),
      ]));

      final seg = await RoutingService.fetchRoute(origin, destination);

      expect(seg, isNotNull);
      expect(seg!.distanceMeters, 812.5);
      expect(seg.polyline, hasLength(2));
    });

    test('flips GeoJSON [lon, lat] into LatLng(lat, lng)', () async {
      // The single most damaging parsing mistake available here: getting it
      // backwards puts a Milan route in the Indian Ocean, and every distance
      // and area computed downstream is silently wrong rather than absent.
      respondWith(okBody([
        feature(lonLat: [
          [9.19, 45.4642],
        ], distance: 10),
      ]));

      final seg = await RoutingService.fetchRoute(origin, destination);

      expect(seg!.polyline.single.latitude, closeTo(45.4642, 1e-9));
      expect(seg.polyline.single.longitude, closeTo(9.19, 1e-9));
    });

    test('sends both endpoints as lat/lng pairs', () async {
      respondWith(okBody([
        feature(lonLat: [
          [9.19, 45.4642],
        ], distance: 10),
      ]));

      await RoutingService.fetchRoute(origin, destination);

      final sent = sentPayload();
      expect(sent['origin'], {'lat': 45.4642, 'lng': 9.19});
      expect(sent['destination'], {'lat': 45.47, 'lng': 9.20});
    });

    test('asks for a timeout with margin over the server\'s own', () async {
      // The Cloud Function's fetch-to-ORS timeout is 12s. A client timeout at
      // or below that makes the client give up first, and a timeout is then
      // indistinguishable from "no route found" — the documented cause of
      // long legs failing while short ones worked.
      respondWith(okBody([
        feature(lonLat: [
          [9.19, 45.4642],
        ], distance: 10),
      ]));

      await RoutingService.fetchRoute(origin, destination);

      final options = verify(functions.httpsCallable(
        'orsRoute',
        options: captureAnyNamed('options'),
      )).captured.single as HttpsCallableOptions;
      expect(options.timeout, greaterThan(const Duration(seconds: 12)));
    });

    group('failures', () {
      test('a non-200 status yields null', () async {
        respondWith({'status': 500, 'body': {}});

        expect(await RoutingService.fetchRoute(origin, destination), isNull);
      });

      test('an empty feature list yields null', () async {
        respondWith(okBody([]));

        expect(await RoutingService.fetchRoute(origin, destination), isNull);
      });

      test('a malformed payload yields null rather than throwing', () async {
        respondWith({'status': 200, 'body': 'not a map at all'});

        expect(await RoutingService.fetchRoute(origin, destination), isNull);
      });

      test('an unreachable backend yields null', () async {
        respondWithFailure();

        expect(await RoutingService.fetchRoute(origin, destination), isNull);
      });
    });

    group('rate limiting', () {
      test('a 429 is an ordinary failure by default', () async {
        // Existing callers — pin placement, deletion, snap-to-close — keep
        // their "null on any failure" contract.
        respondWith({'status': 429, 'body': {}});

        expect(await RoutingService.fetchRoute(origin, destination), isNull);
      });

      test('a 429 throws when the caller opts in', () async {
        // Freehand-draw conversion chains many sequential calls and must stop
        // probing rather than retry into an active throttling window.
        respondWith({'status': 429, 'body': {}});

        expect(
          () => RoutingService.fetchRoute(origin, destination,
              throwOnRateLimit: true),
          throwsA(isA<RoutingRateLimitedException>()),
        );
      });

      test('opting in does not turn other errors into that exception',
          () async {
        respondWith({'status': 500, 'body': {}});

        expect(
          await RoutingService.fetchRoute(origin, destination,
              throwOnRateLimit: true),
          isNull,
        );
      });
    });
  });

  group('fetchAlternatives', () {
    test('returns every alternative the backend offered', () async {
      respondWith(okBody([
        feature(lonLat: [
          [9.19, 45.46],
          [9.20, 45.47],
        ], distance: 900),
        feature(lonLat: [
          [9.19, 45.46],
          [9.21, 45.47],
        ], distance: 1100),
      ]));

      final routes =
          await RoutingService.fetchAlternatives(origin, destination);

      expect(routes, hasLength(2));
      expect(routes.map((r) => r.distanceMeters), [900, 1100]);
    });

    test('asks for alternatives mode and a target count', () async {
      respondWith(okBody([
        feature(lonLat: [
          [9.19, 45.46],
        ], distance: 10),
      ]));

      await RoutingService.fetchAlternatives(origin, destination,
          targetCount: 5);

      final sent = sentPayload();
      expect(sent['mode'], 'alternatives');
      expect(sent['targetCount'], 5);
    });

    test('falls back to a straight line on failure, by default', () async {
      respondWithFailure();

      final routes =
          await RoutingService.fetchAlternatives(origin, destination);

      expect(routes, hasLength(1));
      expect(routes.single.polyline, [origin, destination]);
    });

    test('returns nothing when the fallback is refused', () async {
      // Route search presents these as vetted results, so a straight line
      // masquerading as a road-snapped alternative is worse than no answer —
      // it is what put routes through buildings.
      respondWithFailure();

      final routes = await RoutingService.fetchAlternatives(
        origin,
        destination,
        allowStraightLineFallback: false,
      );

      expect(routes, isEmpty);
    });

    test('an empty feature list also honours the refused fallback', () async {
      respondWith(okBody([]));

      expect(
        await RoutingService.fetchAlternatives(origin, destination,
            allowStraightLineFallback: false),
        isEmpty,
      );
    });

    test('a 429 throws when the caller opts in', () async {
      respondWith({'status': 429, 'body': {}});

      expect(
        () => RoutingService.fetchAlternatives(origin, destination,
            throwOnRateLimit: true),
        throwsA(isA<RoutingRateLimitedException>()),
      );
    });
  });

  group('fetchRoundTrip', () {
    test('returns the loop it was given', () async {
      respondWith(okBody([
        feature(lonLat: [
          [9.19, 45.46],
          [9.20, 45.47],
          [9.19, 45.46],
        ], distance: 4000),
      ]));

      final loop =
          await RoutingService.fetchRoundTrip(origin, lengthMeters: 4000);

      expect(loop, isNotNull);
      expect(loop!.distanceMeters, 4000);
      expect(loop.polyline, hasLength(3));
    });

    test('sends the round-trip parameters', () async {
      respondWith(okBody([
        feature(lonLat: [
          [9.19, 45.46],
          [9.20, 45.47],
        ], distance: 10),
      ]));

      await RoutingService.fetchRoundTrip(origin,
          lengthMeters: 5000, points: 7, seed: 3);

      final sent = sentPayload();
      expect(sent['mode'], 'round_trip');
      expect(sent['lengthMeters'], 5000);
      expect(sent['points'], 7);
      expect(sent['seed'], 3);
      expect(sent.containsKey('destination'), isFalse,
          reason: 'a round trip has only a start');
    });

    test('a degenerate one-point loop is refused', () async {
      // Nothing downstream can use a "loop" that is a single point, and
      // returning it would be reported as a real candidate.
      respondWith(okBody([
        feature(lonLat: [
          [9.19, 45.46],
        ], distance: 0),
      ]));

      expect(
        await RoutingService.fetchRoundTrip(origin, lengthMeters: 4000),
        isNull,
      );
    });

    test('a 429 throws when the caller opts in', () async {
      respondWith({'status': 429, 'body': {}});

      expect(
        () => RoutingService.fetchRoundTrip(origin,
            lengthMeters: 4000, throwOnRateLimit: true),
        throwsA(isA<RoutingRateLimitedException>()),
      );
    });

    test('an unreachable backend yields null', () async {
      respondWithFailure();

      expect(
        await RoutingService.fetchRoundTrip(origin, lengthMeters: 4000),
        isNull,
      );
    });
  });

  group('matchDrawnPath', () {
    final stroke = [const LatLng(45.46, 9.19), const LatLng(45.47, 9.20)];

    test('a match returns the snapped geometry and distance', () async {
      respondWith({
        'status': 'ok',
        'polyline': [
          [45.46, 9.19],
          [45.47, 9.20],
        ],
        'distanceMeters': 1234.5,
      });

      final result = await RoutingService.matchDrawnPath(stroke);

      expect(result, isA<DrawMatchSuccess>());
      final ok = result as DrawMatchSuccess;
      expect(ok.distanceMeters, 1234.5);
      expect(ok.polyline, hasLength(2));
    });

    test('this endpoint returns [lat, lng] and is NOT flipped', () async {
      // Deliberately opposite to the GeoJSON paths above, which arrive as
      // [lon, lat] and are flipped. Two backends, two orders — pinned here
      // because the code looks identical at a glance and swapping either one
      // relocates the route rather than failing outright.
      respondWith({
        'status': 'ok',
        'polyline': [
          [45.4642, 9.19],
          [45.4700, 9.20],
        ],
        'distanceMeters': 10,
      });

      final ok =
          await RoutingService.matchDrawnPath(stroke) as DrawMatchSuccess;

      expect(ok.polyline.first.latitude, closeTo(45.4642, 1e-9));
      expect(ok.polyline.first.longitude, closeTo(9.19, 1e-9));
    });

    test('a single-point match is no match at all', () async {
      respondWith({
        'status': 'ok',
        'polyline': [
          [45.46, 9.19],
        ],
        'distanceMeters': 0,
      });

      final result = await RoutingService.matchDrawnPath(stroke);

      expect(result, isA<DrawMatchNoRoute>());
      expect((result as DrawMatchNoRoute).reason, 'empty geometry');
    });

    test('throttling carries the retry delay when the server sends one',
        () async {
      respondWith({'status': 'rate_limited', 'retryAfterSeconds': 30});

      final result = await RoutingService.matchDrawnPath(stroke);

      expect(result, isA<DrawMatchRateLimited>());
      expect((result as DrawMatchRateLimited).retryAfter,
          const Duration(seconds: 30));
    });

    test('throttling with no delay given is still throttling', () async {
      respondWith({'status': 'rate_limited'});

      final result = await RoutingService.matchDrawnPath(stroke);

      expect(result, isA<DrawMatchRateLimited>());
      expect((result as DrawMatchRateLimited).retryAfter, isNull);
    });

    test('an exhausted daily quota is distinct from throttling', () async {
      // Retrying a 429 can work; retrying a spent daily quota cannot, and the
      // UI is meant to say so rather than offer a retry.
      respondWith({'status': 'quota_exhausted'});

      expect(await RoutingService.matchDrawnPath(stroke),
          isA<DrawMatchQuotaExhausted>());
    });

    test('no walkable match carries the server\'s reason', () async {
      respondWith({'status': 'no_route', 'message': 'drawn over water'});

      final result = await RoutingService.matchDrawnPath(stroke);

      expect(result, isA<DrawMatchNoRoute>());
      expect((result as DrawMatchNoRoute).reason, 'drawn over water');
    });

    test('an unrecognised status is a service error', () async {
      respondWith({'status': 'something_new'});

      expect(await RoutingService.matchDrawnPath(stroke),
          isA<DrawMatchServiceError>());
    });

    test('an unreachable backend is a network error, not a service one',
        () async {
      respondWithFailure();

      expect(await RoutingService.matchDrawnPath(stroke),
          isA<DrawMatchNetworkError>());
    });

    test('a malformed success payload degrades to a network error', () async {
      respondWith({'status': 'ok', 'polyline': 'not a list'});

      expect(await RoutingService.matchDrawnPath(stroke),
          isA<DrawMatchNetworkError>());
    });

    test('sends the stroke as lat/lng pairs', () async {
      respondWith({'status': 'no_route'});

      await RoutingService.matchDrawnPath(stroke);

      final sent = sentPayload();
      expect(sent['points'], [
        {'lat': 45.46, 'lng': 9.19},
        {'lat': 45.47, 'lng': 9.20},
      ]);
    });
  });
}
