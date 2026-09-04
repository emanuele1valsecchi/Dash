import 'package:dash/widgets/dash_stat_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/pump_app.dart';

void main() {
  group('DashStatTile', () {
    testWidgets('shows its icon, label and value together', (tester) async {
      await pumpDashWidget(
        tester,
        const DashStatTile(
          icon: Icons.straighten,
          label: 'Distance',
          value: '4.2 km',
        ),
      );

      expect(find.byIcon(Icons.straighten), findsOneWidget);
      expect(find.text('Distance'), findsOneWidget);
      expect(find.text('4.2 km'), findsOneWidget);
    });

    testWidgets('renders the value verbatim, formatting nothing itself',
        (tester) async {
      // The tile is deliberately dumb: units and precision are decided by
      // UnitFormatter at the call site, so a tile that reformatted anything
      // would quietly disagree with the rest of the app.
      await pumpDashWidget(
        tester,
        const DashStatTile(
          icon: Icons.speed,
          label: 'Avg pace',
          value: "5'30\"/km",
        ),
      );

      expect(find.text("5'30\"/km"), findsOneWidget);
    });

    testWidgets('truncates a long label instead of overflowing',
        (tester) async {
      await pumpDashWidget(
        tester,
        const SizedBox(
          width: 90,
          child: DashStatTile(
            icon: Icons.terrain,
            label: 'Elevation gained over the whole run',
            value: '128 m',
          ),
        ),
        surfaceSize: kPhoneSurface,
      );

      // A RenderFlex overflow would have been recorded as an exception.
      expect(tester.takeException(), isNull);

      final label = tester.widget<Text>(
        find.text('Elevation gained over the whole run'),
      );
      expect(label.maxLines, 1);
      expect(label.overflow, TextOverflow.ellipsis);
    });

    testWidgets('truncates a long value the same way', (tester) async {
      await pumpDashWidget(
        tester,
        const SizedBox(
          width: 90,
          child: DashStatTile(
            icon: Icons.crop_square,
            label: 'Area',
            value: '1234567.89 km2',
          ),
        ),
        surfaceSize: kPhoneSurface,
      );

      expect(tester.takeException(), isNull);

      final value = tester.widget<Text>(find.text('1234567.89 km2'));
      expect(value.maxLines, 1);
      expect(value.overflow, TextOverflow.ellipsis);
    });

    testWidgets('handles an empty value without collapsing', (tester) async {
      await pumpDashWidget(
        tester,
        const DashStatTile(icon: Icons.timer, label: 'Time', value: ''),
      );

      expect(tester.takeException(), isNull);
      expect(find.text('Time'), findsOneWidget);
    });
  });
}
