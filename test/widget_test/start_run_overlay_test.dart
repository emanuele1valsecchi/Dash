import 'package:dash/widgets/home/start_run_overlay.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/pump_app.dart';

/// The three-way choice that opens from the home screen's Start button:
/// search a route, create one, or just run.
///
/// Every one of the three is a separate entry point into the app's core loop,
/// so a callback wired to the wrong action is a silently wrong destination —
/// the sort of thing that looks fine until someone taps it.
void main() {
  late List<String> tapped;

  Future<void> pumpOverlay(WidgetTester tester) async {
    tapped = [];

    await pumpDashWidget(
      tester,
      // The overlay animates in over the home screen and pops itself on
      // dismiss, so it needs a real route to pop from.
      Builder(
        builder: (context) => ElevatedButton(
          onPressed: () => Navigator.of(context).push(
            PageRouteBuilder(
              opaque: false,
              pageBuilder: (_, animation, _) => StartRunOverlay(
                animation: animation,
                fabRect: const Rect.fromLTWH(300, 700, 56, 56),
                onSearchRoute: () => tapped.add('search'),
                onCreateRoute: () => tapped.add('create'),
                onStartRun: () => tapped.add('run'),
              ),
            ),
          ),
          child: const Text('open'),
        ),
      ),
      surfaceSize: kPhoneSurface,
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  group('layout', () {
    testWidgets('offers all three ways to start', (tester) async {
      await pumpOverlay(tester);

      expect(find.text('Search for a route'), findsOneWidget);
      expect(find.text('Create a route'), findsOneWidget);
      expect(find.text('Start to run now'), findsOneWidget);
    });
  });

  group('each action reports itself, and only itself', () {
    // Tapped by **icon**, not by label. `_OverlayAction` is a Row of a plain
    // `Text` and a separate icon-only button, so only the round icon is
    // tappable — see the "only the icon is tappable" test below.
    //
    // Wired to the wrong callback, any of these would open the wrong screen
    // while looking entirely correct.
    testWidgets('Search for a route', (tester) async {
      await pumpOverlay(tester);

      await tester.tap(find.byIcon(Symbols.search_rounded));
      await tester.pumpAndSettle();

      expect(tapped, ['search']);
    });

    testWidgets('Create a route', (tester) async {
      await pumpOverlay(tester);

      await tester.tap(find.byIcon(Symbols.route_rounded));
      await tester.pumpAndSettle();

      expect(tapped, ['create']);
    });

    testWidgets('Start to run now', (tester) async {
      await pumpOverlay(tester);

      await tester.tap(find.byIcon(Symbols.play_arrow_rounded));
      await tester.pumpAndSettle();

      expect(tapped, ['run']);
    });

    testWidgets('only the icon is tappable, not the label beside it',
        (tester) async {
      // **Deliberate, confirmed by the project owner.** Each action is a
      // Row of a plain `Text` beside a separate icon-only button, so only the
      // round icon is a target: tapping the words selects nothing **and does
      // not dismiss either** — the tap is simply swallowed. A user reaching
      // for "Search for a route" gets no response at all, which reads as a
      // no response at all.
      //
      // Of the three possible behaviours — do nothing, dismiss, or trigger the
      // action — "do nothing" is the chosen one: a near-miss on a small icon
      // must not close a menu the user just opened. This test is what stops a
      // refactor quietly turning it into "dismiss".
      await pumpOverlay(tester);

      await tester.tap(find.text('Search for a route'));
      await tester.pumpAndSettle();

      expect(tapped, isEmpty);
      expect(find.byType(StartRunOverlay), findsOneWidget);
    });
  });

  group('dismissing', () {
    testWidgets('choosing an action closes the overlay', (tester) async {
      await pumpOverlay(tester);

      await tester.tap(find.byIcon(Symbols.play_arrow_rounded));
      await tester.pumpAndSettle();

      expect(find.byType(StartRunOverlay), findsNothing);
    });

    testWidgets('tapping the backdrop closes it without choosing anything',
        (tester) async {
      await pumpOverlay(tester);

      // Top-left is backdrop: the actions sit low, above the FAB.
      await tester.tapAt(const Offset(20, 60));
      await tester.pumpAndSettle();

      expect(find.byType(StartRunOverlay), findsNothing);
      expect(tapped, isEmpty);
    });
  });

  testWidgets('animates in rather than appearing fully formed',
      (tester) async {
    // The overlay is driven by the route's own animation; a broken hookup
    // would show it at full opacity on the first frame.
    tapped = [];
    await pumpDashWidget(
      tester,
      Builder(
        builder: (context) => ElevatedButton(
          onPressed: () => Navigator.of(context).push(
            PageRouteBuilder(
              opaque: false,
              transitionDuration: const Duration(milliseconds: 300),
              pageBuilder: (_, animation, _) => StartRunOverlay(
                animation: animation,
                fabRect: const Rect.fromLTWH(300, 700, 56, 56),
                onSearchRoute: () {},
                onCreateRoute: () {},
                onStartRun: () {},
              ),
            ),
          ),
          child: const Text('open'),
        ),
      ),
      surfaceSize: kPhoneSurface,
    );

    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));

    // Mid-flight: present, and no exception from the blur/scale maths.
    expect(find.byType(StartRunOverlay), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpAndSettle();
    expect(find.text('Start to run now'), findsOneWidget);
  });
}
