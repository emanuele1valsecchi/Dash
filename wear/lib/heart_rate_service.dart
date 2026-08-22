import 'dart:async';

import 'package:dash_watch_protocol/dash_watch_protocol.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The watch's heart rate sensor, plus the running average and maximum for the
/// current run.
///
/// Accumulates here rather than on the phone because this is where every sample
/// arrives. The phone receives roughly one message a second, and none while the
/// link is down, so a phone-side average would silently be an average of
/// whatever happened to get through.
///
/// Degrades quietly at every step — no sensor, permission refused, or simply no
/// reading yet all end in the same place: [reading] with null fields, which the
/// UI renders as "--". A runner without a heart rate sensor should see a dash,
/// not an error.
class HeartRateService {
  static const MethodChannel _channel = MethodChannel('dash/heart_rate');
  static const EventChannel _values = EventChannel('dash/heart_rate/values');

  StreamSubscription<dynamic>? _sub;

  int? _current;
  int? _max;
  int _sum = 0;
  int _samples = 0;

  /// True when the device has the sensor at all. Some Wear watches do not.
  bool get isAvailable => _isAvailable;
  bool _isAvailable = false;

  bool get isPermitted => _isPermitted;
  bool _isPermitted = false;

  /// Emitted whenever a new sample lands, so the UI can repaint.
  Stream<HeartRateReading> get readings => _controller.stream;
  final _controller = StreamController<HeartRateReading>.broadcast();

  HeartRateReading get reading => HeartRateReading(
        currentBpm: _current,
        averageBpm: _samples == 0 ? null : (_sum / _samples).round(),
        maxBpm: _max,
      );

  Future<void> start() async {
    _isAvailable =
        await _channel.invokeMethod<bool>('isAvailable') ?? false;
    if (!_isAvailable) {
      debugPrint('HeartRate: no sensor on this device');
      return;
    }

    // MainActivity fires the request on launch. Poll rather than await a
    // result callback: the permission that matters on Wear OS 6 is a Health
    // Connect one that permission_handler cannot express, so there is no
    // plugin-level future to await — and the user needs time to read a prompt
    // on a watch-sized screen.
    _isPermitted = await _awaitPermission();
    if (!_isPermitted) {
      debugPrint('HeartRate: permission not granted — staying at "--"');
      return;
    }

    _sub = _values.receiveBroadcastStream().listen(
          _onSample,
          onError: (Object error) =>
              debugPrint('HeartRate: sensor stream error — $error'),
        );
  }

  /// Waits for the launch-time permission prompt to be answered, giving up
  /// after [_permissionTimeout]. Giving up is not a failure state — it just
  /// means the reading stays "--", which is the same place a device with no
  /// sensor ends up.
  Future<bool> _awaitPermission() async {
    final deadline = DateTime.now().add(_permissionTimeout);
    while (DateTime.now().isBefore(deadline)) {
      if (await _channel.invokeMethod<bool>('hasPermission') ?? false) {
        return true;
      }
      await Future<void>.delayed(_permissionPollInterval);
    }
    return false;
  }

  static const Duration _permissionTimeout = Duration(seconds: 45);
  static const Duration _permissionPollInterval = Duration(seconds: 2);

  void _onSample(dynamic raw) {
    if (raw is! int) return;

    _current = raw;
    _sum += raw;
    _samples++;
    if (_max == null || raw > _max!) _max = raw;

    if (!_controller.isClosed) _controller.add(reading);
  }

  /// Clears the accumulated average and maximum for a new run, without tearing
  /// down the sensor subscription — the same hazard the phone's
  /// `RunSessionController.reset` guards against, for the same reason: carrying
  /// one run's numbers into the next.
  void resetAccumulation() {
    _current = null;
    _max = null;
    _sum = 0;
    _samples = 0;
  }

  void dispose() {
    _sub?.cancel();
    _controller.close();
  }
}
