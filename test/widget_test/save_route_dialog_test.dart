import 'package:dash/widgets/save_route_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../helpers/pump_app.dart';

void main() {
  /// Opens the dialog from a real route so `Navigator.pop` has somewhere to
  /// go, and hands back the future carrying the user's choice.
  Future<Future<SaveRouteChoice?>> openDialog(
    WidgetTester tester, {
    bool offerRun = true,
  }) async {
    late Future<SaveRouteChoice?> result;

    await pumpDashWidget(
      tester,
      Builder(
        builder: (context) => ElevatedButton(
          onPressed: () =>
              result = showSaveRouteDialog(context, offerRun: offerRun),
          child: const Text('open'),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    return result;
  }

  group('showSaveRouteDialog', () {
    testWidgets('states that the choice is permanent', (tester) async {
      await openDialog(tester);

      // The dialog is the only place visibility can ever be set, so it has to
      // say so - there is no toggle anywhere afterwards.
      expect(find.text("This can't be changed later."), findsOneWidget);
    });

    group('defaults to private', () {
      testWidgets('the switch starts off', (tester) async {
        await openDialog(tester);

        expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
        expect(find.text('Private'), findsOneWidget);
        expect(find.text('Only you can see this route.'), findsOneWidget);
      });

      testWidgets('saving without touching anything yields isPublic false',
          (tester) async {
        // The security-relevant default: a user who never reads the dialog
        // gets the safer outcome.
        final result = await openDialog(tester);

        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();

        expect((await result)!.isPublic, isFalse);
      });
    });

    group('publishing', () {
      testWidgets('the switch relabels the route as public', (tester) async {
        await openDialog(tester);

        await tester.tap(find.byType(Switch));
        await tester.pumpAndSettle();

        expect(find.text('Public'), findsOneWidget);
        expect(
          find.text('Anyone can see this route on your profile.'),
          findsOneWidget,
        );
      });

      testWidgets('carries isPublic true out of the dialog', (tester) async {
        final result = await openDialog(tester);

        await tester.tap(find.byType(Switch));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();

        final choice = (await result)!;
        expect(choice.isPublic, isTrue);
        expect(choice.action, SaveRouteAction.save);
      });

      testWidgets('toggling back to private is honoured', (tester) async {
        final result = await openDialog(tester);

        await tester.tap(find.byType(Switch));
        await tester.pumpAndSettle();
        await tester.tap(find.byType(Switch));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();

        expect((await result)!.isPublic, isFalse);
      });
    });

    group('actions', () {
      testWidgets('Save reports the save action', (tester) async {
        final result = await openDialog(tester);

        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();

        expect((await result)!.action, SaveRouteAction.save);
      });

      testWidgets('Save and Run reports the saveAndRun action',
          (tester) async {
        final result = await openDialog(tester);

        await tester.tap(find.text('Save and Run'));
        await tester.pumpAndSettle();

        expect((await result)!.action, SaveRouteAction.saveAndRun);
      });

      testWidgets('Save and Run keeps the visibility choice alongside it',
          (tester) async {
        final result = await openDialog(tester);

        await tester.tap(find.byType(Switch));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Save and Run'));
        await tester.pumpAndSettle();

        final choice = (await result)!;
        expect(choice.action, SaveRouteAction.saveAndRun);
        expect(choice.isPublic, isTrue);
      });

      testWidgets('Cancel yields null, not a default choice', (tester) async {
        // A null result is what tells the caller to save nothing at all.
        final result = await openDialog(tester);

        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();

        expect(await result, isNull);
      });

      testWidgets('offerRun false hides the run option', (tester) async {
        // Route search saves without running; only route creation offers it.
        await openDialog(tester, offerRun: false);

        expect(find.text('Save and Run'), findsNothing);
        expect(find.text('Save'), findsOneWidget);
        expect(find.text('Cancel'), findsOneWidget);
      });
    });
  });

  group('RouteVisibilityInfo', () {
    testWidgets('a private route shows a padlock', (tester) async {
      await pumpDashWidget(
        tester,
        const RouteVisibilityInfo(isPublic: false),
      );

      expect(find.byIcon(Symbols.lock_rounded), findsOneWidget);
      expect(find.byIcon(Symbols.public_rounded), findsNothing);
    });

    testWidgets('a public route shows the globe', (tester) async {
      await pumpDashWidget(
        tester,
        const RouteVisibilityInfo(isPublic: true),
      );

      expect(find.byIcon(Symbols.public_rounded), findsOneWidget);
      expect(find.byIcon(Symbols.lock_rounded), findsNothing);
    });

    testWidgets('showLabel false drops the heading but keeps the sentence',
        (tester) async {
      // How the route detail page renders it: with nothing to set, a bold
      // "Private" heading only repeats the line beneath it.
      await pumpDashWidget(
        tester,
        const RouteVisibilityInfo(isPublic: false, showLabel: false),
      );

      expect(find.text('Private'), findsNothing);
      expect(find.text('Only you can see this route.'), findsOneWidget);
    });
  });

  group('RouteVisibilitySwitch', () {
    testWidgets('reports the inverse of its current value', (tester) async {
      final changes = <bool>[];
      await pumpDashWidget(
        tester,
        RouteVisibilitySwitch(isPublic: false, onChanged: changes.add),
      );

      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();

      expect(changes, [true]);
    });

    testWidgets('is fully controlled - it does not flip itself',
        (tester) async {
      await pumpDashWidget(
        tester,
        RouteVisibilitySwitch(isPublic: false, onChanged: (_) {}),
      );

      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();

      expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
    });
  });
}
