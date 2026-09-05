import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'package:dash/utils/geometry_utils.dart';

/// `smoothPolyline` is cosmetic — it decides how a route *line* is drawn, and
/// is deliberately not used for any distance or loop-closure maths. What
/// matters is therefore not the exact curve but the two properties the
/// drawn line depends on: it must pass through every real point, and it must
/// not wander off the routed path between them.
void main() {
  const a = LatLng(45.4642, 9.1900);

  LatLng at(double north, double east) =>
      LatLng(a.latitude + north * 0.001, a.longitude + east * 0.001);

  group('inputs too short to curve', () {
    test('an empty list is returned as-is', () {
      expect(GeometryUtils.smoothPolyline([]), isEmpty);
    });

    test('a single point is returned as-is', () {
      final pts = [at(0, 0)];

      expect(GeometryUtils.smoothPolyline(pts), pts);
    });

    test('a straight two-point line has nothing to curve', () {
      // Two points describe one straight segment; there is no corner.
      final pts = [at(0, 0), at(0, 1)];

      expect(GeometryUtils.smoothPolyline(pts), pts);
    });
  });

  group('the smoothed line', () {
    final corner = [at(0, 0), at(0, 1), at(1, 1)];

    test('starts and ends exactly where the route does', () {
      // Anything else would visibly detach the line from its start and
      // finish pins.
      final smooth = GeometryUtils.smoothPolyline(corner);

      expect(smooth.first, corner.first);
      expect(smooth.last.latitude, closeTo(corner.last.latitude, 1e-9));
      expect(smooth.last.longitude, closeTo(corner.last.longitude, 1e-9));
    });

    test('passes through every original point', () {
      // Catmull-Rom interpolates rather than approximates: the curve is
      // drawn *through* the routed vertices, so the line never cuts a corner
      // the route actually goes round.
      final smooth = GeometryUtils.smoothPolyline(corner);

      for (final p in corner) {
        final hit = smooth.any((s) =>
            (s.latitude - p.latitude).abs() < 1e-9 &&
            (s.longitude - p.longitude).abs() < 1e-9);
        expect(hit, isTrue, reason: 'original point $p is not on the curve');
      }
    });

    test('adds interpolated points between them', () {
      final smooth = GeometryUtils.smoothPolyline(corner);

      expect(smooth.length, greaterThan(corner.length));
    });

    test('more subdivisions means a denser line', () {
      final coarse = GeometryUtils.smoothPolyline(corner, subdivisions: 2);
      final fine = GeometryUtils.smoothPolyline(corner, subdivisions: 12);

      expect(fine.length, greaterThan(coarse.length));
    });

    test('one subdivision degenerates to the original vertices', () {
      final smooth = GeometryUtils.smoothPolyline(corner, subdivisions: 1);

      expect(smooth.length, corner.length);
    });

    test('stays within the neighbourhood of the route', () {
      // A curve that overshoots would draw the line through buildings the
      // route goes around. Centripetal parametrisation is what keeps the
      // overshoot bounded; a uniform one can loop.
      final smooth = GeometryUtils.smoothPolyline(corner);

      final minLat = corner.map((p) => p.latitude).reduce((x, y) => x < y ? x : y);
      final maxLat = corner.map((p) => p.latitude).reduce((x, y) => x > y ? x : y);
      final span = maxLat - minLat;
      for (final s in smooth) {
        expect(s.latitude, greaterThan(minLat - span));
        expect(s.latitude, lessThan(maxLat + span));
      }
    });

    test('a straight run stays straight', () {
      // Smoothing collinear points must not introduce a wobble.
      final straight = [at(0, 0), at(0, 1), at(0, 2), at(0, 3)];

      final smooth = GeometryUtils.smoothPolyline(straight);

      for (final s in smooth) {
        expect(s.latitude, closeTo(a.latitude, 1e-9));
      }
    });

    test('unevenly spaced points do not produce a self-intersecting loop',
        () {
      // The case centripetal parametrisation exists for: road-snapped ORS
      // polylines constantly mix dense nodes on a curve with sparse ones on
      // a straight stretch. A uniform Catmull-Rom loops here.
      final uneven = [
        at(0, 0),
        at(0, 0.02),
        at(0, 0.04),
        at(0.5, 3),
        at(1, 6),
      ];

      final smooth = GeometryUtils.smoothPolyline(uneven);

      // Monotonic in longitude, as the input is — a loop would go backwards.
      for (var i = 1; i < smooth.length; i++) {
        expect(smooth[i].longitude,
            greaterThanOrEqualTo(smooth[i - 1].longitude - 1e-9),
            reason: 'the curve doubled back at index $i');
      }
    });

    test('duplicate consecutive points do not divide by zero', () {
      // The knot spacing has a floor for exactly this; without it a repeated
      // vertex produces NaN and the line vanishes.
      final dupes = [at(0, 0), at(0, 0), at(0, 1), at(1, 1)];

      final smooth = GeometryUtils.smoothPolyline(dupes);

      for (final s in smooth) {
        expect(s.latitude.isFinite, isTrue);
        expect(s.longitude.isFinite, isTrue);
      }
    });
  });
}
