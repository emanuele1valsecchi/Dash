import 'package:dash/models/home_models.dart';
import 'package:dash/widgets/home/statistic_tachometer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/pump_app.dart';

/// The home screen's monthly stat gauges — a progress arc with the figure in
/// the middle.
///
/// The non-obvious part of this widget is the **invisible sizing stack**: it
/// lays out *every* stat's inner content behind a `Visibility(visible: false,
/// maintainSize: true)` so all the gauges end up the same size regardless of
/// how long each one's text is. Without that, "Distance" and "Total time"
/// would render at different widths and the row would look ragged.
void main() {
  MonthlyStatData stat({
    String title = 'Distance',
    String value = '42.5 km',
    IconData icon = Icons.straighten,
    double progress = 0.6,
    String bottomText = 'this month',
  }) =>
      MonthlyStatData(
        title: title,
        value: value,
        icon: icon,
        progress: progress,
        bottomText: bottomText,
      );

  late List<MonthlyStatData> all;

  setUp(() {
    all = [
      stat(),
      stat(title: 'Total time', value: '5h 12m', icon: Icons.timer),
      stat(title: 'Area claimed', value: '1.2 km2', icon: Icons.crop_square),
    ];
  });

  Future<void> pumpGauge(
    WidgetTester tester,
    MonthlyStatData subject, {
    List<MonthlyStatData>? others,
  }) =>
      pumpDashWidget(
        tester,
        // 300px, not the ~160 a real home screen gives each gauge. The test
        // font renders every glyph a full em wide, so "Distance" measures
        // ~112px here against ~55px on a device (see TEST_NOTES §1.2) and the
        // title Row overflows a realistically-sized box for reasons that have
        // nothing to do with this widget. Sizing up keeps the assertion about
        // the gauge rather than about font metrics.
        SizedBox(
          width: 300,
          child: StatisticTachometer(stat: subject, allStats: others ?? all),
        ),
        surfaceSize: kPhoneSurface,
      );

  group('what it shows', () {
    testWidgets('renders its own title, value and icon', (tester) async {
      await pumpGauge(tester, all.first);

      expect(find.text('Distance'), findsWidgets);
      expect(find.text('42.5 km'), findsWidgets);
      expect(find.byIcon(Icons.straighten), findsWidgets);
    });

    testWidgets('draws a gauge arc', (tester) async {
      await pumpGauge(tester, all.first);

      expect(find.byType(CustomPaint), findsWidgets);
    });

    testWidgets('renders a different stat correctly', (tester) async {
      await pumpGauge(tester, all[1]);

      expect(find.text('5h 12m'), findsWidgets);
    });
  });

  group('the invisible sizing stack', () {
    // Every stat's content is laid out behind an invisible Stack so all the
    // gauges size alike. That means the *other* stats' text is present in the
    // tree but not painted - worth knowing, since it makes `findsOneWidget`
    // the wrong matcher throughout this file.
    testWidgets('lays out every stat, not just the visible one',
        (tester) async {
      await pumpGauge(tester, all.first);

      // The other two titles exist in the tree even though only one shows.
      expect(find.text('Total time'), findsWidgets);
      expect(find.text('Area claimed'), findsWidgets);
    });

    testWidgets('the sizing copies are hidden from the accessibility tree',
        (tester) async {
      // `ExcludeSemantics` around them: a screen reader announcing three
      // stats when one is visible would be nonsense.
      await pumpGauge(tester, all.first);

      expect(find.byType(ExcludeSemantics), findsWidgets);
    });

    testWidgets('the hidden copies keep their size', (tester) async {
      // `maintainSize: true` is what makes the gauges uniform; without it the
      // widget collapses to its own content and the trick does nothing.
      await pumpGauge(tester, all.first);

      final visibility = tester.widgetList<Visibility>(
        find.byType(Visibility),
      );
      expect(
        visibility.any((v) => !v.visible && v.maintainSize),
        isTrue,
      );
    });

    testWidgets('a single stat renders on its own', (tester) async {
      await pumpGauge(tester, all.first, others: [all.first]);

      expect(tester.takeException(), isNull);
      expect(find.text('42.5 km'), findsWidgets);
    });
  });

  group('progress values', () {
    // The painter clamps, so out-of-range values must not throw or paint an
    // arc past a full circle.
    for (final p in const [0.0, 0.5, 1.0]) {
      testWidgets('renders at progress $p', (tester) async {
        await pumpGauge(tester, stat(progress: p), others: [stat(progress: p)]);

        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('a progress above 1 does not throw', (tester) async {
      await pumpGauge(tester, stat(progress: 1.8), others: [stat(progress: 1.8)]);

      expect(tester.takeException(), isNull);
    });

    testWidgets('a negative progress does not throw', (tester) async {
      // Guarded by `if (progress > 0)` before the clamp, so nothing is drawn.
      await pumpGauge(
        tester,
        stat(progress: -0.5),
        others: [stat(progress: -0.5)],
      );

      expect(tester.takeException(), isNull);
    });
  });

  group('long text', () {
    testWidgets('a long title is truncated rather than overflowing',
        (tester) async {
      await pumpGauge(
        tester,
        stat(title: 'Total distance covered this calendar month'),
        others: [stat(title: 'Total distance covered this calendar month')],
      );

      expect(tester.takeException(), isNull);

      final title = tester.widget<Text>(
        find.text('Total distance covered this calendar month').first,
      );
      expect(title.maxLines, 2);
      expect(title.overflow, TextOverflow.ellipsis);
    });

    testWidgets('an empty value renders without collapsing', (tester) async {
      await pumpGauge(tester, stat(value: ''), others: [stat(value: '')]);

      expect(tester.takeException(), isNull);
      expect(find.text('Distance'), findsWidgets);
    });
  });
}
