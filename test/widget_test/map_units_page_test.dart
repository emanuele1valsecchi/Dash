import 'package:dash/config/app_theme.dart';
import 'package:dash/screens/map_units_page.dart';
import 'package:dash/services/unit_preferences.dart';
import 'package:dash/widgets/units_scope.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late UnitPreferences prefs;

  setUp(() {
    // The page writes every choice straight through to SharedPreferences.
    // Without a mock store the plugin channel is missing and each setter
    // throws.
    SharedPreferences.setMockInitialValues({});
    prefs = UnitPreferences.instance;
    prefs.resetForTesting();
  });

  tearDown(() => prefs.resetForTesting());

  /// Pumps the page under the same `UnitsScope` the real app mounts above
  /// `MaterialApp`, so changing a unit rebuilds the page exactly as it does
  /// in production. Without the scope the preview would read
  /// `UnitFormatter.metric` forever and none of the live-update tests would
  /// mean anything.
  Future<void> pumpPage(WidgetTester tester) async {
    // A phone-width but very tall viewport, so the whole settings list is laid
    // out at once. On a normal 800x600 surface `scrollUntilVisible` leaves a
    // row at the clipped bottom edge, where the tap coordinate falls outside
    // the hit box and silently does nothing — the assertion then fails for a
    // scrolling reason rather than a real one.
    tester.view.physicalSize = const Size(390, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      UnitsScope(
        preferences: prefs,
        child: MaterialApp(
          theme: buildAppTheme(),
          home: const MapUnitsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Scrolls [text] into view before tapping it — the page is a long
  /// `ListView` and most rows start off-screen on a test-sized surface.
  Future<void> tapOption(WidgetTester tester, String text) async {
    final target = find.text(text);
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
    await tester.tap(target);
    await tester.pumpAndSettle();
  }


  /// The value shown against [label] in the preview card.
  ///
  /// Scoped to the row rather than searching the page for the text, because
  /// several option *subtitles* quote the same sample values ("e.g. 18:35",
  /// "e.g. 10.9 km/h"). A page-wide `textContaining` matches those too and
  /// fails with "found 2 widgets" for a reason unrelated to the preview.
  String previewValue(WidgetTester tester, String label) {
    final row =
        find.ancestor(of: find.text(label), matching: find.byType(Row)).first;
    final texts = tester
        .widgetList<Text>(find.descendant(of: row, matching: find.byType(Text)))
        .toList();
    return texts[1].data!;
  }

  group('layout', () {
    testWidgets('shows every settings section', (tester) async {
      await pumpPage(tester);

      for (final heading in const [
        'MEASUREMENT SYSTEM',
        'AREA',
        'PACE OR SPEED',
        'ELEVATION',
        'ENERGY',
        'DATE & TIME',
        'PREVIEW',
      ]) {
        expect(find.text(heading), findsOneWidget, reason: heading);
      }
    });

    testWidgets('is titled Map & Units', (tester) async {
      await pumpPage(tester);

      expect(find.text('Map & Units'), findsOneWidget);
    });
  });

  group('defaults', () {
    testWidgets('opens on metric', (tester) async {
      // Deliberately not guessed from platform locale - see UnitPreferences.
      await pumpPage(tester);

      expect(prefs.distance, DistanceUnit.kilometers);
      expect(prefs.area, AreaUnit.metric);
      expect(prefs.elevation, ElevationUnit.meters);
      expect(prefs.energy, EnergyUnit.kcal);
    });

    testWidgets('is not marked configured before the user touches anything',
        (tester) async {
      // syncFromCloud may only adopt a cloud copy while this is false.
      await pumpPage(tester);

      expect(prefs.isConfigured, isFalse);
    });
  });

  group('choosing a unit', () {
    testWidgets('miles updates the stored distance preference',
        (tester) async {
      await pumpPage(tester);

      await tapOption(tester, 'Miles (mi)');

      expect(prefs.distance, DistanceUnit.miles);
    });

    testWidgets('square miles updates the stored area preference',
        (tester) async {
      await pumpPage(tester);

      await tapOption(tester, 'Square miles (mi²)');

      expect(prefs.area, AreaUnit.imperial);
    });

    testWidgets('feet updates the stored elevation preference',
        (tester) async {
      await pumpPage(tester);

      await tapOption(tester, 'Feet (ft)');

      expect(prefs.elevation, ElevationUnit.feet);
    });

    testWidgets('kilojoules updates the stored energy preference',
        (tester) async {
      await pumpPage(tester);

      await tapOption(tester, 'Kilojoules (kJ)');

      expect(prefs.energy, EnergyUnit.kilojoules);
    });

    testWidgets('the 12-hour clock updates the stored clock preference',
        (tester) async {
      await pumpPage(tester);

      await tapOption(tester, '12-hour clock');

      expect(prefs.clock, ClockFormat.h12);
    });

    testWidgets('week-start updates the stored preference', (tester) async {
      await pumpPage(tester);

      await tapOption(tester, 'Week starts Sunday');

      expect(prefs.weekStart, WeekStart.sunday);
    });

    testWidgets('choosing anything marks the preferences as configured',
        (tester) async {
      // This is what stops a stale cloud copy undoing a deliberate choice.
      await pumpPage(tester);

      await tapOption(tester, 'Miles (mi)');

      expect(prefs.isConfigured, isTrue);
    });

    testWidgets('the choices are independent of each other', (tester) async {
      // Area is its own setting on purpose - territory size is the app's core
      // score, so it does not silently follow the distance unit.
      await pumpPage(tester);

      await tapOption(tester, 'Miles (mi)');

      expect(prefs.distance, DistanceUnit.miles);
      expect(prefs.area, AreaUnit.metric);
    });
  });

  group('live preview', () {
    // The sample run is fixed metric data (8420 m, 5.5 min/km, 640000 m²,
    // 96 m, 512 kcal) put through the same formatter every real screen uses,
    // so these assertions also pin the conversion path end to end.
    testWidgets('starts in metric', (tester) async {
      await pumpPage(tester);

      expect(previewValue(tester, 'Distance'), '8.42 km');
    });

    testWidgets('redraws in miles the moment the unit changes',
        (tester) async {
      // The whole point of UnitsScope being an InheritedNotifier: the page
      // rebuilds without anyone calling setState.
      await pumpPage(tester);

      await tapOption(tester, 'Miles (mi)');

      expect(previewValue(tester, 'Distance'), '5.23 mi');
    });

    testWidgets('shows the clock in the chosen format', (tester) async {
      await pumpPage(tester);
      expect(previewValue(tester, 'Finished at'), '18:35');

      await tapOption(tester, '12-hour clock');

      expect(previewValue(tester, 'Finished at'), contains('6:35'));
    });

    testWidgets('switches between pace and speed', (tester) async {
      await pumpPage(tester);

      expect(previewValue(tester, 'Pace'), '5:30 /km');

      await tapOption(tester, 'Speed');

      expect(prefs.rate, RateDisplay.speed);
      // 5.5 min/km inverts to ~10.9 km/h.
      expect(previewValue(tester, 'Speed'), startsWith('10.9'));
    });
  });

  group('Map Theme', () {
    testWidgets('is shown as locked', (tester) async {
      await pumpPage(tester);

      expect(find.text('Coming soon'), findsOneWidget);
      expect(find.byIcon(Icons.lock_rounded), findsOneWidget);
    });

    testWidgets('explains itself rather than doing nothing when tapped',
        (tester) async {
      await pumpPage(tester);

      await tapOption(tester, 'Map Theme');

      expect(find.textContaining('future update'), findsOneWidget);
    });
  });
}
