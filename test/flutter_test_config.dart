import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Global setup, run automatically by the test runner around every test under
/// `test/` — no import or per-file wiring needed. Flutter looks for this exact
/// filename; renaming it silently disables everything here.
///
/// Its whole job is to stop a passing run from printing pages of alarming
/// platform noise. A suite that shouts `MissingPluginException` 40 times while
/// succeeding trains everyone to ignore its output, which is exactly when a
/// real failure slips past.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  TestWidgetsFlutterBinding.ensureInitialized();

  _stubPlatformChannels();

  await testMain();
}

/// Answers the native channels that do not exist in a unit test.
///
/// `RunForegroundService` talks to an Android foreground service over
/// `dash/run_service`. There is no Android here, so every call threw
/// `MissingPluginException`, which the service caught and logged — correct
/// behaviour, but it meant every `RunSessionController` test printed a failure
/// line while passing.
///
/// Stubbing beats muting: the call now *succeeds*, so the tests exercise the
/// same path a real device takes rather than the error branch.
void _stubPlatformChannels() {
  const channels = <MethodChannel>[
    MethodChannel('dash/run_service'),
  ];

  for (final channel in channels) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => true);
  }
}
