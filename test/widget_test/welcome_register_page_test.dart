import 'package:dash/screens/user_setup_page.dart';
import 'package:dash/screens/welcome_register_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/pump_app.dart';

/// The interstitial between signing up and setting up a profile. Small, but
/// it is the only route onward — a dead button here strands a brand-new user
/// with no way into the app.
void main() {
  Future<void> pumpPage(WidgetTester tester) => pumpDashWidget(
        tester,
        const WelcomeRegisterScreen(),
        wrapInScaffold: false,
        surfaceSize: kPhoneSurface,
      );

  testWidgets('welcomes the new user', (tester) async {
    await pumpPage(tester);

    expect(find.textContaining('Welcome to'), findsOneWidget);
    expect(
      find.text("You're almost ready, let's get to know each other!"),
      findsOneWidget,
    );
  });

  testWidgets('offers the way onward', (tester) async {
    await pumpPage(tester);

    expect(find.text('Setup your profile'), findsOneWidget);
  });

  testWidgets('the button is live, not decorative', (tester) async {
    // The failure this guards against is a `onPressed: () {}` stub, which
    // renders identically to a working button. `error_page.dart` has exactly
    // that bug today (it is unreferenced, so it does not matter there).
    await pumpPage(tester);

    final button = tester.widget<ElevatedButton>(
      find.ancestor(
        of: find.text('Setup your profile'),
        matching: find.byType(ElevatedButton),
      ),
    );
    expect(button.onPressed, isNotNull);
  });

  testWidgets('it leads to profile setup', (tester) async {
    await pumpPage(tester);

    await tester.tap(find.text('Setup your profile'));
    await tester.pumpAndSettle();

    expect(find.byType(UserSetupScreen), findsOneWidget);
    expect(find.byType(WelcomeRegisterScreen), findsNothing);
  });

  testWidgets('it replaces this route rather than stacking on it',
      (tester) async {
    // pushReplacement, so back does not return to a welcome screen the user
    // has already passed.
    await pumpPage(tester);

    await tester.tap(find.text('Setup your profile'));
    await tester.pumpAndSettle();

    expect(find.byType(WelcomeRegisterScreen), findsNothing);
  });
}
