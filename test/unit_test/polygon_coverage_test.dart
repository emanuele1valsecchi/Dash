import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'package:dash/utils/geometry_utils.dart';

/// ~100 m grid squares just east of Milano centre, addressed in the same
/// cardinal shorthand used to report the bug this helper exists to fix: x runs
/// east, y runs north, one unit ≈ 100 m.
const _startLat = 45.4642, _startLng = 9.1900;
const _dLat = 0.000905, _dLng = 0.001281;

LatLng _at(double x, double y) =>
    LatLng(_startLat + _dLat * y, _startLng + _dLng * x);

/// The axis-aligned square with corners (x0,y0) and (x1,y1).
List<LatLng> _square(double x0, double y0, double x1, double y1) => [
      _at(x0, y0),
      _at(x1, y0),
      _at(x1, y1),
      _at(x0, y1),
      _at(x0, y0),
    ];

void main() {
  group('GeometryUtils.isPointInPolygon', () {
    final square = _square(0, 0, 1, 1);

    test('accepts an interior point and rejects an exterior one', () {
      expect(GeometryUtils.isPointInPolygon(_at(0.5, 0.5), square), isTrue);
      expect(GeometryUtils.isPointInPolygon(_at(1.5, 0.5), square), isFalse);
    });

    test('rejects anything for a degenerate polygon', () {
      expect(
        GeometryUtils.isPointInPolygon(_at(0.5, 0.5), [_at(0, 0), _at(1, 1)]),
        isFalse,
      );
    });
  });

  group('GeometryUtils.polygonCoversPolygon', () {
    // The reported case. Square A is pinned first, then square B sharing A's
    // eastern side. Neither covers the other — they are neighbours — but every
    // point of the street between them lies on both boundaries at once, which
    // is what made a naive vertex-inside test unable to tell this apart from
    // one square drawn around the other.
    final a = _square(0, 0, 1, 1);
    final b = _square(1, 0, 2, 1);

    test('neighbours sharing a side do not cover each other', () {
      expect(GeometryUtils.polygonCoversPolygon(b, a), isFalse);
      expect(GeometryUtils.polygonCoversPolygon(a, b), isFalse);
    });

    test('a loop drawn around another covers it', () {
      final big = _square(-1, -1, 2, 2);

      expect(GeometryUtils.polygonCoversPolygon(big, a), isTrue);
      // ...and emphatically not the other way round.
      expect(GeometryUtils.polygonCoversPolygon(a, big), isFalse);
    });

    test('a loop covers itself', () {
      // The same block run twice: the two boundaries coincide, so every
      // sample sits exactly on the other polygon's edge — the case the
      // boundary tolerance exists for.
      expect(GeometryUtils.polygonCoversPolygon(a, _square(0, 0, 1, 1)),
          isTrue);
    });

    test('a re-run of the same block still covers it despite GPS noise', () {
      // Same square, every corner nudged ~10 m — well inside the tolerance,
      // but far enough that an exact-boundary test would miss.
      final noisy = [
        _at(0.02, -0.02),
        _at(1.02, 0.02),
        _at(0.98, 1.02),
        _at(-0.02, 0.98),
        _at(0.02, -0.02),
      ];

      expect(GeometryUtils.polygonCoversPolygon(a, noisy), isTrue);
    });

    test('disjoint blocks do not cover each other', () {
      expect(
        GeometryUtils.polygonCoversPolygon(a, _square(5, 5, 6, 6)),
        isFalse,
      );
    });

    test('a partial overlap is not treated as coverage', () {
      // Half of this square sticks out beyond A. Keeping both is the
      // deliberate choice: the bug being fixed was ground being silently
      // deleted, so anything short of real containment errs toward keeping
      // the claim and letting the server union same-owner areas.
      expect(
        GeometryUtils.polygonCoversPolygon(a, _square(0.5, 0, 1.5, 1)),
        isFalse,
      );
    });

    test('degenerate polygons cover nothing', () {
      expect(GeometryUtils.polygonCoversPolygon(a, [_at(0, 0)]), isFalse);
      expect(GeometryUtils.polygonCoversPolygon([_at(0, 0)], a), isFalse);
    });
  });
}
