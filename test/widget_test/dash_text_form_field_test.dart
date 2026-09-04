import 'package:dash/widgets/dash_text_form_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';

import '../helpers/pump_app.dart';

void main() {
  group('DashTextFormField', () {
    testWidgets('renders its label and hint', (tester) async {
      await pumpDashWidget(
        tester,
        const DashTextFormField(label: 'Route name', hintText: 'Morning loop'),
      );

      expect(find.text('Route name'), findsOneWidget);
      expect(find.text('Morning loop'), findsOneWidget);
    });

    testWidgets('reports every keystroke through onChanged', (tester) async {
      final seen = <String>[];
      await pumpDashWidget(
        tester,
        DashTextFormField(onChanged: seen.add),
      );

      await tester.enterText(find.byType(TextFormField), 'Park');
      await tester.pump();

      expect(seen.last, 'Park');
    });

    group('clear button', () {
      testWidgets('is absent while the field is empty', (tester) async {
        await pumpDashWidget(
          tester,
          const DashTextFormField(clearOption: true),
        );

        expect(find.byIcon(Symbols.clear_rounded), findsNothing);
      });

      testWidgets('appears once there is text to clear', (tester) async {
        await pumpDashWidget(
          tester,
          const DashTextFormField(clearOption: true),
        );

        await tester.enterText(find.byType(TextFormField), 'Park');
        await tester.pump();

        expect(find.byIcon(Symbols.clear_rounded), findsOneWidget);
      });

      testWidgets('empties the field and disappears again when tapped',
          (tester) async {
        final controller = TextEditingController();
        addTearDown(controller.dispose);

        await pumpDashWidget(
          tester,
          DashTextFormField(clearOption: true, controller: controller),
        );

        await tester.enterText(find.byType(TextFormField), 'Park');
        await tester.pump();
        await tester.tap(find.byIcon(Symbols.clear_rounded));
        await tester.pump();

        expect(controller.text, isEmpty);
        expect(find.byIcon(Symbols.clear_rounded), findsNothing);
      });

      testWidgets('never appears when clearOption is off', (tester) async {
        await pumpDashWidget(tester, const DashTextFormField());

        await tester.enterText(find.byType(TextFormField), 'Park');
        await tester.pump();

        expect(find.byIcon(Symbols.clear_rounded), findsNothing);
      });
    });

    group('character limit', () {
      testWidgets('defaults to 20 for a single-line field', (tester) async {
        await pumpDashWidget(tester, const DashTextFormField());

        expect(tester.widget<TextField>(find.byType(TextField)).maxLength, 20);
      });

      testWidgets('defaults to 100 for a largeText field', (tester) async {
        await pumpDashWidget(tester, const DashTextFormField(largeText: true));

        final field = tester.widget<TextField>(find.byType(TextField));
        expect(field.maxLength, 100);
        expect(field.maxLines, 4);
      });

      testWidgets('an explicit maxLength wins over the default',
          (tester) async {
        await pumpDashWidget(tester, const DashTextFormField(maxLength: 7));

        expect(tester.widget<TextField>(find.byType(TextField)).maxLength, 7);
      });

      testWidgets('charactersCounter: false drops the limit entirely',
          (tester) async {
        // With no counter and no explicit maxLength there must be no cap at
        // all - falling back to the 20-char default would silently truncate
        // a field whose whole point is being unbounded.
        await pumpDashWidget(
          tester,
          const DashTextFormField(charactersCounter: false),
        );

        expect(
          tester.widget<TextField>(find.byType(TextField)).maxLength,
          isNull,
        );
      });
    });

    group('validation', () {
      testWidgets('surfaces the validator message after user interaction',
          (tester) async {
        await pumpDashWidget(
          tester,
          Form(
            child: DashTextFormField(
              validator: (v) => (v == null || v.isEmpty) ? 'Required' : null,
            ),
          ),
        );

        await tester.enterText(find.byType(TextFormField), 'a');
        await tester.pump();
        await tester.enterText(find.byType(TextFormField), '');
        await tester.pump();

        expect(find.text('Required'), findsOneWidget);
      });

      testWidgets('shows no error for a value the validator accepts',
          (tester) async {
        await pumpDashWidget(
          tester,
          Form(
            child: DashTextFormField(
              validator: (v) => (v == null || v.isEmpty) ? 'Required' : null,
            ),
          ),
        );

        await tester.enterText(find.byType(TextFormField), 'Morning loop');
        await tester.pump();

        expect(find.text('Required'), findsNothing);
      });
    });

    group('controller ownership', () {
      // This is the crash class documented in CLAUDE.md around
      // `_RenameRouteDialog`: disposing a controller the widget does not own
      // tears it out from under whoever passed it in.
      testWidgets('leaves a caller-supplied controller usable after disposal',
          (tester) async {
        final controller = TextEditingController(text: 'Morning loop');
        addTearDown(controller.dispose);

        await pumpDashWidget(
          tester,
          DashTextFormField(controller: controller),
        );
        // Replace the field with something else, disposing its State.
        await pumpDashWidget(tester, const SizedBox());

        // If the widget had disposed a controller it did not own, touching it
        // here would throw a "used after being disposed" FlutterError.
        expect(() => controller.text = 'Evening loop', returnsNormally);
        expect(controller.text, 'Evening loop');
      });

      testWidgets('adopts the text already in a caller-supplied controller',
          (tester) async {
        final controller = TextEditingController(text: 'Morning loop');
        addTearDown(controller.dispose);

        await pumpDashWidget(
          tester,
          DashTextFormField(controller: controller),
        );

        expect(find.text('Morning loop'), findsOneWidget);
      });

      testWidgets('manages its own controller when none is given',
          (tester) async {
        await pumpDashWidget(tester, const DashTextFormField());

        await tester.enterText(find.byType(TextFormField), 'Park');
        await tester.pump();
        // Unmounting must dispose the internal controller without error.
        await pumpDashWidget(tester, const SizedBox());

        expect(tester.takeException(), isNull);
      });
    });

    group('width', () {
      // Aligned rather than dropped straight into the Scaffold body: the body
      // is laid out with *tight* constraints, which would stretch the width
      // the widget asks for back out to the full screen and make the
      // assertion vacuous. A real caller puts this in a Column or ListView,
      // both of which pass loose width constraints, as Align does here.
      testWidgets('takes the given fraction of screen width', (tester) async {
        await pumpDashWidget(
          tester,
          const Align(
            alignment: Alignment.topLeft,
            child: DashTextFormField(widthFactor: 0.5),
          ),
          surfaceSize: kPhoneSurface,
        );

        // The nearest SizedBox above the field is the one the widget inserts;
        // matching byType alone picks up Scaffold's own internal boxes.
        final sizer = find
            .ancestor(
              of: find.byType(TextFormField),
              matching: find.byType(SizedBox),
            )
            .first;
        expect(tester.getSize(sizer).width, kPhoneSurface.width * 0.5);
      });

      testWidgets('is unconstrained at a factor of 1.0', (tester) async {
        await pumpDashWidget(
          tester,
          const Align(
            alignment: Alignment.topLeft,
            child: DashTextFormField(widthFactor: 1.0),
          ),
          surfaceSize: kPhoneSurface,
        );

        // No sizing SizedBox is inserted at all above the form field.
        expect(
          find.ancestor(
            of: find.byType(TextFormField),
            matching: find.byType(SizedBox),
          ),
          findsNothing,
        );
      });
    });
  });
}
