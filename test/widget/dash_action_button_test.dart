import 'package:dash/widgets/dash_action_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/pump_app.dart';

void main() {
  group('DashActionButton', () {
    testWidgets('renders a label-only button as an ElevatedButton',
        (tester) async {
      await pumpDashWidget(
        tester,
        DashActionButton(label: 'Save route', onPressed: () {}),
      );

      expect(find.text('Save route'), findsOneWidget);
      expect(find.byType(ElevatedButton), findsOneWidget);
      expect(find.byType(IconButton), findsNothing);
    });

    testWidgets('collapses to an IconButton when given an icon and no label',
        (tester) async {
      await pumpDashWidget(
        tester,
        DashActionButton(icon: Icons.play_arrow, onPressed: () {}),
      );

      // The icon-only case is a genuinely different widget, not an
      // ElevatedButton with an empty label — a caller relying on IconButton's
      // circular hit box would silently get a pill-shaped one otherwise.
      expect(find.byType(IconButton), findsOneWidget);
      expect(find.byType(ElevatedButton), findsNothing);
      expect(find.byIcon(Icons.play_arrow), findsOneWidget);
    });

    testWidgets('renders both icon and label together', (tester) async {
      await pumpDashWidget(
        tester,
        DashActionButton(
          icon: Icons.play_arrow,
          label: 'Run',
          onPressed: () {},
        ),
      );

      expect(find.byType(ElevatedButton), findsOneWidget);
      expect(find.byIcon(Icons.play_arrow), findsOneWidget);
      expect(find.text('Run'), findsOneWidget);
    });

    testWidgets('fires onPressed when tapped', (tester) async {
      var taps = 0;
      await pumpDashWidget(
        tester,
        DashActionButton(label: 'Run', onPressed: () => taps++),
      );

      await tester.tap(find.byType(ElevatedButton));
      await tester.pump();

      expect(taps, 1);
    });

    testWidgets('a null onPressed disables the button rather than throwing',
        (tester) async {
      await pumpDashWidget(
        tester,
        const DashActionButton(label: 'Run', onPressed: null),
      );

      final button = tester.widget<ElevatedButton>(find.byType(ElevatedButton));
      expect(button.onPressed, isNull);
      expect(button.enabled, isFalse);
    });

    test('asserts when given neither a label nor an icon', () {
      // The constructor's own assert is the contract: a button with no
      // content at all is a caller bug, not something to render blank.
      expect(
        () => DashActionButton(onPressed: () {}),
        throwsA(isA<AssertionError>()),
      );
    });

    testWidgets('honours an explicit icon size over the text size',
        (tester) async {
      await pumpDashWidget(
        tester,
        DashActionButton(icon: Icons.play_arrow, iconSize: 42, onPressed: () {}),
      );

      expect(tester.widget<Icon>(find.byType(Icon)).size, 42);
    });
  });
}
