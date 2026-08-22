import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Controls the Android foreground service that keeps a run recording while the
/// phone is pocketed with the screen off.
///
/// The service holds an ongoing notification of type `location`; that is what
/// exempts the app from background location throttling. It owns no GPS —
/// `RunSessionController` keeps its existing stream and stays the single source
/// of truth, so a backgrounded run runs exactly the same code as a foregrounded
/// one rather than a second implementation that has to be kept in step.
///
/// Android-only. Every call is a no-op elsewhere, so callers need no platform
/// checks of their own.
class RunForegroundService {
  RunForegroundService._();

  static const MethodChannel _channel = MethodChannel('dash/run_service');

  static bool get _supported => defaultTargetPlatform == TargetPlatform.android;

  /// Asks for POST_NOTIFICATIONS if needed.
  ///
  /// On Android 13+ a refusal costs **background tracking entirely**, not just
  /// the alert: a foreground service cannot run without a visible notification.
  /// Returns false so the caller can decide whether to warn; the run itself
  /// still works while the screen is on.
  /// The watch app has no permission_handler dependency — POST_NOTIFICATIONS is
  /// requested natively in MainActivity alongside the heart rate permission, so
  /// there is nothing to do here.
  static Future<bool> ensureNotificationPermission() async => _supported;

  static Future<void> start({
    required String title,
    required String body,
  }) =>
      _invoke('start', title, body);

  /// Refreshes the notification text. Throttle this — the channel is
  /// IMPORTANCE_LOW and `setOnlyAlertOnce`, so it will not buzz, but pushing a
  /// notification update on every GPS fix is still wasted work.
  static Future<void> update({
    required String title,
    required String body,
  }) =>
      _invoke('update', title, body);

  static Future<void> stop() => _invoke('stop', null, null);

  static Future<void> _invoke(String method, String? title, String? body) async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod<bool>(method, {
        'title': ?title,
        'body': ?body,
      });
    } catch (e) {
      // Catches everything on purpose, not just PlatformException. The
      // realistic causes are Android 12+ refusing a background start and
      // MissingPluginException in unit tests (which is *not* a
      // PlatformException, and broke every controller test when this caught
      // only that). Either way the run carries on — it simply will not survive
      // the screen going off.
      debugPrint('RunForegroundService: $method failed — $e');
    }
  }
}
