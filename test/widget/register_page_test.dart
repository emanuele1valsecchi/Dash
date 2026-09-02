import 'package:dash/config/app_theme.dart';
import 'package:dash/screens/register_page.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';

import '../mocks.mocks.dart';

/// Registration is a two-step wizard: email, then password. The password step
/// enforces four rules live, and only enables its button once all four pass —
/// which is the interesting part, because it is the app's entire defence
/// against a weak password.
void main() {
  late MockAuthService auth;
  late MockUserCredential credential;

  setUpAll(() async {
    // Registration navigates to `EmailConfirmationScreen`, which touches
    // Firebase in its own initState. See login_page_auth_flow_test.dart.
    TestWidgetsFlutterBinding.ensureInitialized();
    setupFirebaseCoreMocks();
    await Firebase.initializeApp();
  });

  setUp(() {
    auth = MockAuthService();
    credential = MockUserCredential();
  });

  Future<void> pumpPage(WidgetTester tester) async {
    // Wide, for the same test-font reason as the login screen.
    tester.view.physicalSize = const Size(500, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    addTearDown(() => tester.pumpWidget(const SizedBox()));

    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: RegisterScreen(authService: auth),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Advances, then drops any error thrown by the screen registration
  /// navigates *to*. Only Firebase initialisation complaints are tolerated.
  Future<void> settleAndIgnoreDestination(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    for (var i = 0; i < 100; i++) {
      final error = tester.takeException();
      if (error == null) return;
      final text = error.toString();
      if (!text.toLowerCase().contains('firebase') &&
          !text.contains('Multiple exceptions')) {
        fail('Unexpected error during registration: $error');
      }
    }
  }

  Finder nextButton() => find.byType(ElevatedButton).first;

  /// Fills in the email and moves to the password step.
  Future<void> goToPasswordStep(
    WidgetTester tester, {
    String email = 'runner@example.com',
  }) async {
    await tester.enterText(find.byType(TextField).first, email);
    await tester.tap(nextButton());
    await tester.pumpAndSettle();
  }

  group('the email step', () {
    testWidgets('is where the wizard starts', (tester) async {
      await pumpPage(tester);

      expect(find.text('youremail@domain.com'), findsOneWidget);
      // The password rules belong to the second step only.
      expect(
        find.text('Password must be at least 8 characters long'),
        findsNothing,
      );
    });

    testWidgets('rejects an empty email', (tester) async {
      await pumpPage(tester);

      await tester.tap(nextButton());
      await tester.pumpAndSettle();

      expect(find.text('Enter a valid email address'), findsOneWidget);
    });

    testWidgets('rejects an address with no @', (tester) async {
      await pumpPage(tester);

      await tester.enterText(find.byType(TextField).first, 'not-an-email');
      await tester.tap(nextButton());
      await tester.pumpAndSettle();

      expect(find.text('Enter a valid email address'), findsOneWidget);
    });

    testWidgets('rejects whitespace alone', (tester) async {
      await pumpPage(tester);

      await tester.enterText(find.byType(TextField).first, '   ');
      await tester.tap(nextButton());
      await tester.pumpAndSettle();

      expect(find.text('Enter a valid email address'), findsOneWidget);
    });

    testWidgets('advances to the password step on a valid address',
        (tester) async {
      await pumpPage(tester);

      await goToPasswordStep(tester);

      expect(
        find.text('Password must be at least 8 characters long'),
        findsOneWidget,
      );
      expect(find.text('Enter a valid email address'), findsNothing);
    });

    testWidgets('never contacts the auth service from this step',
        (tester) async {
      await pumpPage(tester);

      await goToPasswordStep(tester);

      verifyNever(auth.registerWithEmail(
        email: anyNamed('email'),
        password: anyNamed('password'),
      ));
    });
  });

  group('password rules', () {
    // All four must pass before the button is live. Each is asserted alone so
    // a failure names the rule that broke.
    Future<bool> buttonEnabledFor(WidgetTester tester, String password) async {
      await pumpPage(tester);
      await goToPasswordStep(tester);
      await tester.enterText(find.byType(TextField).first, password);
      await tester.pumpAndSettle();
      return tester.widget<ElevatedButton>(nextButton()).onPressed != null;
    }

    testWidgets('all four rules are listed', (tester) async {
      await pumpPage(tester);
      await goToPasswordStep(tester);

      expect(find.textContaining('at least 8 characters'), findsOneWidget);
      expect(find.textContaining('1 upper case letter'), findsOneWidget);
      expect(find.textContaining('1 number'), findsOneWidget);
      expect(find.textContaining('1 special character'), findsOneWidget);
    });

    testWidgets('the button starts disabled', (tester) async {
      await pumpPage(tester);
      await goToPasswordStep(tester);

      expect(tester.widget<ElevatedButton>(nextButton()).onPressed, isNull);
    });

    testWidgets('a password meeting every rule enables it', (tester) async {
      expect(await buttonEnabledFor(tester, 'Passw0rd!'), isTrue);
    });

    testWidgets('too short is refused', (tester) async {
      expect(await buttonEnabledFor(tester, 'Pa0!'), isFalse);
    });

    testWidgets('no upper case is refused', (tester) async {
      expect(await buttonEnabledFor(tester, 'passw0rd!'), isFalse);
    });

    testWidgets('no number is refused', (tester) async {
      expect(await buttonEnabledFor(tester, 'Password!'), isFalse);
    });

    testWidgets('no special character is refused', (tester) async {
      expect(await buttonEnabledFor(tester, 'Passw0rdd'), isFalse);
    });

    testWidgets('exactly 8 characters is accepted, not off by one',
        (tester) async {
      // 'Pas0wrd!' is exactly 8 characters and satisfies all four rules.
      expect(await buttonEnabledFor(tester, 'Pas0wrd!'), isTrue);
    });

    testWidgets('the password is obscured, with a reveal toggle',
        (tester) async {
      await pumpPage(tester);
      await goToPasswordStep(tester);

      expect(
        tester.widget<TextField>(find.byType(TextField).first).obscureText,
        isTrue,
      );

      await tester.tap(find.byIcon(Icons.visibility_off_outlined));
      await tester.pumpAndSettle();

      expect(
        tester.widget<TextField>(find.byType(TextField).first).obscureText,
        isFalse,
      );
    });
  });

  group('creating the account', () {
    Future<void> register(WidgetTester tester, {
      String email = 'runner@example.com',
      String password = 'Passw0rd!',
    }) async {
      await pumpPage(tester);
      await goToPasswordStep(tester, email: email);
      await tester.enterText(find.byType(TextField).first, password);
      await tester.pumpAndSettle();
      await tester.tap(nextButton());
      await settleAndIgnoreDestination(tester);
    }

    testWidgets('passes the collected email and password to the service',
        (tester) async {
      when(auth.registerWithEmail(
        email: anyNamed('email'),
        password: anyNamed('password'),
      )).thenAnswer((_) async => credential);

      await register(tester);

      verify(auth.registerWithEmail(
        email: 'runner@example.com',
        password: 'Passw0rd!',
      )).called(1);
    });

    testWidgets('trims the email but not the password', (tester) async {
      when(auth.registerWithEmail(
        email: anyNamed('email'),
        password: anyNamed('password'),
      )).thenAnswer((_) async => credential);

      await register(tester, email: '  runner@example.com  ');

      verify(auth.registerWithEmail(
        email: 'runner@example.com',
        password: 'Passw0rd!',
      )).called(1);
    });

    testWidgets('reports a rejected sign-up in plain language',
        (tester) async {
      when(auth.registerWithEmail(
        email: anyNamed('email'),
        password: anyNamed('password'),
      )).thenThrow(FirebaseAuthException(code: 'invalid-email'));

      await register(tester);

      expect(find.text('Invalid email address'), findsOneWidget);
      expect(find.textContaining('firebase_auth'), findsNothing);
    });

    testWidgets('leaves the user able to retry after a failure',
        (tester) async {
      when(auth.registerWithEmail(
        email: anyNamed('email'),
        password: anyNamed('password'),
      )).thenThrow(FirebaseAuthException(code: 'too-many-requests'));

      await register(tester);

      expect(find.byType(RegisterScreen), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(tester.widget<ElevatedButton>(nextButton()).onPressed, isNotNull);
    });
  });

  group('Google sign-up', () {
    testWidgets('asks the auth service exactly once', (tester) async {
      // Once, not twice. A duplicate call is a second real sign-in attempt
      // against the provider - wasted work at best, and it makes any
      // "already in use" style error depend on which call lands first.
      when(auth.signInWithGoogle()).thenAnswer((_) async => credential);

      await pumpPage(tester);
      await tester.tap(find.text('Continue with Google'));
      await settleAndIgnoreDestination(tester);

      verify(auth.signInWithGoogle()).called(1);
    });

    testWidgets('a cancelled sign-up is not an error', (tester) async {
      when(auth.signInWithGoogle()).thenAnswer((_) async => null);

      await pumpPage(tester);
      await tester.tap(find.text('Continue with Google'));
      await settleAndIgnoreDestination(tester);

      expect(find.byType(RegisterScreen), findsOneWidget);
      expect(find.text('Something went wrong. Try again.'), findsNothing);
    });
  });
}
