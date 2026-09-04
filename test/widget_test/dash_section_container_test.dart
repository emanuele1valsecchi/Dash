import 'package:dash/widgets/dash_section_container.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../helpers/pump_app.dart';

void main() {
  group('DashSectionContainer', () {
    testWidgets('renders its title above its child', (tester) async {
      await pumpDashWidget(
        tester,
        const DashSectionContainer(
          title: 'My Routes',
          child: Text('a route card'),
        ),
      );

      expect(find.text('My Routes'), findsOneWidget);
      expect(find.text('a route card'), findsOneWidget);

      expect(
        tester.getTopLeft(find.text('My Routes')).dy,
        lessThan(tester.getTopLeft(find.text('a route card')).dy),
      );
    });

    testWidgets('shows the forward chevron by default', (tester) async {
      await pumpDashWidget(
        tester,
        const DashSectionContainer(title: 'My Routes', child: SizedBox()),
      );

      expect(find.byIcon(Symbols.arrow_forward_ios_rounded), findsOneWidget);
    });

    testWidgets('hides the chevron for a section that leads nowhere',
        (tester) async {
      await pumpDashWidget(
        tester,
        const DashSectionContainer(
          title: 'My Routes',
          hasForwardIcon: false,
          child: SizedBox(),
        ),
      );

      expect(find.byIcon(Symbols.arrow_forward_ios_rounded), findsNothing);
    });

    group('leading icon', () {
      testWidgets('is omitted when none is given', (tester) async {
        await pumpDashWidget(
          tester,
          const DashSectionContainer(title: 'My Routes', child: SizedBox()),
        );

        // Only the forward chevron should be present.
        expect(find.byType(Icon), findsOneWidget);
      });

      testWidgets('is rendered when given', (tester) async {
        await pumpDashWidget(
          tester,
          const DashSectionContainer(
            title: 'My Routes',
            leadingIcon: Symbols.route_rounded,
            child: SizedBox(),
          ),
        );

        expect(find.byIcon(Symbols.route_rounded), findsOneWidget);
      });

      testWidgets('is drawn filled when asked', (tester) async {
        await pumpDashWidget(
          tester,
          const DashSectionContainer(
            title: 'My Routes',
            leadingIcon: Symbols.route_rounded,
            leadingIconFilled: true,
            child: SizedBox(),
          ),
        );

        expect(
          tester.widget<Icon>(find.byIcon(Symbols.route_rounded)).fill,
          1.0,
        );
      });

      testWidgets('is drawn unfilled by default', (tester) async {
        await pumpDashWidget(
          tester,
          const DashSectionContainer(
            title: 'My Routes',
            leadingIcon: Symbols.route_rounded,
            child: SizedBox(),
          ),
        );

        expect(
          tester.widget<Icon>(find.byIcon(Symbols.route_rounded)).fill,
          0.0,
        );
      });
    });

    group('tap target', () {
      testWidgets('fires onTap from anywhere in the section', (tester) async {
        var taps = 0;
        await pumpDashWidget(
          tester,
          DashSectionContainer(
            title: 'My Routes',
            onTap: () => taps++,
            child: const SizedBox(height: 40),
          ),
        );

        // The header is opaque to hit testing, so the whole block is the
        // target, not just the chevron.
        await tester.tap(find.text('My Routes'));
        await tester.pump();

        expect(taps, 1);
      });

      testWidgets('is inert when no onTap is given', (tester) async {
        await pumpDashWidget(
          tester,
          const DashSectionContainer(title: 'My Routes', child: SizedBox()),
        );

        await tester.tap(find.text('My Routes'));
        await tester.pump();

        expect(tester.takeException(), isNull);
      });
    });

    group('withFadeEdge', () {
      testWidgets('makes its child horizontally scrollable', (tester) async {
        await pumpDashWidget(
          tester,
          const DashSectionContainer.withFadeEdge(
            title: 'My Routes',
            child: SizedBox(width: 2000, height: 40),
          ),
          surfaceSize: kPhoneSurface,
        );

        final scroll = tester.widget<SingleChildScrollView>(
          find.byType(SingleChildScrollView),
        );
        expect(scroll.scrollDirection, Axis.horizontal);
        expect(tester.takeException(), isNull);
      });

      testWidgets('the plain constructor does not scroll', (tester) async {
        await pumpDashWidget(
          tester,
          const DashSectionContainer(
            title: 'My Routes',
            child: SizedBox(height: 40),
          ),
          surfaceSize: kPhoneSurface,
        );

        expect(find.byType(SingleChildScrollView), findsNothing);
      });
    });
  });
}
