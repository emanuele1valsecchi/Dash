import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'package:dash/utils/geometry_utils.dart';

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

/// [path] resampled to [perSide] vertices per original segment — a stand-in
/// for a road-snapped ORS polyline, which arrives with metres between
/// vertices rather than one per corner. Vertex density is what decides
/// whether routeGuidance's segment window restricts anything, since the
/// window is measured in segments rather than metres.
List<LatLng> _densify(List<LatLng> path, {required int perSide}) {
  final out = <LatLng>[];
  for (int i = 0; i < path.length - 1; i++) {
    for (int k = 0; k < perSide; k++) {
      final t = k / perSide;
      out.add(LatLng(
        path[i].latitude + (path[i + 1].latitude - path[i].latitude) * t,
        path[i].longitude + (path[i + 1].longitude - path[i].longitude) * t,
      ));
    }
  }
  out.add(path.last);
  return out;
}

/// Feeds [position] through [GeometryUtils.routeGuidance] [fixes] times,
/// carrying the off-route debounce and hysteresis state forward the way
/// `RunSessionController` does — off-route is no longer decided by a single
/// call, so a test that wants a settled verdict has to ask for one.
RouteGuidance _settled(
  List<LatLng> route,
  LatLng position, {
  int fixes = 6,
  int? previousSegmentIndex,
}) {
  RouteGuidance? g;
  for (int i = 0; i < fixes; i++) {
    g = GeometryUtils.routeGuidance(
      route,
      position,
      previousSegmentIndex: previousSegmentIndex,
      wasOffRoute: g?.isOffRoute ?? false,
      previousOffRouteFixes: g?.offRouteFixes ?? 0,
    );
  }
  return g!;
}

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
      // ~130 m east of the loop's eastern edge, held long enough to settle.
      final guidance = _settled(_loop, const LatLng(45.4642, 9.1930));

      expect(guidance.isOffRoute, isTrue);
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
        final guidance = _settled(
          _loop,
          const LatLng(45.46465, 9.1930),
          previousSegmentIndex: 3,
        );

        expect(guidance.isOffRoute, isTrue);
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
        final guidance = _settled(_loop, const LatLng(45.4642, 9.1930));

        expect(guidance.isOffRoute, isTrue);
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

    group('off-route tolerance', () {
      // All measured against the loop's eastern edge (lng 9.19128), at a
      // latitude comfortably inside it so corners play no part.
      const onEdgeLat = 45.46465;
      LatLng eastOfEdge(double metres) =>
          LatLng(onEdgeLat, 9.19128 + metres / 78053);

      final wellOff = eastOfEdge(130);

      test('a single fix beyond the threshold is not enough', () {
        final guidance = GeometryUtils.routeGuidance(_loop, wellOff);

        expect(guidance!.offRouteMeters, greaterThan(100));
        expect(guidance.isOffRoute, isFalse);
        expect(guidance.offRouteFixes, 1);
      });

      test('a sustained deviation is flagged once the debounce elapses', () {
        expect(_settled(_loop, wellOff, fixes: 4).isOffRoute, isFalse);
        expect(_settled(_loop, wellOff, fixes: 5).isOffRoute, isTrue);
      });

      test('cutting a corner and rejoining never flags at all', () {
        // The roundabout case from the field: the planned route arcs round,
        // the runner crosses at the crosswalk, and a few fixes later is back
        // on the line — having gone nowhere wrong. The old instantaneous test
        // buzzed, spoke, and swung the arrow backwards for the duration.
        final excursion = <LatLng>[
          eastOfEdge(5),
          eastOfEdge(40),
          eastOfEdge(55),
          eastOfEdge(45),
          eastOfEdge(15),
          eastOfEdge(3),
        ];

        RouteGuidance? g;
        for (final p in excursion) {
          g = GeometryUtils.routeGuidance(
            _loop,
            p,
            previousSegmentIndex: 1,
            wasOffRoute: g?.isOffRoute ?? false,
            previousOffRouteFixes: g?.offRouteFixes ?? 0,
          );
          expect(g!.isOffRoute, isFalse,
              reason: 'flagged at ${g.offRouteMeters.round()} m off');
        }
      });

      test('a deviation a roundabout could explain is under the threshold',
          () {
        // 30 m is the sort of offset cutting across a roundabout produces
        // rather than following the planned arc. It used to exceed the flat
        // 25 m threshold outright, before the debounce even mattered.
        final guidance = _settled(_loop, eastOfEdge(30));

        expect(guidance.offRouteMeters, closeTo(30, 3));
        expect(guidance.isOffRoute, isFalse);
      });

      group('hysteresis', () {
        test('holds off-route between the two thresholds', () {
          // Settled off route at 130 m, then back to 30 m — inside the 35 m
          // it takes to be flagged, but still outside the 25 m it takes to be
          // forgiven, so the state must hold rather than flicker.
          final off = _settled(_loop, wellOff, previousSegmentIndex: 1);
          expect(off.isOffRoute, isTrue);

          final still = GeometryUtils.routeGuidance(
            _loop,
            eastOfEdge(30),
            previousSegmentIndex: 1,
            wasOffRoute: off.isOffRoute,
            previousOffRouteFixes: off.offRouteFixes,
          );

          expect(still!.isOffRoute, isTrue);
        });

        test('clears immediately once genuinely back on the line', () {
          final off = _settled(_loop, wellOff, previousSegmentIndex: 1);

          final back = GeometryUtils.routeGuidance(
            _loop,
            eastOfEdge(10),
            previousSegmentIndex: 1,
            wasOffRoute: off.isOffRoute,
            previousOffRouteFixes: off.offRouteFixes,
          );

          // No debounce on the way back — a runner who has rejoined the route
          // should be told so at once.
          expect(back!.isOffRoute, isFalse);
          expect(back.offRouteFixes, 0);
        });
      });
    });

    group('seeding the first match of a run', () {
      // 200 segments rather than four, so the seeded window genuinely excludes
      // the far side of the loop.
      final dense = _densify(_loop, perSide: 50);

      // Three metres north of the start line — one step, or plain GPS noise.
      // On this loop that point lies exactly on the *western* edge, which is
      // the final leg running south into the finish.
      const justOffTheStart = LatLng(45.46422713, 9.19000);

      test('unseeded, the full scan matches the finish and reports arrival',
          () {
        final guidance = GeometryUtils.routeGuidance(dense, justOffTheStart);

        // The bug as reported from the field: the runner has not gone
        // anywhere, but the nearest point on the route is the final leg, so
        // nothing is left to run and the card says "Route complete".
        expect(guidance!.segmentIndex, greaterThan(150));
        expect(guidance.distanceRemainingMeters, lessThan(20));
      });

      test('seeded at segment 0, the whole loop is still ahead', () {
        final guidance = GeometryUtils.routeGuidance(
          dense,
          justOffTheStart,
          previousSegmentIndex: 0,
        );

        expect(guidance!.segmentIndex, lessThan(40));
        expect(guidance.distanceRemainingMeters, closeTo(400, 25));
      });

      test('seeding costs nothing for a runner who joins mid-route', () {
        // The NE corner is far outside the seeded window, so the
        // out-of-threshold fallback must re-scan the whole route — leaving
        // the seed with no effect at all in the one case where it would be
        // wrong to have one.
        final guidance = GeometryUtils.routeGuidance(
          dense,
          _loop[2],
          previousSegmentIndex: 0,
        );

        expect(guidance!.isOffRoute, isFalse);
        expect(guidance.distanceRemainingMeters, closeTo(200, 25));
      });
    });
  });
}
