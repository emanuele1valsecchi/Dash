import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'package:dash_application/utils/geometry_utils.dart';

/// A ~100 m square loop just east of Milano centre, closing back on its own
/// start point — the shape Dash's whole territory mechanic is built around,
/// and the case that breaks naive nearest-point route matching.
///
/// Segment 0: start → east   1: east → north
/// Segment 2: north → west   3: west → back to start
final _loop = <LatLng>[
  const LatLng(45.4642, 9.19000), // 0  SW / start / finish
  const LatLng(45.4642, 9.19128), // 1  SE
  const LatLng(45.4651, 9.19128), // 2  NE
  const LatLng(45.4651, 9.19000), // 3  NW
  const LatLng(45.4642, 9.19000), // 4  back to 0
];

void main() {
  group('GeometryUtils.routeGuidance', () {
    test('returns null for a route too short to have a direction', () {
      expect(GeometryUtils.routeGuidance(const [], const LatLng(45.46, 9.19)),
          isNull);
      expect(
        GeometryUtils.routeGuidance(
          const [LatLng(45.46, 9.19)],
          const LatLng(45.46, 9.19),
        ),
        isNull,
      );
    });

    test('points along the route when the runner is on it', () {
      // Two-point route heading due north; runner sitting at its start.
      final guidance = GeometryUtils.routeGuidance(
        const [LatLng(45.4642, 9.19), LatLng(45.4700, 9.19)],
        const LatLng(45.4642, 9.19),
      );

      expect(guidance, isNotNull);
      expect(guidance!.isOffRoute, isFalse);
      expect(guidance.offRouteMeters, lessThan(1));
      expect(guidance.targetBearingDegrees, closeTo(0, 1)); // north
    });

    test('flags off-route and steers back toward the route', () {
      // ~130 m east of the loop's eastern edge.
      final guidance = GeometryUtils.routeGuidance(
        _loop,
        const LatLng(45.4642, 9.1930),
      );

      expect(guidance, isNotNull);
      expect(guidance!.isOffRoute, isTrue);
      expect(guidance.offRouteMeters, greaterThan(100));
      // Nearest point on the route is due west, so that is where it aims —
      // back onto the line, not further along it.
      expect(guidance.targetBearingDegrees, closeTo(270, 2));
    });

    test('reports remaining distance along the rest of the route', () {
      final atStart = GeometryUtils.routeGuidance(_loop, _loop.first);
      final atNorthEast = GeometryUtils.routeGuidance(
        _loop,
        _loop[2],
        previousSegmentIndex: 1,
      );

      // Whole perimeter is roughly 400 m; two sides remain from the NE corner.
      expect(atStart!.distanceRemainingMeters, closeTo(400, 25));
      expect(atNorthEast!.distanceRemainingMeters, closeTo(200, 25));
    });

    group('closed-loop re-acquisition', () {
      // A runner finishing a lap stands on the loop's start point again. That
      // single position is genuinely on both segment 0 (about to set off) and
      // segment 3 (just arriving) — only the previous index can tell them
      // apart, which is exactly why routeGuidance takes the hint.
      final finishing = _loop.first;

      test('without the hint it wrongly re-matches the first segment', () {
        final guidance = GeometryUtils.routeGuidance(_loop, finishing);

        expect(guidance!.segmentIndex, 0);
        // Told to head east — i.e. to run the entire loop a second time.
        expect(guidance.targetBearingDegrees, closeTo(90, 2));
        expect(guidance.distanceRemainingMeters, closeTo(400, 25));
      });

      test('with the hint it stays on the final segment', () {
        final guidance = GeometryUtils.routeGuidance(
          _loop,
          finishing,
          previousSegmentIndex: 3,
        );

        expect(guidance!.segmentIndex, 3);
        // Still travelling south into the finish, with nothing left to run.
        expect(guidance.targetBearingDegrees, closeTo(180, 2));
        expect(guidance.distanceRemainingMeters, lessThan(1));
      });

      test('a stale hint is abandoned once the runner is genuinely off route',
          () {
        // Hint says "late in the loop", but the runner is far off the east
        // edge — the windowed search must give up and re-scan the whole route.
        final guidance = GeometryUtils.routeGuidance(
          _loop,
          const LatLng(45.46465, 9.1930),
          previousSegmentIndex: 3,
        );

        expect(guidance!.isOffRoute, isTrue);
        // Re-acquired against the eastern edge (segment 1), not left stuck on
        // the westward window the hint pointed at.
        expect(guidance.segmentIndex, 1);
      });
    });

    group('next-turn detection', () {
      test('reports distance and side of an upcoming right turn', () {
        // Runner at the loop's start, heading east; the loop turns left
        // (north) at the SE corner ~100 m ahead.
        final guidance = GeometryUtils.routeGuidance(_loop, _loop.first);

        expect(guidance!.distanceToTurnMeters, isNotNull);
        // Detected slightly before the corner itself — the bearing window
        // starts diverging as it begins to span the turn.
        expect(guidance.distanceToTurnMeters, closeTo(85, 25));
        // Going east then north is a left turn: negative.
        expect(guidance.turnAngleDegrees, isNotNull);
        expect(guidance.turnAngleDegrees, lessThan(0));
        expect(guidance.turnAngleDegrees!.abs(), closeTo(90, 15));
      });

      test('reports no turn on a straight route', () {
        final straight = <LatLng>[
          for (int i = 0; i < 80; i++) LatLng(45.4642 + i * 0.00005, 9.19),
        ];

        final guidance = GeometryUtils.routeGuidance(straight, straight.first);

        expect(guidance!.distanceToTurnMeters, isNull);
        expect(guidance.turnAngleDegrees, isNull);
      });

      test('detects a corner rounded by many small vertex steps', () {
        // A road-snapped polyline turns through a dozen vertices, none of
        // which individually looks like a turn — the whole reason detection
        // samples by distance rather than by vertex.
        final rounded = <LatLng>[
          for (int i = 0; i < 30; i++) LatLng(45.4642, 9.19 + i * 0.00006),
          for (int i = 1; i <= 12; i++)
            LatLng(45.4642 + i * 0.000015, 9.19180 + i * 0.000015),
          for (int i = 1; i < 30; i++) LatLng(45.46438 + i * 0.00005, 9.19198),
        ];

        final guidance = GeometryUtils.routeGuidance(rounded, rounded.first);

        expect(guidance!.distanceToTurnMeters, isNotNull);
        expect(guidance.turnAngleDegrees, isNotNull);
        expect(guidance.turnAngleDegrees, lessThan(0)); // east → north
      });

      test('reports no turn while off route', () {
        final guidance = GeometryUtils.routeGuidance(
          _loop,
          const LatLng(45.4642, 9.1930),
        );

        expect(guidance!.isOffRoute, isTrue);
        expect(guidance.distanceToTurnMeters, isNull);
      });
    });

    test('lookahead smooths past densely-sampled vertices', () {
      // A road-snapped polyline can put vertices a metre or two apart. Aiming
      // at the next *vertex* would make the arrow jitter; aiming 30 m ahead
      // should still read as due north.
      final dense = <LatLng>[
        for (int i = 0; i < 60; i++) LatLng(45.4642 + i * 0.00002, 9.19),
      ];

      final guidance = GeometryUtils.routeGuidance(dense, dense.first);

      expect(guidance!.targetBearingDegrees, closeTo(0, 1));
      expect(guidance.isOffRoute, isFalse);
    });
  });
}
