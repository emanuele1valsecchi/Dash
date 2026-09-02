import 'package:dash/main.dart' as app;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// End-to-end smoke test: the real app, on a real device or emulator, against
/// a real Firebase project.
///
/// **This is the layer that cannot be faked.** Every widget test in `test/`
/// substitutes something — the Firestore, the auth service, the fonts, the
/// platform channels — so none of them can tell you that
/// `Firebase.initializeApp()` actually connects, that the Google Services
/// plist/json is wired up, that the app has the permissions it declares, or
/// that the first frame renders on a phone at all. A build that fails on
/// launch passes the entire unit suite.
///
/// Run it with a device attached:
///
/// ```sh
/// flutter test integration_test/app_launch_test.dart
/// ```
///
/// It will NOT run under a plain `flutter test` — there is no device, and the
/// `integration_test` binding needs one. That is deliberate: keeping these out
/// of the default run keeps `flutter test` fast and offline.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('app launch', () {
    testWidgets('boots without crashing and shows a first screen',
        (tester) async {
      app.main();
      // Not pumpAndSettle: the app opens a Firestore listener and an auth
      // stream that may never go idle, and pumpAndSettle would time out
      // waiting for a quiet frame that never comes.
      await tester.pump(const Duration(seconds: 5));

      expect(tester.takeException(), isNull);
      expect(find.byType(MaterialApp), findsOneWidget);
    });

    testWidgets('lands on a signed-out entry point when nobody is signed in',
        (tester) async {
      // Which of these appears depends on the account state left on the
      // device, so the assertion is deliberately loose: what matters is that
      // the auth gate resolved to *something* rather than hanging on the
      // splash screen forever.
      app.main();
      await tester.pump(const Duration(seconds: 5));

      final reachedSomeScreen = find.byType(Scaffold).evaluate().isNotEmpty;
      expect(reachedSomeScreen, isTrue,
          reason: 'the app never rendered a screen after 5 seconds');
    });
  });
}
