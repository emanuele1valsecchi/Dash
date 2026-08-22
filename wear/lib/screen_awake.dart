import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Stops Wear OS blanking the display while a run is recording.
///
/// Ambient mode alone is not enough. It keeps the app resident and dims the
/// screen, which is what we want — but only while the app is actually the
/// foreground activity. Wear will otherwise drop back to the watch face and
/// take the run screen with it, which is exactly what happened on a real walk.
///
/// Paired with the watch's dismissal guard: this keeps the screen alive, that
/// keeps the app in front of it. Neither works alone.
class ScreenAwake {
  ScreenAwake._();

  static const MethodChannel _channel = MethodChannel('dash/screen');

  static Future<void> set(bool keep) async {
    try {
      await _channel.invokeMethod<bool>('keepAwake', {'keep': keep});
    } catch (e) {
      // Never fatal — the run continues, the screen just behaves normally.
      debugPrint('ScreenAwake: could not set keepAwake=$keep — $e');
    }
  }
}
