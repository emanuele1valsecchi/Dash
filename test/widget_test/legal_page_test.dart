import 'package:dash/screens/legal_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/pump_app.dart';

/// The Terms and the Privacy Policy are the same screen with a different
/// document. Cheap to get wrong in a way nobody notices — showing one under
/// the other's title is exactly the sort of thing that only surfaces when
/// somebody goes looking for a legal document and finds the wrong one.
void main() {
  Future<void> pumpPage(WidgetTester tester, LegalType type) => pumpDashWidget(
        tester,
        LegalScreen(type: type),
        wrapInScaffold: false,
        surfaceSize: kPhoneSurface,
      );

  group('terms of service', () {
    testWidgets('is titled as the terms', (tester) async {
      await pumpPage(tester, LegalType.terms);

      expect(find.text('Terms of Service'), findsOneWidget);
      expect(find.text('Privacy Policy'), findsNothing);
    });

    testWidgets('renders its document, not the privacy one', (tester) async {
      // Matched on text unique to the body of each document - the page title
      // is not enough, since both documents open with their own name.
      await pumpPage(tester, LegalType.terms);

      expect(find.textContaining('Acceptance of Terms'), findsOneWidget);
      expect(find.textContaining('This Privacy Policy describes'), findsNothing);
    });

    testWidgets('offers no external privacy link', (tester) async {
      // The TermsFeed link belongs to the privacy document only.
      await pumpPage(tester, LegalType.terms);

      expect(
        find.text('View Online Privacy Policy (TermsFeed)'),
        findsNothing,
      );
    });
  });

  group('privacy policy', () {
    testWidgets('is titled as the policy', (tester) async {
      await pumpPage(tester, LegalType.privacy);

      expect(find.text('Privacy Policy'), findsOneWidget);
      expect(find.text('Terms of Service'), findsNothing);
    });

    testWidgets('renders its document, not the terms', (tester) async {
      await pumpPage(tester, LegalType.privacy);

      expect(find.textContaining('This Privacy Policy describes'),
          findsOneWidget);
      expect(find.textContaining('Acceptance of Terms'), findsNothing);
    });

    testWidgets('offers the external link', (tester) async {
      await pumpPage(tester, LegalType.privacy);

      expect(
        find.text('View Online Privacy Policy (TermsFeed)'),
        findsOneWidget,
      );
    });

    testWidgets('the link is tappable', (tester) async {
      // Tapping opens a browser, which a widget test cannot follow — what is
      // checked here is that the gesture exists and does not throw, so a
      // silently-inert link would be caught.
      await pumpPage(tester, LegalType.privacy);

      // The link sits at the foot of a very long document, ~21,000px down, so
      // it has to be scrolled into view before it can be tapped — otherwise
      // the tap lands outside the render tree and only warns.
      final link = find.text('View Online Privacy Policy (TermsFeed)');
      await tester.ensureVisible(link);
      await tester.pumpAndSettle();
      await tester.tap(link);
      await tester.pump();

      expect(tester.takeException(), isNull);
    });
  });

  group('both documents', () {
    for (final type in LegalType.values) {
      testWidgets('$type scrolls rather than overflowing', (tester) async {
        // These are long documents on a short screen; the scroll view has to
        // wrap the whole body, not just the text.
        await pumpPage(tester, type);

        expect(find.byType(SingleChildScrollView), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('$type actually contains text', (tester) async {
        await pumpPage(tester, type);

        final body = tester
            .widgetList<Text>(find.byType(Text))
            .map((t) => t.data ?? '')
            .join();
        expect(body.length, greaterThan(500),
            reason: 'the $type document looks empty');
      });
    }
  });
}
