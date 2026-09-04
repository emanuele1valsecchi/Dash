import 'package:dash/widgets/rename_route_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/pump_app.dart';

void main() {
  /// Opens the rename prompt from a real route and hands back the future
  /// carrying the new name.
  Future<Future<String?>> openDialog(
    WidgetTester tester, {
    String initialName = 'Morning loop',
  }) async {
    late Future<String?> result;

    await pumpDashWidget(
      tester,
      Builder(
        builder: (context) => ElevatedButton(
          onPressed: () =>
              result = showRenameRouteDialog(context, initialName: initialName),
          child: const Text('open'),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    return result;
  }

  group('showRenameRouteDialog', () {
    testWidgets('opens with the current name already in the field',
        (tester) async {
      await openDialog(tester);

      expect(find.text('Rename route'), findsOneWidget);
      expect(find.text('Morning loop'), findsOneWidget);
    });

    testWidgets('preselects the name so typing replaces it', (tester) async {
      // A rename usually means replacing the whole name, not appending to it.
      await openDialog(tester);

      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller!.selection.baseOffset, 0);
      expect(
        field.controller!.selection.extentOffset,
        'Morning loop'.length,
      );
    });

    testWidgets('returns the new name on Save', (tester) async {
      final result = await openDialog(tester);

      await tester.enterText(find.byType(TextField), 'Evening loop');
      await tester.pump();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(await result, 'Evening loop');
    });

    testWidgets('trims surrounding whitespace off the new name',
        (tester) async {
      final result = await openDialog(tester);

      await tester.enterText(find.byType(TextField), '  Evening loop  ');
      await tester.pump();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(await result, 'Evening loop');
    });

    testWidgets('submitting from the keyboard saves too', (tester) async {
      final result = await openDialog(tester);

      await tester.enterText(find.byType(TextField), 'Evening loop');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(await result, 'Evening loop');
    });

    testWidgets('Cancel returns null rather than the unchanged name',
        (tester) async {
      // Null is what tells the caller to write nothing at all - returning the
      // original name would cost a pointless Firestore write on every cancel.
      final result = await openDialog(tester);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(await result, isNull);
    });

    group('empty names are refused', () {
      testWidgets('Save is disabled when the field is emptied',
          (tester) async {
        await openDialog(tester);

        await tester.enterText(find.byType(TextField), '');
        await tester.pump();

        final save = tester.widget<TextButton>(
          find.ancestor(
            of: find.text('Save'),
            matching: find.byType(TextButton),
          ),
        );
        expect(save.onPressed, isNull);
      });

      testWidgets('Save is disabled for whitespace alone', (tester) async {
        await openDialog(tester);

        await tester.enterText(find.byType(TextField), '   ');
        await tester.pump();

        final save = tester.widget<TextButton>(
          find.ancestor(
            of: find.text('Save'),
            matching: find.byType(TextButton),
          ),
        );
        expect(save.onPressed, isNull);
      });

      testWidgets('submitting whitespace from the keyboard does nothing',
          (tester) async {
        await openDialog(tester);

        await tester.enterText(find.byType(TextField), '   ');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pumpAndSettle();

        // The dialog must still be open - a no-op, not a dismissal.
        expect(find.text('Rename route'), findsOneWidget);
      });

      testWidgets('Save re-enables once real text is typed', (tester) async {
        await openDialog(tester);

        await tester.enterText(find.byType(TextField), '');
        await tester.pump();
        await tester.enterText(find.byType(TextField), 'Evening loop');
        await tester.pump();

        final save = tester.widget<TextButton>(
          find.ancestor(
            of: find.text('Save'),
            matching: find.byType(TextButton),
          ),
        );
        expect(save.onPressed, isNotNull);
      });
    });

    testWidgets('caps the name at the length the Cloud Function allows',
        (tester) async {
      await openDialog(tester);

      expect(
        tester.widget<TextField>(find.byType(TextField)).maxLength,
        kMaxRouteNameLength,
      );
    });

    // The regression this widget exists for: the naive version disposes the
    // controller when showDialog's future completes, which is when the exit
    // transition *starts* - the TextField is still mounted and bound to it.
    // The crash surfaces as an unrelated-looking `dependents.isEmpty`
    // assertion, so it is worth pinning down explicitly.
    testWidgets('survives its own exit transition without a disposal crash',
        (tester) async {
      final result = await openDialog(tester);

      await tester.tap(find.text('Save'));
      // Pump *through* the transition one frame at a time rather than
      // settling straight past it.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(await result, 'Morning loop');
    });

    testWidgets('handles being opened on a route with an empty name',
        (tester) async {
      await openDialog(tester, initialName: '');

      final save = tester.widget<TextButton>(
        find.ancestor(of: find.text('Save'), matching: find.byType(TextButton)),
      );
      expect(save.onPressed, isNull);
      expect(tester.takeException(), isNull);
    });
  });
}
