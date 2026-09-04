import 'package:dash/config/app_theme.dart';
import 'package:dash/screens/login_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  /// The login screen on a realistic phone viewport.
  ///
  /// No Firebase is initialised here, and that is deliberate rather than a
  /// limitation: the page builds its own `AuthService` in a field
  /// initializer, so nothing can be injected into it. What that buys is a
  /// real test of the paths that must work *without* a successful sign-in —
  /// local validation, the visibility toggle, and the error branch — which is
  /// where the bugs a user actually hits tend to live.
  Future<void> pumpPage(WidgetTester tester) async {
    // 500pt wide, not a phone's 390, and the reason is the test font rather
    // than anything about this page. `flutter test` renders every glyph as a
    // full em square, so "Continue with Google" at 15px measures 300px here
    // against roughly 145px on a real device — the Google button reports a
    // RenderFlex overflow below ~480pt that simply does not happen in the
    // app. Widening the viewport sidesteps the artifact so these tests
    // exercise behaviour, which is what they are for. Layout width is not
    // asserted here for exactly that reason.
    tester.view.physicalSize = const Size(500, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      MaterialApp(theme: buildAppTheme(), home: const LoginScreen()),
    );
    await tester.pumpAndSettle();
  }

  Finder emailField() => find.byType(TextField).first;
  Finder passwordField() => find.byType(TextField).at(1);

  group('layout', () {
    testWidgets('shows the brand and tagline', (tester) async {
      await pumpPage(tester);

      expect(find.text('DASH'), findsOneWidget);
      expect(find.textContaining('blank map'), findsOneWidget);
    });

    testWidgets('offers an email and a password field', (tester) async {
      await pumpPage(tester);

      expect(find.byType(TextField), findsNWidgets(2));
      expect(find.text('youremail@domain.com'), findsOneWidget);
      expect(find.text('Type your password'), findsOneWidget);
    });

    testWidgets('offers Google sign-in as an alternative', (tester) async {
      await pumpPage(tester);

      expect(find.text('Continue with Google'), findsOneWidget);
    });
  });

  group('password visibility', () {
    testWidgets('is obscured to begin with', (tester) async {
      await pumpPage(tester);

      expect(tester.widget<TextField>(passwordField()).obscureText, isTrue);
      expect(find.byIcon(Icons.visibility_off_outlined), findsOneWidget);
    });

    testWidgets('the eye reveals it', (tester) async {
      await pumpPage(tester);

      await tester.tap(find.byIcon(Icons.visibility_off_outlined));
      await tester.pumpAndSettle();

      expect(tester.widget<TextField>(passwordField()).obscureText, isFalse);
      expect(find.byIcon(Icons.visibility_outlined), findsOneWidget);
    });

    testWidgets('tapping again hides it', (tester) async {
      await pumpPage(tester);

      await tester.tap(find.byIcon(Icons.visibility_off_outlined));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.visibility_outlined));
      await tester.pumpAndSettle();

      expect(tester.widget<TextField>(passwordField()).obscureText, isTrue);
    });

    testWidgets('the email field is never obscured', (tester) async {
      await pumpPage(tester);

      expect(tester.widget<TextField>(emailField()).obscureText, isFalse);
    });
  });

  group('local validation', () {
    // These run entirely before any network call, so they are the one part of
    // sign-in that must never depend on Firebase being reachable.
    Future<void> submit(WidgetTester tester) async {
      await tester.tap(find.text("Let's go"));
      await tester.pump();
    }

    testWidgets('refuses an empty form', (tester) async {
      await pumpPage(tester);

      await submit(tester);

      expect(find.text('Enter email and password'), findsOneWidget);
    });

    testWidgets('refuses an email with no password', (tester) async {
      await pumpPage(tester);

      await tester.enterText(emailField(), 'runner@example.com');
      await submit(tester);

      expect(find.text('Enter email and password'), findsOneWidget);
    });

    testWidgets('refuses a password with no email', (tester) async {
      await pumpPage(tester);

      await tester.enterText(passwordField(), 'hunter2');
      await submit(tester);

      expect(find.text('Enter email and password'), findsOneWidget);
    });

    testWidgets('treats a whitespace-only email as empty', (tester) async {
      // The email is trimmed before the check, so spaces must not count as
      // input - otherwise the app would attempt a sign-in guaranteed to fail.
      await pumpPage(tester);

      await tester.enterText(emailField(), '   ');
      await tester.enterText(passwordField(), 'hunter2');
      await submit(tester);

      expect(find.text('Enter email and password'), findsOneWidget);
    });

    testWidgets('shows no error before the user submits', (tester) async {
      await pumpPage(tester);

      expect(find.text('Enter email and password'), findsNothing);
    });

    testWidgets('the error clears once a complete form is submitted',
        (tester) async {
      await pumpPage(tester);
      await submit(tester);
      expect(find.text('Enter email and password'), findsOneWidget);

      await tester.enterText(emailField(), 'runner@example.com');
      await tester.enterText(passwordField(), 'hunter2');
      await submit(tester);
      await tester.pumpAndSettle();

      // The local complaint must go, whatever the sign-in itself then does.
      expect(find.text('Enter email and password'), findsNothing);
    });
  });

  group('sign-in failure', () {
    testWidgets('reports a failure instead of hanging on the spinner',
        (tester) async {
      // With no Firebase app the call throws, which stands in for any
      // real-world failure. What matters is that the page recovers: it must
      // surface a message and re-enable the button, not spin forever.
      await pumpPage(tester);

      await tester.enterText(emailField(), 'runner@example.com');
      await tester.enterText(passwordField(), 'hunter2');
      await tester.tap(find.text("Let's go"));
      await tester.pumpAndSettle();

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(
        tester
            .widget<ElevatedButton>(
              find.ancestor(
                of: find.text("Let's go"),
                matching: find.byType(ElevatedButton),
              ),
            )
            .onPressed,
        isNotNull,
      );
    });

    testWidgets('the message is human-readable, not a raw exception',
        (tester) async {
      await pumpPage(tester);

      await tester.enterText(emailField(), 'runner@example.com');
      await tester.enterText(passwordField(), 'hunter2');
      await tester.tap(find.text("Let's go"));
      await tester.pumpAndSettle();

      expect(find.textContaining('Exception'), findsNothing);
      expect(find.text('Something went wrong. Try again.'), findsOneWidget);
    });
  });
}
