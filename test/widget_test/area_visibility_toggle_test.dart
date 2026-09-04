import 'package:dash/widgets/map/area_visibility_toggle.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/pump_app.dart';

void main() {
  group('AreaVisibilityToggle', () {
    /// The panel under test with both toggles on and their callbacks
    /// recording into [events].
    Widget subject({
      bool showOtherAreas = true,
      bool showMyAreas = true,
      required List<String> events,
    }) {
      return AreaVisibilityToggle(
        showOtherAreas: showOtherAreas,
        showMyAreas: showMyAreas,
        onShowOtherAreasChanged: (v) => events.add('other:$v'),
        onShowMyAreasChanged: (v) => events.add('mine:$v'),
      );
    }

    testWidgets('offers both ownership toggles', (tester) async {
      await pumpDashWidget(tester, subject(events: []));

      expect(find.byIcon(Icons.grid_on_outlined), findsOneWidget);
      expect(find.byIcon(Icons.cable_outlined), findsOneWidget);
    });

    testWidgets('each button carries a tooltip naming what it hides',
        (tester) async {
      await pumpDashWidget(tester, subject(events: []));

      expect(find.byTooltip("Show other users' areas"), findsOneWidget);
      expect(find.byTooltip('Show my areas'), findsOneWidget);
    });

    group('reports the inverse of its current state', () {
      // The widget is fully controlled: it never flips its own state, it
      // asks the screen to. Reporting the *current* value instead of the
      // inverse would make the button a no-op.
      testWidgets('turning other users\' areas off', (tester) async {
        final events = <String>[];
        await pumpDashWidget(tester, subject(events: events));

        await tester.tap(find.byIcon(Icons.grid_on_outlined));
        await tester.pump();

        expect(events, ['other:false']);
      });

      testWidgets('turning other users\' areas back on', (tester) async {
        final events = <String>[];
        await pumpDashWidget(
          tester,
          subject(showOtherAreas: false, events: events),
        );

        await tester.tap(find.byIcon(Icons.grid_on_outlined));
        await tester.pump();

        expect(events, ['other:true']);
      });

      testWidgets('turning my own areas off', (tester) async {
        final events = <String>[];
        await pumpDashWidget(tester, subject(events: events));

        await tester.tap(find.byIcon(Icons.cable_outlined));
        await tester.pump();

        expect(events, ['mine:false']);
      });

      testWidgets('turning my own areas back on', (tester) async {
        final events = <String>[];
        await pumpDashWidget(
          tester,
          subject(showMyAreas: false, events: events),
        );

        await tester.tap(find.byIcon(Icons.cable_outlined));
        await tester.pump();

        expect(events, ['mine:true']);
      });
    });

    testWidgets('the two toggles are independent', (tester) async {
      final events = <String>[];
      await pumpDashWidget(
        tester,
        subject(showOtherAreas: true, showMyAreas: false, events: events),
      );

      await tester.tap(find.byIcon(Icons.grid_on_outlined));
      await tester.pump();

      // Tapping one must not report anything about the other.
      expect(events, ['other:false']);
    });

    testWidgets('an inactive toggle is drawn in the muted colour',
        (tester) async {
      await pumpDashWidget(
        tester,
        subject(showOtherAreas: false, events: []),
      );

      final off = tester.widget<Icon>(find.byIcon(Icons.grid_on_outlined));
      final on = tester.widget<Icon>(find.byIcon(Icons.cable_outlined));

      expect(off.color, isNot(on.color));
    });
  });
}
