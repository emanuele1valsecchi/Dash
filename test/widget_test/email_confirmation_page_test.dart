import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mock_exceptions/mock_exceptions.dart';
import 'package:mockito/mockito.dart';

import 'package:dash/root_screen.dart';
import 'package:dash/screens/email_confirmation_page.dart';
import 'package:dash/screens/welcome_register_page.dart';
import 'package:dash/services/wear_bridge.dart';

import '../helpers/pump_app.dart';
// `MockUser` is hidden: firebase_auth_mocks defines its own, and that is the
// one this file wants (a real in-memory user, not a mockito stub).
import '../mocks.mocks.dart' hide MockUser;

/// The screen a user is parked on between signing up and clicking the link in
/// their inbox. It is a dead end by design — the only ways forward are "I've
/// confirmed my email" and "Resend email" — so the failure that matters is
/// stranding someone: a check that silently does nothing, or a button left
/// spinning after an error, leaves the account unreachable with no way back.
///
/// The two branches after a *successful* verification are worth separating
/// because they lead to different halves of the app: a returning user with a
/// finished profile belongs in [RootScreen], a brand-new one in
/// [WelcomeRegisterScreen], and sending someone to the wrong one either
/// re-asks for details they already gave or drops them into the app shell
/// with an empty profile.
void main() {
  late MockProfileService profiles;
  late _RouteSpy routes;

  setUpAll(() async {
    // Stands up a mock Firebase app for the whole file.
    //
    // Not because this screen needs one — both its collaborators are injected
    // — but because verifying navigates to `RootScreen`, which reaches for
    // `FirebaseAuth.instance` in its own `initState`. Without an initialised
    // app that throws `[core/no-app]` while the route transition is still in
    // flight, and the failure surfaces at teardown attributed to whichever
    // test was running. Mirrors `login_page_auth_flow_test`, which navigates
    // to the same two destinations.
    TestWidgetsFlutterBinding.ensureInitialized();
    setupFirebaseCoreMocks();
    await Firebase.initializeApp();
  });

  setUp(() {
    profiles = MockProfileService();
    routes = _RouteSpy();
  });

  Future<void> pumpPage(
    WidgetTester tester, {
    required FirebaseAuth auth,
    String email = 'runner@example.com',
  }) async {
    await pumpDashWidget(
      tester,
      EmailConfirmationScreen(
        email: email,
        auth: auth,
        profileService: profiles,
      ),
      wrapInScaffold: false,
      navigatorObserver: routes,
    );
  }

  /// Settles the frame without letting the *destination* screen's Firebase
  /// complaints fail the test.
  ///
  /// Verifying successfully replaces this route with `RootScreen`, whose
  /// `initState` reaches straight for `FirebaseAuth.instance` and throws
  /// `[core/no-app]`. What this file is about is which route the screen asked
  /// for, not whether the app shell can render — that is an integration-test
  /// question. Mirrors `login_page_auth_flow_test`'s helper of the same name.
  Future<void> settleAndIgnoreDestination(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // `WearBridge` is an app-lifetime singleton started by `HomePage.initState`
    // with a periodic timer nothing cancels, and `flutter_test` fails any test
    // that ends with a timer pending. Stopped here in the test body rather
    // than in `addTearDown`, which runs after that invariant check.
    WearBridge.instance.dispose();

    for (var i = 0; i < 100; i++) {
      final error = tester.takeException();
      if (error == null) return;
      if (!error.toString().toLowerCase().contains('firebase') &&
          !error.toString().contains('Multiple exceptions')) {
        fail('Unexpected error after verifying: $error');
      }
    }
  }

  Future<void> tapConfirm(WidgetTester tester) async {
    await tester.tap(find.text("I've confirmed my email"));
    await settleAndIgnoreDestination(tester);
  }

  Future<void> tapResend(WidgetTester tester) async {
    await tester.tap(find.text('Resend email'));
    await tester.pumpAndSettle();
  }

  /// The widget the single replacement route would build, without mounting it.
  ///
  /// `MaterialPageRoute.builder` is just a closure returning a `const` screen,
  /// so calling it constructs the destination without running its `initState`
  /// — which is the part that needs a live Firebase app. This is what makes
  /// asserting the *exact* destination affordable here.
  Widget replacementDestination(WidgetTester tester) {
    expect(routes.replaced, hasLength(1),
        reason: 'the screen should have navigated exactly once');
    final route = routes.replaced.single as MaterialPageRoute;
    return route.builder(tester.element(find.byType(Navigator)));
  }

  MockFirebaseAuth signedIn({bool verified = true}) => MockFirebaseAuth(
        signedIn: true,
        mockUser: MockUser(
          uid: 'me',
          email: 'runner@example.com',
          isEmailVerified: verified,
        ),
      );

  group('what it shows', () {
    testWidgets('names the address the mail was sent to', (tester) async {
      // The address is the one thing on this screen a user can act on — if it
      // is wrong, the fix is to go back and re-register, not to keep waiting.
      await pumpPage(tester,
          auth: signedIn(), email: 'someone.else@example.com');

      expect(
        find.textContaining('someone.else@example.com'),
        findsOneWidget,
      );
    });

    testWidgets('offers both a re-check and a resend', (tester) async {
      await pumpPage(tester, auth: signedIn());

      expect(find.text("I've confirmed my email"), findsOneWidget);
      expect(find.text('Resend email'), findsOneWidget);
    });
  });

  group('checking whether the email is verified', () {
    testWidgets('a verified user with a finished profile goes to the app',
        (tester) async {
      when(profiles.isProfileComplete()).thenAnswer((_) async => true);

      await pumpPage(tester, auth: signedIn());
      await tapConfirm(tester);

      expect(replacementDestination(tester), isA<RootScreen>());
    });

    testWidgets('a verified user with no profile goes to registration',
        (tester) async {
      when(profiles.isProfileComplete()).thenAnswer((_) async => false);

      await pumpPage(tester, auth: signedIn());
      await tapConfirm(tester);

      expect(replacementDestination(tester), isA<WelcomeRegisterScreen>());
    });

    testWidgets('an unverified user is told to look again, and stays put',
        (tester) async {
      await pumpPage(tester, auth: signedIn(verified: false));
      await tapConfirm(tester);

      expect(
        find.text('Email not verified yet. Check your inbox again.'),
        findsOneWidget,
      );
      expect(routes.replaced, isEmpty);
      // The profile is none of this branch's business — asking for it would
      // mean a Firestore read on every impatient tap.
      verifyNever(profiles.isProfileComplete());
    });

    testWidgets('a signed-out user is told so rather than silently ignored',
        (tester) async {
      await pumpPage(tester, auth: MockFirebaseAuth());
      await tapConfirm(tester);

      expect(find.text('No user is currently logged in'), findsOneWidget);
      expect(routes.replaced, isEmpty);
    });

    testWidgets('a failed refresh is reported, not swallowed', (tester) async {
      final auth = signedIn(verified: false);
      whenCalling(Invocation.method(#reload, null))
          .on(auth.currentUser!)
          .thenThrow(FirebaseAuthException(code: 'network-request-failed'));

      await pumpPage(tester, auth: auth);
      await tapConfirm(tester);

      expect(find.text('Verification check failed'), findsOneWidget);
      expect(routes.replaced, isEmpty);
    });

    testWidgets('the button comes back after a failure rather than spinning',
        (tester) async {
      // The `finally` branch. Without it one network blip would leave the
      // only way forward permanently disabled.
      final auth = signedIn(verified: false);
      whenCalling(Invocation.method(#reload, null))
          .on(auth.currentUser!)
          .thenThrow(FirebaseAuthException(code: 'network-request-failed'));

      await pumpPage(tester, auth: auth);
      await tapConfirm(tester);

      expect(find.text("I've confirmed my email"), findsOneWidget);
      final button = tester.widget<ElevatedButton>(
        find.ancestor(
          of: find.text("I've confirmed my email"),
          matching: find.byType(ElevatedButton),
        ),
      );
      expect(button.onPressed, isNotNull);
    });
  });

  group('resending the verification email', () {
    testWidgets('asks Firebase to send another one', (tester) async {
      final auth = signedIn(verified: false);

      await pumpPage(tester, auth: auth);
      await tapResend(tester);

      expect(find.text('Verification email sent again'), findsOneWidget);
    });

    testWidgets('a signed-out user is told so rather than silently ignored',
        (tester) async {
      await pumpPage(tester, auth: MockFirebaseAuth());
      await tapResend(tester);

      expect(find.text('No user is currently logged in'), findsOneWidget);
    });

    testWidgets('a send failure is reported as retryable', (tester) async {
      // Wording matters here: the user cannot fix this, so the message says
      // to try later rather than implying they did something wrong.
      final auth = signedIn(verified: false);
      whenCalling(Invocation.method(#sendEmailVerification, null))
          .on(auth.currentUser!)
          .thenThrow(FirebaseAuthException(code: 'too-many-requests'));

      await pumpPage(tester, auth: auth);
      await tapResend(tester);

      expect(
        find.text('Could not resend email, try again later'),
        findsOneWidget,
      );
    });

    testWidgets('the link comes back after a failure rather than spinning',
        (tester) async {
      final auth = signedIn(verified: false);
      whenCalling(Invocation.method(#sendEmailVerification, null))
          .on(auth.currentUser!)
          .thenThrow(FirebaseAuthException(code: 'too-many-requests'));

      await pumpPage(tester, auth: auth);
      await tapResend(tester);

      final button = tester.widget<TextButton>(
        find.ancestor(
          of: find.text('Resend email'),
          matching: find.byType(TextButton),
        ),
      );
      expect(button.onPressed, isNotNull);
    });
  });
}

/// Records what the screen asks the navigator to do.
///
/// Used instead of asserting the destination is on screen, because building
/// it is exactly what must be avoided — `RootScreen` and
/// `WelcomeRegisterScreen` both reach for `FirebaseAuth.instance` in their own
/// `initState`.
class _RouteSpy extends NavigatorObserver {
  final List<Route<dynamic>> replaced = [];

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (newRoute != null) replaced.add(newRoute);
  }
}
