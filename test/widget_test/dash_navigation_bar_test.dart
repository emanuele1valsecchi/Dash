import 'package:dash/widgets/dash_navigation_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/pump_app.dart';

void main() {
  group('DashNavigationbar', () {
    testWidgets('shows the app\'s three destinations in order', (tester) async {
      await pumpDashWidget(
        tester,
        DashNavigationbar(selectedIndex: 1, onDestinationSelected: (_) {}),
      );

      expect(find.text('Explore'), findsOneWidget);
      expect(find.text('Home'), findsOneWidget);
      expect(find.text('Profile'), findsOneWidget);
      expect(find.byType(NavigationDestination), findsNWidgets(3));
    });

    testWidgets('reflects the selected index it is given', (tester) async {
      await pumpDashWidget(
        tester,
        DashNavigationbar(selectedIndex: 2, onDestinationSelected: (_) {}),
      );

      expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
        2,
      );
    });

    group('reports the tapped destination index', () {
      for (final (index, label) in const [
        (0, 'Explore'),
        (1, 'Home'),
        (2, 'Profile'),
      ]) {
        testWidgets('$label reports $index', (tester) async {
          final selected = <int>[];
          await pumpDashWidget(
            tester,
            DashNavigationbar(
              selectedIndex: 1,
              onDestinationSelected: selected.add,
            ),
          );

          await tester.tap(find.text(label));
          await tester.pumpAndSettle();

          expect(selected, [index]);
        });
      }
    });

    testWidgets('is fully controlled - tapping does not move the selection '
        'on its own', (tester) async {
      await pumpDashWidget(
        tester,
        DashNavigationbar(selectedIndex: 1, onDestinationSelected: (_) {}),
      );

      await tester.tap(find.text('Profile'));
      await tester.pumpAndSettle();

      // The parent owns the index; the bar must still render what it was
      // given, or the UI would briefly disagree with the app's real route.
      expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
        1,
      );
    });

    testWidgets('re-selecting the current destination still reports it',
        (tester) async {
      final selected = <int>[];
      await pumpDashWidget(
        tester,
        DashNavigationbar(
          selectedIndex: 1,
          onDestinationSelected: selected.add,
        ),
      );

      await tester.tap(find.text('Home'));
      await tester.pumpAndSettle();

      // Screens use this to pop to the root of an already-active tab.
      expect(selected, [1]);
    });
  });
}
