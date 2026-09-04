import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart';

import 'package:dash/services/run_foreground_service.dart';

import '../helpers/fake_location_platform.dart';

/// The Android foreground service that keeps GPS alive once the screen goes
/// off. Everything here is static and platform-channel-bound, so what is worth
/// pinning is narrow but real: **the run must survive this failing.**
///
/// A foreground service cannot start at all without a visible notification, so
/// on Android 13+ a refused permission costs background tracking outright. And
/// Android 12+ refuses a background start regardless. Both are ordinary, and
/// neither is allowed to take the run down with it — an earlier version caught
/// only `PlatformException` and broke every controller test, because
/// `MissingPluginException` is not one.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('dash/run_service');
  late List<MethodCall> calls;

  /// Answers the channel; when [fail] the platform side throws instead.
  void serve({bool fail = false}) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (fail) {
        throw PlatformException(code: 'FOREGROUND_SERVICE_START_NOT_ALLOWED');
      }
      return true;
    });
  }

  setUp(() {
    calls = [];
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    serve();
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('on Android', () {
    test('start sends the notification text through', () async {
      await RunForegroundService.start(title: 'Recording run', body: '2.4 km');

      expect(calls.single.method, 'start');
      expect(calls.single.arguments,
          {'title': 'Recording run', 'body': '2.4 km'});
    });

    test('update refreshes the same notification', () async {
      await RunForegroundService.update(title: 'Run paused', body: '3.1 km');

      expect(calls.single.method, 'update');
      expect(calls.single.arguments, {'title': 'Run paused', 'body': '3.1 km'});
    });

    test('stop carries no text at all', () async {
      // The null-aware map entries mean the keys are omitted rather than sent
      // as nulls, which the platform side would have to special-case.
      await RunForegroundService.stop();

      expect(calls.single.method, 'stop');
      expect(calls.single.arguments, isEmpty);
    });
  });

  group('when the platform refuses', () {
    test('a failed start does not take the run down', () async {
      // Android 12+ refuses a background start. The run carries on; it simply
      // will not survive the screen going off.
      serve(fail: true);

      await expectLater(
        RunForegroundService.start(title: 'x', body: 'y'),
        completes,
      );
    });

    test('a missing plugin is survived too, not just a PlatformException',
        () async {
      // The regression this catch-all exists for: `MissingPluginException` is
      // not a `PlatformException`, and catching only the latter broke every
      // controller test at once.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);

      await expectLater(RunForegroundService.stop(), completes);
    });
  });

  group('off Android', () {
    setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.iOS);

    test('nothing is sent to the channel at all', () async {
      await RunForegroundService.start(title: 'x', body: 'y');
      await RunForegroundService.update(title: 'x', body: 'y');
      await RunForegroundService.stop();

      expect(calls, isEmpty);
    });

    test('permission is reported as unavailable rather than requested',
        () async {
      final platform = installFakeLocationPlatform();
      platform.permissions.status = PermissionStatus.granted;

      expect(await RunForegroundService.ensureNotificationPermission(), isFalse,
          reason: 'there is no Android foreground service to permit');
      expect(platform.permissions.requests, 0);
    });
  });

  group('notification permission', () {
    test('granted is reported as true', () async {
      final platform = installFakeLocationPlatform();
      platform.permissions.status = PermissionStatus.granted;

      expect(await RunForegroundService.ensureNotificationPermission(), isTrue);
    });

    test('denied is reported as false rather than thrown', () async {
      // The caller decides whether to warn; a refusal is not an error.
      final platform = installFakeLocationPlatform();
      platform.permissions.status = PermissionStatus.denied;

      expect(await RunForegroundService.ensureNotificationPermission(), isFalse);
    });

    test('permanently denied is false too', () async {
      final platform = installFakeLocationPlatform();
      platform.permissions.status = PermissionStatus.permanentlyDenied;

      expect(await RunForegroundService.ensureNotificationPermission(), isFalse);
    });
  });
}
