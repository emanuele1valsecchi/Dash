import 'package:dash_watch_protocol/dash_watch_protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dash_wear/watch_theme.dart';
import 'package:dash_wear/widgets/controls_page.dart';
import 'package:dash_wear/widgets/metric.dart';
import 'package:dash_wear/widgets/metrics_page.dart';
import 'package:dash_wear/widgets/navigation_page.dart';
import 'package:dash_wear/widgets/territory_page.dart';

/// The three pages of the watch face, and the tile they are built from.
///
/// These are pure presentation — they take a `RunStats` and draw it — but the
/// decisions inside them are the ones a runner reads at arm's length while
/// moving, and several are easy to get subtly wrong: which way an arrow
/// points, whether a turn says "bear" or "turn", whether a paused clock looks
/// paused. Ambient mode matters as much: a Wear OS watch spends most of a run
/// in it, so a page that only works in full colour is a page that mostly does
/// not work.
void main() {
  /// Deliberately larger than a real watch face.
  ///
  /// A 1.4" Wear screen is about 220 dp, and these pages fit one at real font
  /// metrics — but the test font is roughly 1 em per character, close to
  /// double the real width, so laying them out at 220 dp overflows for
  /// reasons that have nothing to do with the widgets. See TEST_NOTES 1.2 on
  /// the phone side, where the same trap produced two "overflow bugs" that
  /// were not real. Nothing here can therefore claim anything about fit on a
  /// real device; that is a job for a device screenshot, not a widget test.
  const watchSurface = Size(420, 420);

  Future<void> pumpPage(WidgetTester tester, Widget page) async {
    await tester.binding.setSurfaceSize(watchSurface);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(backgroundColor: Colors.black, body: page)),
    );
    await tester.pump();
  }

  /// The colour a `Metric`'s big number is actually drawn in.
  Color valueColourOf(WidgetTester tester, String value) => tester
      .widget<Text>(find.descendant(
        of: find.byType(Metric),
        matching: find.text(value),
      ))
      .style!
      .color!;

  group('a metric tile', () {
    testWidgets('shows its number and its unit separately', (tester) async {
      // Two `Text`s, not one string: the digits are the part being read at
      // arm's length, and the unit must not compete for that space.
      await pumpPage(tester, const Metric(value: '3.42', label: 'KM'));

      expect(find.text('3.42'), findsOneWidget);
      expect(find.text('KM'), findsOneWidget);
    });

    testWidgets('takes an accent colour when asked', (tester) async {
      await pumpPage(tester, const Metric(
        value: '2',
        label: 'LOOPS',
        valueColor: WatchTheme.accent,
      ));

      expect(valueColourOf(tester, '2'), WatchTheme.accent);
    });

    testWidgets('drops every accent in ambient mode', (tester) async {
      // Ambient is one flat colour by design — an accent burns power on an
      // always-on display and, on some panels, burns in.
      await pumpPage(tester, const Metric(
        value: '2',
        label: 'LOOPS',
        valueColor: WatchTheme.accent,
        ambient: true,
      ));

      expect(valueColourOf(tester, '2'), WatchTheme.ambientText);
    });
  });

  group('the metrics page', () {
    RunStats running({
      Duration elapsed = const Duration(minutes: 24, seconds: 30),
      RunPhase phase = RunPhase.running,
      int loops = 0,
      int? bpm,
    }) =>
        RunStats(
          phase: phase,
          elapsed: elapsed,
          distanceMeters: 4200,
          paceMinPerKm: 5.5,
          heartRateBpm: bpm,
          loopsCompleted: loops,
        );

    testWidgets('leads with the clock', (tester) async {
      await pumpPage(tester,
          MetricsPage(stats: running(), ambient: false));

      expect(find.text('TIME'), findsOneWidget);
      expect(find.text('24:30'), findsOneWidget);
    });

    testWidgets('says PAUSED in place of TIME when it is', (tester) async {
      // The clock stops either way; without the label a paused run and a
      // runner standing still look identical.
      await pumpPage(
        tester,
        MetricsPage(stats: running(phase: RunPhase.paused), ambient: false),
      );

      expect(find.text('PAUSED'), findsOneWidget);
      expect(find.text('TIME'), findsNothing);
    });

    testWidgets('a paused clock is warned in colour too', (tester) async {
      await pumpPage(
        tester,
        MetricsPage(stats: running(phase: RunPhase.paused), ambient: false),
      );

      expect(valueColourOf(tester, '24:30'), WatchTheme.warning);
    });

    testWidgets('shows distance, pace, heart rate and loops', (tester) async {
      await pumpPage(
        tester,
        MetricsPage(stats: running(bpm: 148, loops: 2), ambient: false),
      );

      for (final label in ['KM', '/KM', 'BPM', 'LOOPS']) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      expect(find.text('148'), findsOneWidget);
    });

    testWidgets('a closed loop is accented, none is not', (tester) async {
      // The one number on this page worth glancing down for mid-run.
      await pumpPage(
          tester, MetricsPage(stats: running(loops: 2), ambient: false));
      expect(valueColourOf(tester, '2'), WatchTheme.accent);

      await pumpPage(
          tester, MetricsPage(stats: running(loops: 0), ambient: false));
      expect(valueColourOf(tester, '0'), isNot(WatchTheme.accent));
    });

    testWidgets('renders with no heart rate at all', (tester) async {
      // A watch without the sensor permission, or a phone-relayed run.
      await pumpPage(
          tester, MetricsPage(stats: running(), ambient: false));

      expect(tester.takeException(), isNull);
      expect(find.text('BPM'), findsOneWidget);
    });
  });

  group('the territory page', () {
    RunStats withLoops(int loops) => RunStats(
          phase: RunPhase.running,
          loopsCompleted: loops,
          claimedAreaM2: loops * 12000,
        );

    testWidgets('invites you to close one when you have not', (tester) async {
      await pumpPage(
          tester, TerritoryPage(stats: withLoops(0), ambient: false));

      expect(find.textContaining('Close a loop'), findsOneWidget);
    });

    testWidgets('drops the invitation once ground is claimed', (tester) async {
      await pumpPage(
          tester, TerritoryPage(stats: withLoops(1), ambient: false));

      expect(find.textContaining('Close a loop'), findsNothing);
    });

    testWidgets('the invitation is suppressed in ambient mode', (tester) async {
      // Ambient is for glancing, not reading; prose there is wasted pixels.
      await pumpPage(
          tester, TerritoryPage(stats: withLoops(0), ambient: true));

      expect(find.textContaining('Close a loop'), findsNothing);
    });

    testWidgets('counts one loop in the singular', (tester) async {
      await pumpPage(
          tester, TerritoryPage(stats: withLoops(1), ambient: false));

      expect(find.text('LOOP CLOSED'), findsOneWidget);
    });

    testWidgets('and several in the plural', (tester) async {
      await pumpPage(
          tester, TerritoryPage(stats: withLoops(3), ambient: false));

      expect(find.text('LOOPS CLOSED'), findsOneWidget);
    });

    testWidgets('none reads as plural, not as one', (tester) async {
      await pumpPage(
          tester, TerritoryPage(stats: withLoops(0), ambient: false));

      expect(find.text('LOOPS CLOSED'), findsOneWidget);
    });
  });

  group('the navigation page', () {
    WatchGuidance guide({
      double? distanceToTurn,
      double? turnAngle,
      bool offRoute = false,
      double remaining = 2400,
    }) =>
        WatchGuidance(
          targetBearingDegrees: 90,
          headingDegrees: 0,
          isOffRoute: offRoute,
          distanceToTurnMeters: distanceToTurn,
          turnAngleDegrees: turnAngle,
          distanceRemainingMeters: remaining,
        );

    Widget page(WatchGuidance? guidance, {bool ambient = false}) =>
        NavigationPage(
          stats: RunStats(phase: RunPhase.running, guidance: guidance),
          ambient: ambient,
        );

    testWidgets('says so plainly when there is no route', (tester) async {
      await pumpPage(tester, page(null));

      expect(find.textContaining('No route'), findsOneWidget);
    });

    testWidgets('a turn at or past 70 degrees is a turn', (tester) async {
      await pumpPage(
          tester, page(guide(distanceToTurn: 80, turnAngle: 90)));

      expect(find.textContaining('Turn right'), findsOneWidget);
    });

    testWidgets('a gentler one is a bear', (tester) async {
      // The split matters: told to "turn" at a 40° fork, a runner looks for a
      // junction that is not there.
      await pumpPage(
          tester, page(guide(distanceToTurn: 80, turnAngle: 40)));

      expect(find.textContaining('Bear right'), findsOneWidget);
    });

    testWidgets('exactly 70 degrees is a turn, not a bear', (tester) async {
      await pumpPage(
          tester, page(guide(distanceToTurn: 80, turnAngle: 70)));

      expect(find.textContaining('Turn right'), findsOneWidget);
    });

    testWidgets('a negative angle is a left', (tester) async {
      await pumpPage(
          tester, page(guide(distanceToTurn: 80, turnAngle: -90)));

      expect(find.textContaining('Turn left'), findsOneWidget);
    });

    testWidgets('inside 15 m it is happening now, with no distance',
        (tester) async {
      // "Turn left in 10 m" is useless at the corner itself.
      await pumpPage(
          tester, page(guide(distanceToTurn: 8, turnAngle: 90)));

      expect(find.textContaining('now'), findsOneWidget);
      expect(find.textContaining(' m'), findsNothing);
    });

    testWidgets('the distance is rounded to ten metres', (tester) async {
      // GPS cannot resolve better than that, and a jittering "83 m, 79 m,
      // 86 m" reads as broken.
      await pumpPage(
          tester, page(guide(distanceToTurn: 83, turnAngle: 90)));

      expect(find.textContaining('80 m'), findsOneWidget);
    });

    testWidgets('with nothing in range it says to carry on', (tester) async {
      // Explicitly, rather than leaving a blank — a blank mid-run reads as a
      // lost signal.
      await pumpPage(tester, page(guide()));

      expect(find.text('Continue straight'), findsOneWidget);
    });

    testWidgets('off route overrides whatever the turn was', (tester) async {
      await pumpPage(
        tester,
        page(guide(distanceToTurn: 80, turnAngle: 90, offRoute: true)),
      );

      expect(find.text('OFF ROUTE'), findsOneWidget);
      expect(find.textContaining('Turn right'), findsNothing);
    });

    testWidgets('off route is drawn as a warning', (tester) async {
      await pumpPage(tester, page(guide(offRoute: true)));

      final text = tester.widget<Text>(find.text('OFF ROUTE'));
      expect(text.style!.color, WatchTheme.warning);
    });

    testWidgets('ambient mode flattens even the off-route warning',
        (tester) async {
      await pumpPage(tester, page(guide(offRoute: true), ambient: true));

      final text = tester.widget<Text>(find.text('OFF ROUTE'));
      expect(text.style!.color, WatchTheme.ambientText);
    });

    testWidgets('shows how far is left', (tester) async {
      await pumpPage(tester, page(guide(remaining: 2400)));

      expect(find.text('KM LEFT'), findsOneWidget);
    });
  });

  group('the controls page', () {
    late List<WatchCommand> sent;

    setUp(() => sent = []);

    Future<void> pumpControls(WidgetTester tester,
        {RunPhase phase = RunPhase.running}) async {
      await pumpPage(
        tester,
        ControlsPage(
          stats: RunStats(phase: phase),
          onCommand: sent.add,
        ),
      );
    }

    testWidgets('offers to pause a running run', (tester) async {
      await pumpControls(tester);

      expect(find.text('PAUSE'), findsOneWidget);
      expect(find.text('RESUME'), findsNothing);
    });

    testWidgets('offers to resume a paused one', (tester) async {
      await pumpControls(tester, phase: RunPhase.paused);

      expect(find.text('RESUME'), findsOneWidget);
    });

    testWidgets('pausing sends pause', (tester) async {
      await pumpControls(tester);

      await tester.tap(find.byIcon(Icons.pause_rounded));
      await tester.pump();

      expect(sent, [WatchCommand.pause]);
    });

    testWidgets('resuming sends resume, not pause again', (tester) async {
      await pumpControls(tester, phase: RunPhase.paused);

      await tester.tap(find.byIcon(Icons.play_arrow_rounded));
      await tester.pump();

      expect(sent, [WatchCommand.resume]);
    });

    /// The red disc behind [icon] — the `Material` that draws it. Measuring
    /// the icon instead would report a constant 24: the glyph does not grow,
    /// the disc around it does.
    Size discSize(WidgetTester tester, IconData icon) => tester.getSize(
          find
              .ancestor(of: find.byIcon(icon), matching: find.byType(Material))
              .first,
        );

    group('ending a run', () {
      // Hold, never tap. A run is the whole point of being out there and a
      // stray touch — a sleeve, a wrist against a doorframe — must not end
      // one. The ring filling is the confirmation that it is being asked for.

      testWidgets('a tap does nothing at all', (tester) async {
        await pumpControls(tester);

        await tester.tap(find.byIcon(Icons.stop_rounded));
        await tester.pump();
        await tester.pump(const Duration(seconds: 2));

        expect(sent, isEmpty);
      });

      testWidgets('holding long enough ends it', (tester) async {
        await pumpControls(tester);

        final gesture =
            await tester.startGesture(tester.getCenter(find.byIcon(Icons.stop_rounded)));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 1500));
        await gesture.up();
        await tester.pump();

        expect(sent, [WatchCommand.finish]);
      });

      testWidgets('letting go early abandons it', (tester) async {
        // The run keeps going. Anything else would make a mis-touch
        // irreversible.
        await pumpControls(tester);

        final gesture =
            await tester.startGesture(tester.getCenter(find.byIcon(Icons.stop_rounded)));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));
        await gesture.up();
        await tester.pump(const Duration(seconds: 2));

        expect(sent, isEmpty);
      });

      testWidgets('the button itself swells as the ring fills', (tester) async {
        // The ring sweeping round on its own reads as an animation playing
        // next to the control rather than as the control responding to being
        // held. The disc grows with it, up to the ring's inner edge.
        await pumpControls(tester);
        final atRest = discSize(tester, Icons.stop_rounded);

        final gesture =
            await tester.startGesture(tester.getCenter(find.byIcon(Icons.stop_rounded)));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 700));
        final halfHeld =
            discSize(tester, Icons.stop_rounded);

        expect(halfHeld.width, greaterThan(atRest.width));
        await gesture.up();
        await tester.pumpAndSettle();
      });

      testWidgets('and settles back to its resting size when let go',
          (tester) async {
        await pumpControls(tester);
        final atRest = discSize(tester, Icons.stop_rounded);

        final gesture =
            await tester.startGesture(tester.getCenter(find.byIcon(Icons.stop_rounded)));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 700));
        await gesture.up();
        await tester.pumpAndSettle();

        expect(discSize(tester, Icons.stop_rounded).width,
            atRest.width);
      });

      testWidgets('the pause button never swells, since it is a tap',
          (tester) async {
        // Only the hold has progress to show; growing a plain button would
        // suggest it needs holding too.
        await pumpControls(tester);
        final before =
            discSize(tester, Icons.pause_rounded);

        final gesture =
            await tester.startGesture(tester.getCenter(find.byIcon(Icons.stop_rounded)));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 700));

        expect(discSize(tester, Icons.pause_rounded).width,
            before.width);
        await gesture.up();
        await tester.pumpAndSettle();
      });

      testWidgets('the label says the hold is being registered',
          (tester) async {
        // Without it a hold in progress is indistinguishable from a dead
        // button, and people let go.
        await pumpControls(tester);

        final gesture =
            await tester.startGesture(tester.getCenter(find.byIcon(Icons.stop_rounded)));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        expect(find.text('KEEP HOLDING'), findsOneWidget);
        await gesture.up();
        await tester.pump(const Duration(seconds: 2));
      });

      testWidgets('and goes back once the hold is abandoned', (tester) async {
        await pumpControls(tester);

        final gesture =
            await tester.startGesture(tester.getCenter(find.byIcon(Icons.stop_rounded)));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await gesture.up();
        // Settle, not one long pump: the ring animates back down over several
        // frames, and a single jump leaves it mid-reverse.
        await tester.pumpAndSettle();

        expect(find.text('HOLD TO END'), findsOneWidget);
        expect(find.text('KEEP HOLDING'), findsNothing);
      });

      testWidgets('one hold ends the run once, not repeatedly',
          (tester) async {
        // The controller resets on completion; without that it would sit
        // completed and fire again on the next status change.
        await pumpControls(tester);

        final gesture =
            await tester.startGesture(tester.getCenter(find.byIcon(Icons.stop_rounded)));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 2500));
        await gesture.up();
        await tester.pump(const Duration(seconds: 1));

        expect(sent, [WatchCommand.finish]);
      });
    });
  });

}
