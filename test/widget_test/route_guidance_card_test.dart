import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'package:dash/utils/geometry_utils.dart';
import 'package:dash/utils/route_progress.dart';
import 'package:dash/widgets/run/route_guidance_card.dart';

import '../helpers/pump_app.dart';

/// The card's five states are chosen from `guidance` + `progress` + `heading`.
/// Everything here drives that choice; the arithmetic behind the numbers is
/// `GeometryUtils.routeGuidance`'s own, tested separately.
RouteGuidance _guidance({
  double targetBearingDegrees = 90,
  double offRouteMeters = 3,
  bool isOffRoute = false,
  int offRouteFixes = 0,
  double distanceRemainingMeters = 1200,
  double? distanceToTurnMeters,
  double? turnAngleDegrees,
  int segmentIndex = 0,
}) {
  return RouteGuidance(
    targetBearingDegrees: targetBearingDegrees,
    offRouteMeters: offRouteMeters,
    isOffRoute: isOffRoute,
    offRouteFixes: offRouteFixes,
    distanceRemainingMeters: distanceRemainingMeters,
    distanceToTurnMeters: distanceToTurnMeters,
    turnAngleDegrees: turnAngleDegrees,
    anchor: const LatLng(45.4642, 9.1900),
    segmentIndex: segmentIndex,
  );
}

void main() {
  Future<void> pumpCard(
    WidgetTester tester, {
    required RouteGuidance guidance,
    RouteProgress? progress,
    double? heading = 90,
    bool isVoiceEnabled = true,
    VoidCallback? onToggleVoice,
  }) {
    return pumpDashWidget(
      tester,
      RouteGuidanceCard(
        guidance: guidance,
        progress: progress,
        heading: heading,
        isVoiceEnabled: isVoiceEnabled,
        onToggleVoice: onToggleVoice ?? () {},
      ),
    );
  }

  group('following the route', () {
    testWidgets('names the next turn and how far is left', (tester) async {
      await pumpCard(
        tester,
        guidance: _guidance(
          distanceToTurnMeters: 80,
          turnAngleDegrees: -90,
          distanceRemainingMeters: 1200,
        ),
      );

      expect(find.text('Turn left in 80 m'), findsOneWidget);
      expect(find.text('1.20 km to go'), findsOneWidget);
    });

    testWidgets('a gentle turn is a bear, not a turn', (tester) async {
      // The two split at 70 degrees: anything shallower reads as a bend in the
      // road rather than an instruction to change street.
      await pumpCard(
        tester,
        guidance: _guidance(distanceToTurnMeters: 80, turnAngleDegrees: 40),
      );

      expect(find.text('Bear right in 80 m'), findsOneWidget);
    });

    testWidgets('a turn underfoot says "now" rather than a distance',
        (tester) async {
      await pumpCard(
        tester,
        guidance: _guidance(distanceToTurnMeters: 9, turnAngleDegrees: -90),
      );

      expect(find.text('Turn left now'), findsOneWidget);
    });

    testWidgets('no turn in range reads as continue straight', (tester) async {
      await pumpCard(tester, guidance: _guidance());

      expect(find.text('Continue straight'), findsOneWidget);
    });

    testWidgets('the arrow points where the runner should go', (tester) async {
      await pumpCard(tester, guidance: _guidance());

      expect(find.byIcon(Icons.navigation_rounded), findsOneWidget);
    });
  });

  group('no heading yet', () {
    // Below the minimum speed, course-over-ground is sensor noise. Pointing
    // confidently nowhere is worse than admitting it.
    testWidgets('drops to a neutral bearing state', (tester) async {
      await pumpCard(tester, guidance: _guidance(), heading: null);

      expect(find.text('Getting your bearing'), findsOneWidget);
      expect(find.textContaining('start moving'), findsOneWidget);
    });

    testWidgets('shows the compass glyph, not a direction arrow',
        (tester) async {
      await pumpCard(tester, guidance: _guidance(), heading: null);

      expect(find.byIcon(Icons.explore_outlined), findsOneWidget);
      expect(find.byIcon(Icons.navigation_rounded), findsNothing);
    });
  });

  group('off route', () {
    testWidgets('says how far away and to follow the arrow back',
        (tester) async {
      await pumpCard(
        tester,
        guidance: _guidance(isOffRoute: true, offRouteMeters: 62),
      );

      expect(find.text('Off route'), findsOneWidget);
      expect(find.textContaining('62 m away'), findsOneWidget);
    });

    testWidgets('takes priority over being near the finish', (tester) async {
      // A runner 60 m off the line beside the finish has not arrived, however
      // little route distance is nominally left.
      await pumpCard(
        tester,
        guidance: _guidance(
          isOffRoute: true,
          offRouteMeters: 62,
          distanceRemainingMeters: 2,
        ),
        progress: const RouteProgress(reached: 6, total: 6),
      );

      expect(find.text('Off route'), findsOneWidget);
      expect(find.text('Route complete'), findsNothing);
    });
  });

  group('arrival', () {
    testWidgets('is announced once the finish is reached and covered',
        (tester) async {
      await pumpCard(
        tester,
        guidance: _guidance(distanceRemainingMeters: 5),
        progress: const RouteProgress(reached: 6, total: 6),
      );

      expect(find.text('Route complete'), findsOneWidget);
      expect(find.byIcon(Icons.flag_rounded), findsOneWidget);
    });

    testWidgets('is withheld when checkpoints were skipped', (tester) async {
      // The field-test bug: on a loop the start and finish are the same place,
      // so proximity alone said "Route complete" before the runner had moved.
      await pumpCard(
        tester,
        guidance: _guidance(distanceRemainingMeters: 5),
        progress: const RouteProgress(reached: 1, total: 6),
      );

      expect(find.text('Route complete'), findsNothing);
      expect(find.text('Keep going'), findsOneWidget);
      expect(find.textContaining('5 of 6 checkpoints missed'), findsOneWidget);
    });

    testWidgets('falls back to proximity when there is no progress to track',
        (tester) async {
      // A route too short to place checkpoints on has none to skip.
      await pumpCard(
        tester,
        guidance: _guidance(distanceRemainingMeters: 5),
        progress: null,
      );

      expect(find.text('Route complete'), findsOneWidget);
    });

    testWidgets('still guides while short of the arrival radius',
        (tester) async {
      await pumpCard(
        tester,
        guidance: _guidance(distanceRemainingMeters: 40),
        progress: const RouteProgress(reached: 6, total: 6),
      );

      expect(find.text('Route complete'), findsNothing);
      expect(find.text('Continue straight'), findsOneWidget);
    });
  });

  group('voice toggle', () {
    testWidgets('shows the muted glyph when voice is off', (tester) async {
      await pumpCard(
        tester,
        guidance: _guidance(),
        isVoiceEnabled: false,
      );

      expect(find.byIcon(Icons.volume_off_rounded), findsOneWidget);
    });

    testWidgets('reports a tap to the caller', (tester) async {
      var taps = 0;
      await pumpCard(
        tester,
        guidance: _guidance(),
        onToggleVoice: () => taps++,
      );

      await tester.tap(find.byIcon(Icons.volume_up_rounded));

      expect(taps, 1);
    });
  });
}
