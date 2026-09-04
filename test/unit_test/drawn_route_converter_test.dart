import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mockito/mockito.dart';

import 'package:dash/services/drawn_route_converter.dart';
import 'package:dash/services/routing_service.dart';

import '../mocks.mocks.dart';

/// The converter turns a raw finger stroke into a route. It reaches the
/// backend only through `RoutingService.matchDrawnPath`, so it is driven here
/// by stubbing that one call — see `routing_service_test.dart` for the
/// transport itself.
void main() {
  late MockFirebaseFunctions functions;
  late MockHttpsCallable callable;

  setUp(() {
    functions = MockFirebaseFunctions();
    callable = MockHttpsCallable();
    when(functions.httpsCallable(any, options: anyNamed('options')))
        .thenReturn(callable);
    RoutingService.functionsOverride = functions;
  });

  tearDown(() => RoutingService.functionsOverride = null);

  void backendSays(Map<String, dynamic> data) {
    final result = MockHttpsCallableResult<dynamic>();
    when(result.data).thenReturn(data);
    when(callable.call(any)).thenAnswer((_) async => result);
  }

  void backendUnreachable() {
    when(callable.call(any)).thenAnswer((_) async => throw Exception('down'));
  }

  /// A straight stroke running north from Milan. `steps` points spaced
  /// `spacingMeters` apart — 0.000009 degrees of latitude is ~1 m.
  List<LatLng> stroke({int steps = 60, double spacingMeters = 5}) {
    const degreesPerMetre = 0.000009;
    return [
      for (var i = 0; i < steps; i++)
        LatLng(45.4642 + i * spacingMeters * degreesPerMetre, 9.19),
    ];
  }

  /// What the matcher hands back: a polyline of `steps` points, `spacing`
  /// metres apart, along the same line.
  Map<String, dynamic> matched({int steps = 60, double spacingMeters = 5}) {
    const degreesPerMetre = 0.000009;
    return {
      'status': 'ok',
      'polyline': [
        for (var i = 0; i < steps; i++)
          [45.4642 + i * spacingMeters * degreesPerMetre, 9.19],
      ],
      'distanceMeters': (steps - 1) * spacingMeters,
    };
  }

  group('strokes too small to be a route', () {
    test('a single tap produces nothing', () async {
      final result = await DrawnRouteConverter.convert(
          [const LatLng(45.4642, 9.19)]);

      expect(result, isA<DrawnRouteTooShort>());
    });

    test('an empty stroke produces nothing', () async {
      expect(await DrawnRouteConverter.convert([]), isA<DrawnRouteTooShort>());
    });

    test('a jitter shorter than the minimum is not a route', () async {
      // Well under `minStrokeLengthMeters` (20 m) — an accidental drag, not
      // a shape somebody meant to draw.
      final result = await DrawnRouteConverter.convert(
        stroke(steps: 3, spacingMeters: 2),
      );

      expect(result, isA<DrawnRouteTooShort>());
    });

    test('a too-short stroke never reaches the backend', () async {
      // The check is local on purpose: an accidental tap must not spend a
      // request from the shared quota.
      backendSays(matched());

      await DrawnRouteConverter.convert(stroke(steps: 3, spacingMeters: 2));

      verifyNever(callable.call(any));
    });

    test('a stroke just over the minimum is accepted', () async {
      backendSays(matched(steps: 10, spacingMeters: 5));

      final result = await DrawnRouteConverter.convert(
        stroke(steps: 10, spacingMeters: 5),
      );

      expect(result, isA<DrawnRouteSuccess>());
    });
  });

  group('a matched stroke', () {
    test('becomes waypoints and segments', () async {
      backendSays(matched());

      final result =
          await DrawnRouteConverter.convert(stroke()) as DrawnRouteSuccess;

      expect(result.segments, isNotEmpty);
      expect(result.waypoints.length, result.segments.length + 1,
          reason: 'each segment adds one waypoint to the starting one');
    });

    test('the waypoints are vertices of the matched route, not the stroke',
        () async {
      // The old version used raw finger samples, which left the start and
      // finish pins floating beside the road rather than on it.
      backendSays(matched(steps: 20, spacingMeters: 10));

      final result = await DrawnRouteConverter.convert(
          stroke(steps: 20, spacingMeters: 10)) as DrawnRouteSuccess;

      expect(result.waypoints.first.latitude, closeTo(45.4642, 1e-6));
    });

    test('consecutive segments share their junction vertex', () async {
      // Loop detection walks segment to segment; a gap between them would
      // break it.
      backendSays(matched(steps: 200, spacingMeters: 10));

      final result = await DrawnRouteConverter.convert(
          stroke(steps: 200, spacingMeters: 10)) as DrawnRouteSuccess;

      for (var i = 1; i < result.segments.length; i++) {
        expect(result.segments[i].polyline.first,
            result.segments[i - 1].polyline.last);
      }
    });

    test('the reported distance is the sum of the segments', () async {
      backendSays(matched(steps: 100, spacingMeters: 10));

      final result = await DrawnRouteConverter.convert(
          stroke(steps: 100, spacingMeters: 10)) as DrawnRouteSuccess;

      final summed = result.segments
          .fold<double>(0, (s, seg) => s + seg.distanceMeters);
      expect(result.distanceMeters, closeTo(summed, 0.001));
    });

    test('a long route is split into several segments', () async {
      // ~2 km at a 200 m target should be about ten.
      backendSays(matched(steps: 201, spacingMeters: 10));

      final result = await DrawnRouteConverter.convert(
          stroke(steps: 201, spacingMeters: 10)) as DrawnRouteSuccess;

      expect(result.segments.length, greaterThan(5));
    });

    test('a short route stays a single segment', () async {
      backendSays(matched(steps: 10, spacingMeters: 5));

      final result = await DrawnRouteConverter.convert(
          stroke(steps: 10, spacingMeters: 5)) as DrawnRouteSuccess;

      expect(result.segments, hasLength(1));
    });

    test('duplicate consecutive points are dropped', () async {
      backendSays({
        'status': 'ok',
        'polyline': [
          [45.4642, 9.19],
          [45.4642, 9.19],
          [45.4652, 9.19],
          [45.4652, 9.19],
        ],
        'distanceMeters': 120,
      });

      final result =
          await DrawnRouteConverter.convert(stroke()) as DrawnRouteSuccess;

      final all = result.segments.expand((s) => s.polyline).toList();
      for (var i = 1; i < all.length; i++) {
        expect(all[i], isNot(all[i - 1]));
      }
    });

    test('geometry that collapses to one point is no route', () async {
      backendSays({
        'status': 'ok',
        'polyline': [
          [45.4642, 9.19],
          [45.4642, 9.19],
        ],
        'distanceMeters': 0,
      });

      final result = await DrawnRouteConverter.convert(stroke());

      expect(result, isA<DrawnRouteFailure>());
      expect((result as DrawnRouteFailure).kind, DrawnRouteFailureKind.noRoute);
    });
  });

  group('an implausible match is refused', () {
    test('a route far longer than the stroke is rejected', () async {
      // The matcher had to invent a detour the user never drew — a stroke
      // across a river with the nearest bridge kilometres away. Accepting it
      // would make the headline distance a lie, which is the whole point of
      // the feature.
      backendSays(matched(steps: 60, spacingMeters: 100));

      final result =
          await DrawnRouteConverter.convert(stroke(steps: 60, spacingMeters: 5));

      expect(result, isA<DrawnRouteFailure>());
      final failure = result as DrawnRouteFailure;
      expect(failure.kind, DrawnRouteFailureKind.noRoute);
      expect(failure.detail, contains('implausibly longer'));
    });

    test('a route a little longer than the stroke is fine', () async {
      // Road snapping always adds some length; only a gross mismatch is a
      // problem.
      backendSays(matched(steps: 60, spacingMeters: 7));

      final result =
          await DrawnRouteConverter.convert(stroke(steps: 60, spacingMeters: 5));

      expect(result, isA<DrawnRouteSuccess>());
    });
  });

  group('failures are distinguished, not collapsed', () {
    test('throttling carries its retry delay', () async {
      backendSays({'status': 'rate_limited', 'retryAfterSeconds': 30});

      final result =
          await DrawnRouteConverter.convert(stroke()) as DrawnRouteFailure;

      expect(result.kind, DrawnRouteFailureKind.rateLimited);
      expect(result.retryAfter, const Duration(seconds: 30));
    });

    test('throttling is worth retrying', () async {
      backendSays({'status': 'rate_limited'});

      final result =
          await DrawnRouteConverter.convert(stroke()) as DrawnRouteFailure;

      expect(result.isRetryable, isTrue);
    });

    test('an exhausted daily quota is not worth retrying', () async {
      // The distinction the UI needs: retrying a 429 can work, retrying a
      // spent daily quota cannot until the window rolls over.
      backendSays({'status': 'quota_exhausted'});

      final result =
          await DrawnRouteConverter.convert(stroke()) as DrawnRouteFailure;

      expect(result.kind, DrawnRouteFailureKind.quotaExhausted);
      expect(result.isRetryable, isFalse);
    });

    test('no walkable match carries the reason given', () async {
      backendSays({'status': 'no_route', 'message': 'drawn over water'});

      final result =
          await DrawnRouteConverter.convert(stroke()) as DrawnRouteFailure;

      expect(result.kind, DrawnRouteFailureKind.noRoute);
      expect(result.detail, 'drawn over water');
    });

    test('an unreachable backend is a network failure', () async {
      backendUnreachable();

      final result =
          await DrawnRouteConverter.convert(stroke()) as DrawnRouteFailure;

      expect(result.kind, DrawnRouteFailureKind.network);
      expect(result.isRetryable, isTrue);
    });

    test('an unrecognised backend status is a service failure', () async {
      backendSays({'status': 'something_new'});

      final result =
          await DrawnRouteConverter.convert(stroke()) as DrawnRouteFailure;

      expect(result.kind, DrawnRouteFailureKind.serviceError);
    });
  });

  group('the upload payload', () {
    test('drops points that add no shape', () async {
      // Decimation exists to bound the payload, not to simplify the shape —
      // a matcher works better the more shape it sees, so only points closer
      // than 5 m to the previous kept one go.
      backendSays(matched());

      await DrawnRouteConverter.convert(stroke(steps: 400, spacingMeters: 1));

      final sent = verify(callable.call(captureAny)).captured.single
          as Map<String, dynamic>;
      final points = sent['points'] as List;
      expect(points.length, lessThan(400));
      expect(points.length, greaterThan(50),
          reason: 'dense enough for the matcher to see the shape');
    });

    test('keeps both ends of the stroke', () async {
      backendSays(matched());
      final drawn = stroke(steps: 400, spacingMeters: 1);

      await DrawnRouteConverter.convert(drawn);

      final sent = verify(callable.call(captureAny)).captured.single
          as Map<String, dynamic>;
      final points = sent['points'] as List;
      expect(points.first['lat'], closeTo(drawn.first.latitude, 1e-9));
      expect(points.last['lat'], closeTo(drawn.last.latitude, 1e-9));
    });
  });
}
