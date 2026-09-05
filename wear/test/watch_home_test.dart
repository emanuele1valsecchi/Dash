import 'dart:async';

import 'package:dash_watch_protocol/dash_watch_protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dash_wear/run_stats_source.dart';
import 'package:dash_wear/screens/watch_home.dart';
import 'package:dash_wear/widgets/controls_page.dart';
import 'package:dash_wear/widgets/metrics_page.dart';

/// The root of the watch app, which is a router: one screen per run phase.
///
/// Getting the routing wrong is not subtle on a wrist — a runner who taps
/// start and stays on the start screen has no way to tell whether the run
/// began. `WatchHome` takes a `RunStatsSource` rather than reaching for a
/// transport, which is what makes driving it from a fake possible at all.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeSource source;

  setUp(() {
    // `ScreenAwake` and `wear_plus` are platform channels with nothing to say
    // in a test; answering null keeps them from throwing.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('dash/screen_awake'), (_) async => null);
    source = _FakeSource();
  });

  tearDown(() {
    source.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('dash/screen_awake'), null);
  });

  Future<void> pumpHome(WidgetTester tester) async {
    // Larger than a real 220 dp watch: the test font is about twice the real
    // width, so a true-size surface overflows for reasons unrelated to the
    // widgets. See the note in `watch_pages_test.dart`.
    await tester.binding.setSurfaceSize(const Size(420, 420));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(home: WatchHome(source: source)));
    await tester.pump();
  }

  /// Moves the source to [stats] and lets the screen react.
  Future<void> emit(WidgetTester tester, RunStats stats) async {
    source.emit(stats);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  group('which screen is shown', () {
    testWidgets('idle offers to start a run', (tester) async {
      await pumpHome(tester);

      expect(find.text('DASH'), findsOneWidget);
      expect(find.byType(MetricsPage), findsNothing);
    });

    testWidgets('a countdown shows the number and nothing else',
        (tester) async {
      // Big, single, unmissable — it is read at arm's length in the second
      // before setting off.
      await pumpHome(tester);

      await emit(tester,
          const RunStats(phase: RunPhase.countdown, countdownValue: 3));

      expect(find.text('3'), findsOneWidget);
      expect(find.text('DASH'), findsNothing);
    });

    testWidgets('the countdown follows the value down', (tester) async {
      await pumpHome(tester);

      await emit(tester,
          const RunStats(phase: RunPhase.countdown, countdownValue: 5));
      expect(find.text('5'), findsOneWidget);

      await emit(tester,
          const RunStats(phase: RunPhase.countdown, countdownValue: 2));
      expect(find.text('2'), findsOneWidget);
      expect(find.text('5'), findsNothing);
    });

    testWidgets('a running run shows the metrics pager', (tester) async {
      await pumpHome(tester);

      await emit(tester, const RunStats(
          phase: RunPhase.running, distanceMeters: 1200));

      expect(find.byType(MetricsPage), findsOneWidget);
      expect(find.text('DASH'), findsNothing);
    });

    testWidgets('a paused run stays on the pager', (tester) async {
      // Pausing is not leaving the run — dropping back to the start screen
      // would lose every number on it.
      await pumpHome(tester);

      await emit(tester, const RunStats(phase: RunPhase.paused));

      expect(find.byType(MetricsPage), findsOneWidget);
    });

    testWidgets('a finished run shows its summary', (tester) async {
      await pumpHome(tester);

      await emit(tester, const RunStats(
          phase: RunPhase.finished, distanceMeters: 5000, loopsCompleted: 2));

      expect(find.byType(MetricsPage), findsNothing);
      expect(find.text('LOOPS'), findsOneWidget);
    });

    testWidgets('a phone-owned run says where to save it', (tester) async {
      // No send button here: the phone has the run, and the watch must not
      // imply the runner has to do something on the wrist.
      await pumpHome(tester);

      await emit(tester, const RunStats(phase: RunPhase.finished));

      expect(find.textContaining('on your phone'), findsOneWidget);
    });

    testWidgets('and back to idle when the run is cleared', (tester) async {
      await pumpHome(tester);
      await emit(tester, const RunStats(phase: RunPhase.running));

      await emit(tester, const RunStats(phase: RunPhase.idle));

      expect(find.text('DASH'), findsOneWidget);
      expect(find.byType(MetricsPage), findsNothing);
    });
  });

  group('the pager', () {
    testWidgets('scrolls vertically, not horizontally', (tester) async {
      // Wear OS's back gesture is a swipe in from the left edge, so a
      // horizontal pager fights the OS for every swipe and users leave the
      // app by accident.
      await pumpHome(tester);
      await emit(tester, const RunStats(phase: RunPhase.running));

      final pager = tester.widget<PageView>(find.byType(PageView));

      expect(pager.scrollDirection, Axis.vertical);
    });

    testWidgets('reaches the controls by scrolling', (tester) async {
      await pumpHome(tester);
      await emit(tester, const RunStats(phase: RunPhase.running));

      await tester.drag(find.byType(PageView), const Offset(0, -1200));
      await tester.pumpAndSettle();

      expect(find.byType(ControlsPage), findsOneWidget);
    });
  });

  group('starting a run', () {
    testWidgets('the play button asks for a run', (tester) async {
      // Addressed by the icon, not the caption: the label sits below the
      // circle and receives no taps, so finding it would prove nothing.
      await pumpHome(tester);

      await tester.tap(find.byIcon(Icons.play_arrow_rounded));
      await tester.pump();

      expect(source.commands, [WatchCommand.start]);
    });

    testWidgets('it is labelled, so the circle is not a guess',
        (tester) async {
      await pumpHome(tester);

      expect(find.text('START RUN'), findsOneWidget);
    });

    testWidgets('there is nothing to start once a run is under way',
        (tester) async {
      await pumpHome(tester);

      await emit(tester, const RunStats(phase: RunPhase.running));

      expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);
    });
  });
}

/// A stats source under the test's control.
///
/// `WatchHome` is written against this interface rather than a transport,
/// which is the whole reason the screen can be driven with no phone, no
/// Bluetooth and no GPS.
class _FakeSource implements RunStatsSource {
  final _controller = StreamController<RunStats>.broadcast();
  final commands = <WatchCommand>[];

  RunStats _current = RunStats.idle;

  void emit(RunStats stats) {
    _current = stats;
    _controller.add(stats);
  }

  @override
  Stream<RunStats> get stats => _controller.stream;

  @override
  RunStats get current => _current;

  @override
  Future<void> send(WatchCommand command) async => commands.add(command);

  @override
  void dismissSummary() {}

  @override
  void dispose() => _controller.close();
}
