import 'package:dash/config/app_theme.dart';
import 'package:dash/screens/login_page.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';

import '../mocks.mocks.dart';

/// The sign-in paths that need the screen's collaborators replaced.
///
/// Split from `login_page_test.dart`, which covers everything reachable
/// without a mock (layout, the password toggle, local validation, the failure
/// branch). This file is about what the screen *asks its services to do* and
/// what it does with their answers — questions only `verify()` can settle.
/// Records what the screen asks the navigator to do.
///
/// Used instead of asserting the destination widget is on screen, because
/// building the destination is exactly what must be avoided here: `RootScreen`
/// and `WelcomeRegisterScreen` both reach for `FirebaseAuth.instance` in their
/// own `initState` and throw with no Firebase app. Observing the route keeps
/// the assertion about *this* screen's behaviour.
class _RouteSpy extends NavigatorObserver {
  final List<Route<dynamic>> replaced = [];
  final List<Route<dynamic>> pushed = [];

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (newRoute != null) replaced.add(newRoute);
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushed.add(route);
  }
}

void main() {
  late MockAuthService auth;
  late MockProfileService profiles;
  late MockPushNotificationService push;
  late MockUserCredential credential;
  late _RouteSpy routes;

  setUpAll(() async {
    // Stands up a mock Firebase app for the whole file.
    //
    // Not because this screen needs one — its three services are injected —
    // but because a successful sign-in navigates to `RootScreen`, which
    // reaches for `FirebaseAuth.instance` in its own `initState`. Without an
    // initialised app that throws `[core/no-app]` while the route transition
    // is still in flight, and the failure surfaces at teardown attributed to
    // whichever test was running, with no useful stack. This makes the
    // destination constructible so the navigation under test can simply
    // happen.
    TestWidgetsFlutterBinding.ensureInitialized();
    setupFirebaseCoreMocks();
    await Firebase.initializeApp();
  });

  setUp(() {
    auth = MockAuthService();
    profiles = MockProfileService();
    push = MockPushNotificationService();
    credential = MockUserCredential();
    routes = _RouteSpy();

    // Sensible defaults so an individual test only stubs what it is about.
    when(profiles.isProfileComplete()).thenAnswer((_) async => true);
    when(push.initialize()).thenAnswer((_) async {});
  });

  Future<void> pumpPage(WidgetTester tester) async {
    // Wide enough to dodge the test-font overflow on the Google button; see
    // login_page_test.dart and test/README.md.
    tester.view.physicalSize = const Size(500, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    // Tear the tree down before the test ends, so the half-mounted
    // destination is disposed rather than left to error again during the
    // binding's own teardown frames.
    addTearDown(() => tester.pumpWidget(const SizedBox()));

    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        navigatorObservers: [routes],
        home: LoginScreen(
          authService: auth,
          profileService: profiles,
          pushNotificationService: push,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }


  /// Advances the sign-in future chain, then discards the errors thrown by
  /// the screen it navigates *to*.
  ///
  /// A successful sign-in replaces this route with `RootScreen`, which is the
  /// entire app shell — bottom nav, map, profile — and mounting it reaches for
  /// Firebase Storage, Firestore and more. None of that is reachable in a
  /// widget test, and none of it is what this file is testing.
  ///
  /// So the destination is allowed to fail and its `FirebaseException`s are
  /// dropped here, deliberately and narrowly: anything that is *not* a Firebase
  /// initialisation complaint fails the test. What survives is the part that
  /// matters — which services `LoginScreen` called, with what arguments, and
  /// what it put on screen. Whether the app shell then renders correctly is an
  /// integration-test question, not one for this file.
  Future<void> settleAndIgnoreDestination(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    for (var i = 0; i < 100; i++) {
      final error = tester.takeException();
      if (error == null) return;
      // Matched on the message, not the type: several failures during one
      // frame arrive wrapped in a summary object rather than as the original
      // FirebaseException.
      if (!error.toString().toLowerCase().contains('firebase') &&
          !error.toString().contains('Multiple exceptions')) {
        fail('Unexpected error after sign-in: $error');
      }
    }
  }

  Future<void> signIn(
    WidgetTester tester, {
    String email = 'runner@example.com',
    String password = 'hunter2',
  }) async {
    await tester.enterText(find.byType(TextField).first, email);
    await tester.enterText(find.byType(TextField).at(1), password);
    await tester.tap(find.text("Let's go"));
    await settleAndIgnoreDestination(tester);
  }

  group('email sign-in', () {
    testWidgets('passes the typed credentials to the auth service',
        (tester) async {
      when(auth.loginWithEmail(
        email: anyNamed('email'),
        password: anyNamed('password'),
      )).thenAnswer((_) async => credential);

      await pumpPage(tester);
      await signIn(tester);

      verify(auth.loginWithEmail(
        email: 'runner@example.com',
        password: 'hunter2',
      )).called(1);
    });

    testWidgets('trims the email before sending it', (tester) async {
      // A stray leading space is easy to introduce on a phone keyboard and
      // would otherwise turn into a "no account found" the user cannot
      // explain.
      when(auth.loginWithEmail(
        email: anyNamed('email'),
        password: anyNamed('password'),
      )).thenAnswer((_) async => credential);

      await pumpPage(tester);
      await signIn(tester, email: '  runner@example.com  ');

      verify(auth.loginWithEmail(
        email: 'runner@example.com',
        password: anyNamed('password'),
      )).called(1);
    });

    testWidgets('sends the password exactly as typed', (tester) async {
      // Deliberately NOT trimmed - a trailing space can be part of a password.
      when(auth.loginWithEmail(
        email: anyNamed('email'),
        password: anyNamed('password'),
      )).thenAnswer((_) async => credential);

      await pumpPage(tester);
      await signIn(tester, password: ' hunter2 ');

      verify(auth.loginWithEmail(
        email: anyNamed('email'),
        password: ' hunter2 ',
      )).called(1);
    });

    testWidgets('never reaches the auth service on an incomplete form',
        (tester) async {
      // Local validation must short-circuit: a request guaranteed to fail is
      // a wasted round trip and a worse error message.
      await pumpPage(tester);

      await tester.tap(find.text("Let's go"));
      await tester.pumpAndSettle();

      verifyNever(auth.loginWithEmail(
        email: anyNamed('email'),
        password: anyNamed('password'),
      ));
    });
  });

  group('after a successful sign-in', () {
    setUp(() {
      when(auth.loginWithEmail(
        email: anyNamed('email'),
        password: anyNamed('password'),
      )).thenAnswer((_) async => credential);
    });

    testWidgets('checks whether the profile is complete', (tester) async {
      // Which of two very different screens the user lands on depends on this.
      await pumpPage(tester);
      await signIn(tester);

      verify(profiles.isProfileComplete()).called(1);
    });

    testWidgets('registers for push notifications', (tester) async {
      // Only after sign-in, since the token is stored against the user.
      await pumpPage(tester);
      await signIn(tester);

      verify(push.initialize()).called(1);
    });

    testWidgets('leaves the login screen when the profile is complete',
        (tester) async {
      when(profiles.isProfileComplete()).thenAnswer((_) async => true);

      await pumpPage(tester);
      await signIn(tester);

      expect(routes.replaced, hasLength(1));
    });

    testWidgets('leaves the login screen when the profile is incomplete too',
        (tester) async {
      // Different destination, but either way the user must not be left
      // sitting on the login form after signing in.
      when(profiles.isProfileComplete()).thenAnswer((_) async => false);

      await pumpPage(tester);
      await signIn(tester);

      expect(routes.replaced, hasLength(1));
    });

    testWidgets('shows no error message', (tester) async {
      await pumpPage(tester);
      await signIn(tester);

      expect(find.text('Enter email and password'), findsNothing);
      expect(find.text('Something went wrong. Try again.'), findsNothing);
    });
  });

  group('sign-in failures are explained, not dumped', () {
    // The screen maps Firebase's codes onto sentences a person can act on.
    // Anything unmapped must still not leak a raw exception to the UI.
    Future<void> failWith(WidgetTester tester, String code) async {
      when(auth.loginWithEmail(
        email: anyNamed('email'),
        password: anyNamed('password'),
      )).thenThrow(FirebaseAuthException(code: code));

      await pumpPage(tester);
      await signIn(tester);
    }

    for (final (code, message) in const [
      ('user-not-found', 'No account found with this email'),
      ('wrong-password', 'Incorrect password'),
      ('invalid-email', 'Invalid email address'),
      ('too-many-requests', 'Too many attempts. Try again later'),
    ]) {
      testWidgets('$code reads as "$message"', (tester) async {
        await failWith(tester, code);

        expect(find.text(message), findsOneWidget);
      });
    }

    testWidgets('an unrecognised code falls back to a generic message',
        (tester) async {
      await failWith(tester, 'network-request-failed');

      expect(find.text('Something went wrong. Try again.'), findsOneWidget);
      expect(find.textContaining('firebase_auth'), findsNothing);
    });

    testWidgets('the user is kept on the login screen to retry',
        (tester) async {
      await failWith(tester, 'wrong-password');

      expect(find.byType(LoginScreen), findsOneWidget);
      expect(routes.replaced, isEmpty);
    });

    testWidgets('the button is re-enabled rather than left spinning',
        (tester) async {
      await failWith(tester, 'wrong-password');

      expect(find.byType(CircularProgressIndicator), findsNothing);
      final button = tester.widget<ElevatedButton>(
        find.ancestor(
          of: find.text("Let's go"),
          matching: find.byType(ElevatedButton),
        ),
      );
      expect(button.onPressed, isNotNull);
    });

    testWidgets('a failed sign-in never registers for push notifications',
        (tester) async {
      await failWith(tester, 'wrong-password');

      verifyNever(push.initialize());
      verifyNever(profiles.isProfileComplete());
    });

    testWidgets('the error clears when the next attempt succeeds',
        (tester) async {
      await failWith(tester, 'wrong-password');
      expect(find.text('Incorrect password'), findsOneWidget);

      when(auth.loginWithEmail(
        email: anyNamed('email'),
        password: anyNamed('password'),
      )).thenAnswer((_) async => credential);
      await signIn(tester, password: 'correct-horse');

      expect(find.text('Incorrect password'), findsNothing);
    });
  });

  group('Google sign-in', () {
    testWidgets('asks the auth service to start the Google flow',
        (tester) async {
      when(auth.signInWithGoogle()).thenAnswer((_) async => credential);

      await pumpPage(tester);
      await tester.tap(find.text('Continue with Google'));
      await settleAndIgnoreDestination(tester);

      verify(auth.signInWithGoogle()).called(1);
    });

    testWidgets('continues into the app on success', (tester) async {
      when(auth.signInWithGoogle()).thenAnswer((_) async => credential);

      await pumpPage(tester);
      await tester.tap(find.text('Continue with Google'));
      await settleAndIgnoreDestination(tester);

      verify(profiles.isProfileComplete()).called(1);
      expect(routes.replaced, hasLength(1));
    });

    testWidgets('a cancelled Google sign-in leaves the user where they were',
        (tester) async {
      // Dismissing the account picker returns null rather than throwing. It
      // is not an error and must not be reported as one.
      when(auth.signInWithGoogle()).thenAnswer((_) async => null);

      await pumpPage(tester);
      await tester.tap(find.text('Continue with Google'));
      await settleAndIgnoreDestination(tester);

      expect(find.byType(LoginScreen), findsOneWidget);
      expect(routes.replaced, isEmpty);
      expect(find.text('Something went wrong. Try again.'), findsNothing);
      verifyNever(profiles.isProfileComplete());
    });

    testWidgets('a failed Google sign-in is explained', (tester) async {
      when(auth.signInWithGoogle())
          .thenThrow(FirebaseAuthException(code: 'too-many-requests'));

      await pumpPage(tester);
      await tester.tap(find.text('Continue with Google'));
      await settleAndIgnoreDestination(tester);

      expect(find.text('Too many attempts. Try again later'), findsOneWidget);
    });
  });
}
