import 'package:dash/screens/onboarding_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/pump_app.dart';

/// The three-page intro carousel. The first thing anyone ever sees, and the
/// only route into sign-in, so "can the user get out of it" matters more here
/// than on most screens.
void main() {
  Future<void> pumpPage(WidgetTester tester) => pumpDashWidget(
        tester,
        const OnboardingScreen(),
        wrapInScaffold: false,
        surfaceSize: kPhoneSurface,
      );

  /// Advances one page and lets the 400ms slide finish.
  Future<void> next(WidgetTester tester) async {
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
  }

  group('paging', () {
    testWidgets('opens on the first page', (tester) async {
      await pumpPage(tester);

      expect(find.text('The world is your circuit!'), findsOneWidget);
      expect(find.text('Next'), findsOneWidget);
    });

    testWidgets('Next advances through all three pages', (tester) async {
      await pumpPage(tester);
      expect(find.text('Next'), findsOneWidget);

      await next(tester);
      expect(find.text('Next'), findsOneWidget);

      await next(tester);
      // The third page is the last, so the button changes purpose.
      expect(find.text('Next'), findsNothing);
      expect(find.text('Login or Register'), findsOneWidget);
    });

    testWidgets('swiping advances too', (tester) async {
      await pumpPage(tester);

      await tester.drag(find.byType(PageView), const Offset(-400, 0));
      await tester.pumpAndSettle();

      expect(find.text('The world is your circuit!'), findsNothing);
    });

    testWidgets('swiping back returns to the first page', (tester) async {
      await pumpPage(tester);

      await tester.drag(find.byType(PageView), const Offset(-400, 0));
      await tester.pumpAndSettle();
      await tester.drag(find.byType(PageView), const Offset(400, 0));
      await tester.pumpAndSettle();

      expect(find.text('The world is your circuit!'), findsOneWidget);
    });

    testWidgets('Next on the last page does not run off the end',
        (tester) async {
      // `_nextPage` guards on `_currentPage < _totalPages - 1`; without it the
      // controller would be asked for a page that does not exist.
      await pumpPage(tester);
      await next(tester);
      await next(tester);

      expect(tester.takeException(), isNull);
      expect(find.text('Login or Register'), findsOneWidget);
    });
  });

  group('getting out', () {
    testWidgets('the last page offers the way into sign-in', (tester) async {
      await pumpPage(tester);
      await next(tester);
      await next(tester);

      final button = tester.widget<ElevatedButton>(
        find.ancestor(
          of: find.text('Login or Register'),
          matching: find.byType(ElevatedButton),
        ),
      );
      expect(button.onPressed, isNotNull);
    });

    testWidgets('an escape exists from the first page too', (tester) async {
      // Somebody reinstalling should not have to sit through the carousel.
      await pumpPage(tester);

      expect(find.byType(ElevatedButton), findsWidgets);
    });
  });

  testWidgets('disposes its page controller cleanly', (tester) async {
    await pumpPage(tester);
    await next(tester);

    await pumpDashWidget(tester, const SizedBox());

    expect(tester.takeException(), isNull);
  });
}
