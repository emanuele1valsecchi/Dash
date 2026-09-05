import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dash/services/unit_preferences.dart';
import 'package:dash/widgets/profile/profile_statistics_section.dart';
import 'package:dash/widgets/units_scope.dart';

import '../helpers/pump_app.dart';

/// The weekly bar chart on a profile.
///
/// Two settings decide what this draws, and neither is visible in the data:
/// the user's units (km/mi, kcal/kJ) and which day their week starts on.
/// Both can be changed while the chart is on screen, which is why the raw
/// sessions are held in state and converted during `build` — the same reason
/// the home screen's monthly cards hold raw numbers.
void main() {
  late FakeFirebaseFirestore db;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = FakeFirebaseFirestore();
    // `warmUp` short-circuits once it has run, so it cannot undo a unit a
    // previous test set — the singleton has to be reset explicitly or the
    // kilojoules test silently reconfigures every test after it.
    UnitPreferences.instance.resetForTesting();
    await UnitPreferences.instance.warmUp();
  });

  tearDown(UnitPreferences.instance.resetForTesting);

  /// A run of [distanceMeters] on [at].
  Future<void> addRun({
    required DateTime at,
    double distanceMeters = 5000,
    int durationMs = 1800000,
    double maxPaceMinPerKm = 6,
    String userId = 'me',
  }) =>
      db.collection('runningSessions').add({
        'userId': userId,
        'createdAt': Timestamp.fromDate(at),
        'distanceMeters': distanceMeters,
        'durationMs': durationMs,
        'maxPaceMinPerKm': maxPaceMinPerKm,
      });

  Future<void> pumpChart(WidgetTester tester) async {
    await pumpDashWidget(
      tester,
      // The scope is what makes the settings reach the chart: `Units.of`
      // degrades to metric with nothing above it, so without this every test
      // below would read the default and prove nothing about the setting.
      UnitsScope(
        preferences: UnitPreferences.instance,
        child: ProfileStatisticsSection(userId: 'me', firestore: db),
      ),
      surfaceSize: const Size(900, 1400),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  /// Selects one of the five metrics.
  Future<void> choose(WidgetTester tester, String metric) async {
    await tester.tap(find.text(metric));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  /// The most recent weekday matching [weekday] (Mon = 1 … Sun = 7), at noon
  /// so no timezone rounding can push it into an adjacent day.
  DateTime lastWeekday(int weekday) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day, 12);
    return today.subtract(Duration(days: (today.weekday - weekday + 7) % 7));
  }

  group('the days along the bottom', () {
    testWidgets('start on Monday by default', (tester) async {
      await pumpChart(tester);

      expect(find.text('Mon'), findsOneWidget);
      expect(find.text('Sun'), findsOneWidget);
    });

    testWidgets('start on Sunday when that is the setting', (tester) async {
      // Not cosmetic: the bars are positioned by the same index, so a label
      // row that disagrees with the buckets would file every run under the
      // wrong day.
      await UnitPreferences.instance.setWeekStart(WeekStart.sunday);
      await pumpChart(tester);

      final labels = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data)
          .where((d) => const ['Mon', 'Sun'].contains(d))
          .toList();

      expect(labels.first, 'Sun', reason: 'the week now opens on Sunday');
    });

    testWidgets('all seven are always drawn', (tester) async {
      await pumpChart(tester);

      for (final day in ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun']) {
        expect(find.text(day), findsOneWidget, reason: day);
      }
    });
  });

  group('units', () {
    testWidgets('distance reads in kilometres by default', (tester) async {
      await addRun(at: lastWeekday(DateTime.monday), distanceMeters: 10000);
      await pumpChart(tester);

      await choose(tester, 'Distance');

      expect(find.textContaining('10.0 km'), findsWidgets);
      expect(find.textContaining('mi'), findsNothing);
    });

    testWidgets('distance reads in miles when that is the setting',
        (tester) async {
      // 10 km is 6.2 miles. A miles user seeing "10.0 km" here while every
      // other screen says 6.2 mi is exactly the inconsistency this fixes.
      await UnitPreferences.instance.setDistance(DistanceUnit.miles);
      await addRun(at: lastWeekday(DateTime.monday), distanceMeters: 10000);
      await pumpChart(tester);

      await choose(tester, 'Distance');

      // The number has to convert too, not just the suffix — a bar labelled
      // "10.0 mi" for a 10 km run is worse than one labelled in kilometres,
      // because it looks right.
      expect(find.textContaining('6.2 mi'), findsWidgets);
      expect(find.textContaining('10.0'), findsNothing);
      expect(find.textContaining('km'), findsNothing);
    });

    testWidgets('energy reads in kcal by default', (tester) async {
      await addRun(at: lastWeekday(DateTime.monday), distanceMeters: 10000);
      await pumpChart(tester);

      await choose(tester, 'Calories');

      expect(find.textContaining('700 kcal'), findsWidgets);
      expect(find.textContaining('kJ'), findsNothing);
    });

    testWidgets('energy reads in kilojoules when that is the setting',
        (tester) async {
      await UnitPreferences.instance.setEnergy(EnergyUnit.kilojoules);
      await addRun(at: lastWeekday(DateTime.monday), distanceMeters: 10000);
      await pumpChart(tester);

      await choose(tester, 'Calories');

      // 700 kcal is 2928.8 kJ, and the axis truncates rather than rounds.
      // Relabelling without converting would report a seventh of the real
      // figure.
      expect(find.textContaining('2928 kJ'), findsWidgets);
      expect(find.textContaining('700'), findsNothing);
    });

    testWidgets('speed carries the same distance unit as everything else',
        (tester) async {
      await UnitPreferences.instance.setDistance(DistanceUnit.miles);
      await addRun(at: lastWeekday(DateTime.monday), maxPaceMinPerKm: 6);
      await pumpChart(tester);

      await choose(tester, 'Speed');

      // 6 min/km is 10 km/h, which is 6.2 mph.
      expect(find.textContaining('6.2 mi/h'), findsWidgets);
      expect(find.textContaining('10.0'), findsNothing);
      expect(find.textContaining('km/h'), findsNothing);
    });

    testWidgets('time is unitless and unaffected', (tester) async {
      // Minutes are minutes in either system; switching units must not make
      // the one metric that has no unit start showing one.
      await UnitPreferences.instance.setDistance(DistanceUnit.miles);
      await addRun(
          at: lastWeekday(DateTime.monday), durationMs: 45 * 60 * 1000);
      await pumpChart(tester);

      expect(find.textContaining('45m'), findsWidgets);
    });
  });

  group('what is counted', () {
    testWidgets('a run from this week is counted', (tester) async {
      await addRun(at: DateTime.now().subtract(const Duration(hours: 1)));
      await pumpChart(tester);

      await choose(tester, 'Activities');

      expect(find.text('1'), findsWidgets);
    });

    testWidgets('another user\'s run is not', (tester) async {
      await addRun(
          at: DateTime.now().subtract(const Duration(hours: 1)),
          userId: 'someone-else');
      await pumpChart(tester);

      await choose(tester, 'Distance');

      expect(find.textContaining('km'), findsNothing,
          reason: 'no data, so no axis labels at all');
    });

    testWidgets('a run from before this week is fetched but not charted',
        (tester) async {
      // The query deliberately reaches back further than one week so either
      // week-start setting is covered — so the trimming has to happen when
      // the bars are built, or last week's runs leak into this week's chart.
      //
      // The day *before* this week began is the case that matters: it is
      // inside the query window by construction, so the only thing that can
      // exclude it is the trim.
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day, 12);
      final startOfWeek = today.subtract(Duration(days: today.weekday - 1));
      await addRun(at: startOfWeek.subtract(const Duration(days: 1)));
      await pumpChart(tester);

      await choose(tester, 'Distance');

      expect(find.textContaining('km'), findsNothing);
    });

    testWidgets('energy comes from the shared estimate, not a local constant',
        (tester) async {
      // 10 km at 70 kcal/km is 700 kcal. The constant lives in
      // `run_estimates.dart` and is mirrored server-side; a second copy here
      // could only drift.
      await addRun(at: lastWeekday(DateTime.monday), distanceMeters: 10000);
      await pumpChart(tester);

      await choose(tester, 'Calories');

      expect(find.textContaining('700'), findsWidgets);
    });
  });
}
