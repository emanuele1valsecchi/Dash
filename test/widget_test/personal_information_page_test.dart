import 'package:cloud_functions/cloud_functions.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:mock_exceptions/mock_exceptions.dart';
import 'package:mockito/mockito.dart';

import 'package:dash/screens/personal_information_page.dart';

import '../helpers/pump_app.dart';
// `MockUser` is hidden: firebase_auth_mocks defines its own, and that is
// the one this file wants (a real in-memory user, not a mockito stub).
import '../mocks.mocks.dart' hide MockUser;

void main() {
  late FakeFirebaseFirestore db;
  late MockFirebaseAuth auth;
  late MockFirebaseFunctions functions;
  late MockHttpsCallable callable;

  setUp(() {
    db = FakeFirebaseFirestore();
    auth = MockFirebaseAuth(
      signedIn: true,
      mockUser: MockUser(
        uid: 'me',
        email: 'runner@example.com',
        displayName: 'Ada',
      ),
    );
    functions = MockFirebaseFunctions();
    callable = MockHttpsCallable();
    when(functions.httpsCallable(any)).thenReturn(callable);
  });

  /// Stubs the callable to succeed, optionally with a server message.
  void callableSucceeds({String? message}) {
    final result = MockHttpsCallableResult<dynamic>();
    when(result.data).thenReturn(message == null ? null : {'message': message});
    when(callable.call(any)).thenAnswer((_) async => result);
  }

  /// Stubs the callable to fail. `thenAnswer`, never `thenThrow` — the latter
  /// throws synchronously at the call site rather than completing the future
  /// with an error, which is not what a failing callable does.
  void callableFails(FirebaseFunctionsException error) {
    when(callable.call(any)).thenAnswer((_) async => throw error);
  }

  Future<void> pumpPage(WidgetTester tester, {MockFirebaseAuth? withAuth}) async {
    await pumpDashWidget(
      tester,
      PersonalInformationPage(
        auth: withAuth ?? auth,
        firestore: db,
        functions: functions,
      ),
      wrapInScaffold: false,
    );
    await tester.pumpAndSettle();
  }

  group('the page', () {
    testWidgets('lists every action', (tester) async {
      await pumpPage(tester);

      expect(find.text('Personal Information'), findsOneWidget);
      expect(find.text('Change Password'), findsOneWidget);
      expect(find.text('Update Email'), findsOneWidget);
      expect(find.text('Export Data (GDPR)'), findsOneWidget);
      expect(find.text('Clear Progress'), findsOneWidget);
      expect(find.text('Delete Account'), findsOneWidget);
    });

    testWidgets('warns that deletion is permanent', (tester) async {
      await pumpPage(tester);

      expect(find.textContaining('Deleting your account is permanent'),
          findsOneWidget);
    });
  });

  group('update email', () {
    testWidgets('opens a dialog asking for the new address', (tester) async {
      await pumpPage(tester);

      await tester.tap(find.text('Update Email'));
      await tester.pumpAndSettle();

      expect(find.text('Enter new email address'), findsOneWidget);
      expect(find.text('Send Link'), findsOneWidget);
    });

    testWidgets('cancelling closes it cleanly', (tester) async {
      // Regression test for a crash, not a UX check. The dialog's controller
      // used to be disposed the moment `showDialog`'s future completed —
      // which is when the dialog *starts* its exit transition, with the
      // TextField still mounted and bound to it for the rest of the
      // animation. Tearing that subtree down then throws, and it surfaces as
      // `dependents.isEmpty is not true` from a totally unrelated
      // InheritedElement. Settling the exit animation is what catches it.
      await pumpPage(tester);

      await tester.tap(find.text('Update Email'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'new@example.com');
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Enter new email address'), findsNothing);
    });

    testWidgets('confirming closes it cleanly too', (tester) async {
      await pumpPage(tester);

      await tester.tap(find.text('Update Email'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'new@example.com');
      await tester.tap(find.text('Send Link'));
      await tester.pumpAndSettle();

      expect(find.text('Enter new email address'), findsNothing);
    });
    testWidgets('sends the verification link to the address typed',
        (tester) async {
      await pumpPage(tester);

      await tester.tap(find.text('Update Email'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '  new@example.com  ');
      await tester.tap(find.text('Send Link'));
      await tester.pumpAndSettle();

      expect(find.text('Verification link sent to new email!'), findsOneWidget);
    });

    testWidgets('an empty address sends nothing', (tester) async {
      await pumpPage(tester);

      await tester.tap(find.text('Update Email'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Send Link'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Verification link'), findsNothing);
    });

    testWidgets('a stale login is explained in words the user can act on',
        (tester) async {
      // Reported from a real device. Changing the sign-in address is one of
      // Firebase's *sensitive* operations, refused unless the ID token is
      // fresh — which it stops being minutes after signing in. Firebase's own
      // message ("This operation is sensitive and requires recent
      // authentication...") is accurate but tells the user nothing to do, so
      // it is replaced with the same instruction `_deleteAccount` already
      // gives for the same situation.
      final user = MockUser(uid: 'me', email: 'runner@example.com');
      whenCalling(Invocation.method(#verifyBeforeUpdateEmail, null))
          .on(user)
          .thenThrow(FirebaseAuthException(
            code: 'requires-recent-login',
            message: 'This operation is sensitive and requires recent '
                'authentication. Log in again before retrying this request.',
          ));

      await pumpPage(
        tester,
        withAuth: MockFirebaseAuth(signedIn: true, mockUser: user),
      );
      await tester.tap(find.text('Update Email'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'new@example.com');
      await tester.tap(find.text('Send Link'));
      await tester.pumpAndSettle();

      expect(
        find.text('Please log out and log back in before changing your email.'),
        findsOneWidget,
      );
      expect(find.textContaining('This operation is sensitive'), findsNothing);
    });

    testWidgets('any other auth failure still reports what Firebase said',
        (tester) async {
      // Only the one actionable case is rewritten; everything else keeps the
      // real message, which is more use than a generic "something failed".
      //
      // The uid differs from every other test's on purpose. `MockUser` mixes
      // in `EquatableMixin`, so two users built with the same fields are `==`
      // — and `mock_exceptions` keys its registry by object. Reusing
      // `uid: 'me'` here made this user collide with the previous test's, so
      // it threw *that* test's `requires-recent-login` instead and this one
      // failed while passing in isolation.
      final user = MockUser(uid: 'other', email: 'other@example.com');
      whenCalling(Invocation.method(#verifyBeforeUpdateEmail, null))
          .on(user)
          .thenThrow(FirebaseAuthException(
            code: 'invalid-email',
            message: 'The email address is badly formatted.',
          ));

      await pumpPage(
        tester,
        withAuth: MockFirebaseAuth(signedIn: true, mockUser: user),
      );
      await tester.tap(find.text('Update Email'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'not-an-email');
      await tester.tap(find.text('Send Link'));
      await tester.pumpAndSettle();

      expect(find.textContaining('badly formatted'), findsOneWidget);
    });

  });

  group('export data', () {
    testWidgets('queues a mail document for the signed-in user',
        (tester) async {
      await pumpPage(tester);

      await tester.tap(find.text('Export Data (GDPR)'));
      await tester.pumpAndSettle();

      final mail = await db.collection('mail').get();
      expect(mail.docs, hasLength(1));
      final data = mail.docs.single.data();
      expect(data['userId'], 'me');
      expect(data['requestType'], 'dataExport');
      expect(data['to'], contains('runner@example.com'));
    });

    testWidgets('confirms to the user that it was received', (tester) async {
      await pumpPage(tester);

      await tester.tap(find.text('Export Data (GDPR)'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Request received'), findsOneWidget);
    });

    testWidgets('refuses when the account has no email address',
        (tester) async {
      // Nothing to send the export to, so the request must not be queued at
      // all rather than written and silently dropped.
      await pumpPage(
        tester,
        withAuth: MockFirebaseAuth(
          signedIn: true,
          mockUser: MockUser(uid: 'me', email: ''),
        ),
      );

      await tester.tap(find.text('Export Data (GDPR)'));
      await tester.pumpAndSettle();

      expect(find.textContaining('No email address'), findsOneWidget);
      expect((await db.collection('mail').get()).docs, isEmpty);
    });
  });

  group('clear progress', () {
    testWidgets('asks for confirmation first', (tester) async {
      await pumpPage(tester);

      await tester.tap(find.text('Clear Progress'));
      await tester.pumpAndSettle();

      expect(find.textContaining('permanently delete all your running sessions'),
          findsOneWidget);
      verifyNever(functions.httpsCallable(any));
    });

    testWidgets('cancelling calls nothing', (tester) async {
      await pumpPage(tester);

      await tester.tap(find.text('Clear Progress'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      verifyNever(functions.httpsCallable(any));
    });

    testWidgets('confirming calls clearUserProgress', (tester) async {
      callableSucceeds();
      await pumpPage(tester);

      await tester.tap(find.text('Clear Progress'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      verify(functions.httpsCallable('clearUserProgress')).called(1);
    });

    testWidgets('reports the server\'s own message when it sends one',
        (tester) async {
      callableSucceeds(message: 'Wiped 12 sessions.');
      await pumpPage(tester);

      await tester.tap(find.text('Clear Progress'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      expect(find.text('Wiped 12 sessions.'), findsOneWidget);
    });

    testWidgets('falls back to its own wording when the server sends none',
        (tester) async {
      callableSucceeds();
      await pumpPage(tester);

      await tester.tap(find.text('Clear Progress'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      expect(find.text('Progress cleared successfully!'), findsOneWidget);
    });

    testWidgets('surfaces a server failure instead of looking successful',
        (tester) async {
      callableFails(FirebaseFunctionsException(
        code: 'internal',
        message: 'something broke',
      ));
      await pumpPage(tester);

      await tester.tap(find.text('Clear Progress'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Server error'), findsOneWidget);
      expect(find.textContaining('something broke'), findsOneWidget);
    });

    testWidgets('stops loading after a failure so the page is usable again',
        (tester) async {
      callableFails(FirebaseFunctionsException(code: 'internal', message: 'boom'));
      await pumpPage(tester);

      await tester.tap(find.text('Clear Progress'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('Clear Progress'), findsOneWidget);
    });
  });

  group('delete account', () {
    testWidgets('asks for confirmation first', (tester) async {
      await pumpPage(tester);

      await tester.tap(find.text('Delete Account'));
      await tester.pumpAndSettle();

      expect(find.textContaining('This action is irreversible'), findsOneWidget);
      verifyNever(functions.httpsCallable(any));
    });

    testWidgets('cancelling calls nothing', (tester) async {
      await pumpPage(tester);

      await tester.tap(find.text('Delete Account'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      verifyNever(functions.httpsCallable(any));
    });

    testWidgets('an expired session says to log in again', (tester) async {
      callableFails(FirebaseFunctionsException(code: 'unauthenticated', message: 'no auth'));
      await pumpPage(tester);

      await tester.tap(find.text('Delete Account'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(find.text('Your session has expired. Please log in again.'),
          findsOneWidget);
    });

    testWidgets('a stale login says to log out and back in', (tester) async {
      // Firebase requires a recent sign-in for destructive account actions;
      // "failed-precondition" is what that looks like from the callable.
      callableFails(FirebaseFunctionsException(code: 'failed-precondition', message: 'stale'));
      await pumpPage(tester);

      await tester.tap(find.text('Delete Account'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(
        find.text('Please log out and log back in before deleting your account.'),
        findsOneWidget,
      );
    });

    testWidgets('any other failure reports the server\'s message',
        (tester) async {
      callableFails(FirebaseFunctionsException(
        code: 'internal',
        message: 'cascade failed',
      ));
      await pumpPage(tester);

      await tester.tap(find.text('Delete Account'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(find.textContaining('cascade failed'), findsOneWidget);
    });

    testWidgets('the account is not signed out when deletion failed',
        (tester) async {
      // Signing out on failure would strand the user with their data intact
      // and no obvious way to see that nothing happened.
      callableFails(FirebaseFunctionsException(code: 'internal', message: 'boom'));
      await pumpPage(tester);

      await tester.tap(find.text('Delete Account'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(auth.currentUser, isNotNull);
    });
  });
}
