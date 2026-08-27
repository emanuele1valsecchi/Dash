import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'package:dash/utils/geometry_utils.dart';

/// Metres-per-degree at Milano's latitude, used to build test fixtures whose
/// deviations are expressed in real metres rather than raw degrees.
const _mPerDegLat = 110540.0;
final _mPerDegLng = 111320.0 * cos(45.4642 * pi / 180);

LatLng _offset(LatLng from, {double northM = 0, double eastM = 0}) => LatLng(
      from.latitude + northM / _mPerDegLat,
      from.longitude + eastM / _mPerDegLng,
    );

const _origin = LatLng(45.4642, 9.19000);

void main() {
  group('GeometryUtils.simplifyPolyline', () {
    test('returns lists too short to simplify unchanged', () {
      expect(GeometryUtils.simplifyPolyline(const []), isEmpty);

      const single = [_origin];
      expect(GeometryUtils.simplifyPolyline(single), equals(single));

      final pair = [_origin, _offset(_origin, eastM: 100)];
      expect(GeometryUtils.simplifyPolyline(pair), equals(pair));
    });

    test('collapses a dense straight line to just its endpoints', () {
      // 200 points every 2m along a straight line — the exact shape the live
      // GPS breadcrumb filter produces on a straight stretch of road.
      final straight = List<LatLng>.generate(
        200,
        (i) => _offset(_origin, eastM: i * 2.0),
      );

      final simplified = GeometryUtils.simplifyPolyline(straight);

      expect(simplified.length, 2);
      expect(simplified.first, straight.first);
      expect(simplified.last, straight.last);
    });

    test('keeps a corner that deviates well beyond the tolerance', () {
      final corner = [
        _origin,
        _offset(_origin, eastM: 100),
        _offset(_origin, eastM: 100, northM: 100),
      ];

      expect(GeometryUtils.simplifyPolyline(corner).length, 3);
    });

    test('drops a wobble smaller than the tolerance but keeps a real turn',
        () {
      final path = [
        _origin,
        // 1m off the straight line — GPS noise, below the 5m default.
        _offset(_origin, eastM: 50, northM: 1),
        _offset(_origin, eastM: 100),
        // 40m off — a real turn.
        _offset(_origin, eastM: 150, northM: 40),
        _offset(_origin, eastM: 200),
      ];

      final simplified = GeometryUtils.simplifyPolyline(path);

      expect(simplified, contains(path[3]));
      expect(simplified, isNot(contains(path[1])));
    });

    test('always preserves first and last point, which territory keys off',
        () {
      final loop = <LatLng>[
        _origin,
        _offset(_origin, eastM: 100),
        _offset(_origin, eastM: 100, northM: 100),
        _offset(_origin, northM: 100),
        _origin,
      ];

      final simplified = GeometryUtils.simplifyPolyline(loop);

      expect(simplified.first, loop.first);
      expect(simplified.last, loop.last);
    });

    test('never grows a path and preserves original ordering', () {
      final rnd = Random(42);
      final noisy = List<LatLng>.generate(
        500,
        (i) => _offset(
          _origin,
          eastM: i * 2.0,
          northM: (rnd.nextDouble() - 0.5) * 6,
        ),
      );

      final simplified = GeometryUtils.simplifyPolyline(noisy);

      expect(simplified.length, lessThanOrEqualTo(noisy.length));

      var searchFrom = 0;
      for (final p in simplified) {
        final idx = noisy.indexOf(p, searchFrom);
        expect(idx, greaterThanOrEqualTo(searchFrom));
        searchFrom = idx;
      }
    });

    test('cuts a realistic 2m-resolution GPS trail by several times over', () {
      // A gently curving 2km run sampled every 2m, plus GPS-scale noise —
      // the real input this exists for.
      final rnd = Random(7);
      final trail = List<LatLng>.generate(1000, (i) {
        final t = i / 1000 * pi;
        return _offset(
          _origin,
          eastM: i * 2.0,
          northM: sin(t) * 300 + (rnd.nextDouble() - 0.5) * 4,
        );
      });

      final simplified = GeometryUtils.simplifyPolyline(trail);

      expect(simplified.length * 5, lessThan(trail.length));
    });

    test('a larger tolerance never keeps more points than a smaller one', () {
      final rnd = Random(3);
      final trail = List<LatLng>.generate(
        300,
        (i) => _offset(
          _origin,
          eastM: i * 2.0,
          northM: (rnd.nextDouble() - 0.5) * 30,
        ),
      );

      final tight = GeometryUtils.simplifyPolyline(trail, toleranceMeters: 2);
      final loose = GeometryUtils.simplifyPolyline(trail, toleranceMeters: 20);

      expect(loose.length, lessThanOrEqualTo(tight.length));
    });

    test('a zero or negative tolerance leaves the path untouched', () {
      final trail = List<LatLng>.generate(
        50,
        (i) => _offset(_origin, eastM: i * 2.0),
      );

      expect(
        GeometryUtils.simplifyPolyline(trail, toleranceMeters: 0),
        equals(trail),
      );
    });

    test('handles tens of thousands of points without a stack overflow', () {
      // Douglas-Peucker recursion depth degrades to O(n) on a steadily
      // curving path, which is why the implementation uses an explicit
      // stack — a marathon at 2m resolution is ~21k points.
      final trail = List<LatLng>.generate(25000, (i) {
        final t = i / 25000 * 2 * pi;
        return _offset(_origin, eastM: cos(t) * 2000, northM: sin(t) * 2000);
      });

      expect(GeometryUtils.simplifyPolyline(trail).length,
          lessThan(trail.length));
    });
  });
}
