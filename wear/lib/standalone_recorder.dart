import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:path_provider/path_provider.dart';

/// One accepted GPS fix. Mirrors the phone's `TrackPoint`, but kept separate:
/// this one has to survive being written to disk and read back, which the
/// phone's in-memory version never does.
class RecordedFix {
  final double latitude;
  final double longitude;
  final double altitude;
  final DateTime time;

  const RecordedFix({
    required this.latitude,
    required this.longitude,
    required this.altitude,
    required this.time,
  });

  /// Short keys, and time as epoch millis. An hour of running is roughly 1800
  /// fixes; verbose keys would add tens of kilobytes to something that has to
  /// cross a Bluetooth link.
  Map<String, Object?> toJson() => {
        'a': latitude,
        'o': longitude,
        'e': altitude,
        't': time.millisecondsSinceEpoch,
      };

  factory RecordedFix.fromJson(Map<String, Object?> json) => RecordedFix(
        latitude: (json['a'] as num).toDouble(),
        longitude: (json['o'] as num).toDouble(),
        altitude: (json['e'] as num?)?.toDouble() ?? 0,
        time: DateTime.fromMillisecondsSinceEpoch(json['t'] as int),
      );
}

/// Records a run using the **watch's own GPS**, for running with the phone left
/// at home.
///
/// Deliberately produces nothing but a breadcrumb list. Distance is computed
/// only to show the runner a number; loop geometry, area and XP are never
/// calculated here, because they decide territory ownership and that has to be
/// derived where the server can verify it. The phone recomputes everything from
/// the raw fixes on import, so a tampered-with watch cannot claim ground.
///
/// Fixes are appended to a file as they arrive rather than held in memory until
/// the end. A standalone run has no phone to fall back on, so a crash, a reboot
/// or a flat battery would otherwise lose the whole thing.
class StandaloneRecorder {
  /// Coarser than the phone's 2 m filter. A watch battery has to survive the
  /// whole run *and* the rest of the day, and the extra resolution buys nothing
  /// once the trail is only being used for distance and loop geometry.
  static const int _distanceFilterMeters = 5;

  /// Same thresholds as the phone's controller, so an imported run is filtered
  /// the way a phone-recorded one would have been.
  static const double _accuracyThresholdMeters = 20.0;
  static const double _maxPlausibleSpeedMs = 8.0;

  /// Flushed on a timer rather than per fix: a write every 5 m of running would
  /// hammer the flash for no benefit, since losing the last few seconds of a
  /// run to a crash is survivable where losing all of it is not.
  static const Duration _flushInterval = Duration(seconds: 20);

  static const String _fileName = 'standalone_run.json';

  final List<RecordedFix> _fixes = [];
  StreamSubscription<Position>? _sub;
  Timer? _flushTimer;
  final Stopwatch _stopwatch = Stopwatch();
  double _distanceMeters = 0;
  bool _dirty = false;
  bool _streamFailed = false;

  List<RecordedFix> get fixes => List.unmodifiable(_fixes);
  double get distanceMeters => _distanceMeters;
  Duration get elapsed => _stopwatch.elapsed;
  bool get isRecording => _sub != null;

  /// True when the GPS stream died. The run keeps its clock, but no further
  /// fixes are arriving and the caller should say so rather than imply
  /// recording is healthy.
  bool get hasLostGps => _streamFailed;

  /// **Never call `Geolocator.isLocationServiceEnabled()` on Wear OS.**
  ///
  /// It always routes through Play Services' FusedLocationClient regardless of
  /// `forceLocationManager`, and on a watch that throws
  /// `ApiException: 10: Not implemented on this platform` — an uncaught *Java*
  /// exception on the main looper, which kills the process outright. A Dart
  /// try/catch cannot save you; the only defence is not calling it.
  ///
  /// Whether location is usable is therefore discovered the only safe way: by
  /// subscribing and seeing whether fixes arrive. [hasLostGps] reports the
  /// answer once the stream has had a chance to fail.

  /// Location settings for the watch's own GPS.
  ///
  /// `forceLocationManager: true` is the important part. Geolocator defaults to
  /// Play Services' *fused* provider, which on a Wear device with no phone
  /// attached reports the location service as disabled — even while the raw GPS
  /// provider is enabled and `cmd location is-location-enabled` returns true.
  /// The stream then errors once and dies, leaving a run that ticks along
  /// recording nothing. Talking to the platform LocationManager directly
  /// sidesteps the fused provider entirely, which is what we want anyway: this
  /// watch has its own GNSS and there is no phone to fuse with.
  static final LocationSettings _locationSettings = AndroidSettings(
    accuracy: LocationAccuracy.high,
    distanceFilter: _distanceFilterMeters,
    forceLocationManager: true,
  );

  /// Returns false when location is unavailable — permission refused, or the
  /// device's location switched off entirely — so the caller can stay in
  /// companion mode rather than starting a run that silently records nothing.
  Future<bool> start() async {
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      debugPrint('StandaloneRecorder: location denied ($permission)');
      return false;
    }

    _fixes.clear();
    _distanceMeters = 0;
    _streamFailed = false;
    _stopwatch
      ..reset()
      ..start();

    _sub = Geolocator.getPositionStream(
      locationSettings: _locationSettings,
    ).listen(_onPosition, onError: (Object e) {
      // A stream error terminates the subscription, so record that fixes have
      // stopped rather than leaving a run ticking over nothing.
      _streamFailed = true;
      debugPrint('StandaloneRecorder: position stream error — $e');
    });

    _flushTimer = Timer.periodic(_flushInterval, (_) => _flush());
    return true;
  }

  void _onPosition(Position pos) {
    if (pos.accuracy > _accuracyThresholdMeters) return;

    final fix = RecordedFix(
      latitude: pos.latitude,
      longitude: pos.longitude,
      altitude: pos.altitude,
      time: pos.timestamp,
    );

    if (_fixes.isNotEmpty) {
      final prev = _fixes.last;
      final metres = Geolocator.distanceBetween(
        prev.latitude,
        prev.longitude,
        fix.latitude,
        fix.longitude,
      );
      final seconds = fix.time.difference(prev.time).inMilliseconds / 1000.0;
      // Same GPS-spike rejection as the phone. Applied here as well as on
      // import so the distance shown on the wrist matches what the phone will
      // later compute, rather than drifting apart mid-run.
      if (seconds > 0 && metres / seconds > _maxPlausibleSpeedMs) return;
      _distanceMeters += metres;
    }

    _fixes.add(fix);
    _dirty = true;
  }

  Future<void> pause() async {
    _stopwatch.stop();
    await _sub?.cancel();
    _sub = null;
    await _flush();
  }

  Future<void> resume() async {
    if (_sub != null) return;
    _stopwatch.start();
    _sub = Geolocator.getPositionStream(
      locationSettings: _locationSettings,
    ).listen(_onPosition);
  }

  /// Stops recording and leaves the run on disk for the phone to collect. The
  /// file is deliberately *not* deleted here — it is the only copy until a
  /// transfer is confirmed.
  Future<void> stop() async {
    _stopwatch.stop();
    await _sub?.cancel();
    _sub = null;
    _flushTimer?.cancel();
    _flushTimer = null;
    await _flush(force: true);
  }

  Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_fileName');
  }

  Future<void> _flush({bool force = false}) async {
    if (!_dirty && !force) return;
    try {
      final file = await _file();
      await file.writeAsString(jsonEncode({
        'startedAt': DateTime.now().millisecondsSinceEpoch,
        'durationMs': _stopwatch.elapsed.inMilliseconds,
        'distanceMeters': _distanceMeters,
        'fixes': _fixes.map((f) => f.toJson()).toList(),
      }));
      _dirty = false;
    } catch (e) {
      // Never fatal: the run continues in memory. Losing persistence is worse
      // than not having it, but not worse than stopping the run.
      debugPrint('StandaloneRecorder: flush failed — $e');
    }
  }

  /// Reads back a run left on disk — after a crash, or waiting for the phone to
  /// come back into range. Returns null when there is nothing pending.
  static Future<Map<String, Object?>?> readPending() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$_fileName');
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      return decoded is Map ? decoded.cast<String, Object?>() : null;
    } catch (e) {
      debugPrint('StandaloneRecorder: could not read pending run — $e');
      return null;
    }
  }

  /// Records that the run has been handed to the Data Layer but not yet
  /// acknowledged. Only such a run is retried automatically on next launch —
  /// one the runner has not chosen to send is left where it is.
  static Future<void> markSent() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$_fileName');
      if (!await file.exists()) return;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return;
      decoded['sentAt'] = DateTime.now().millisecondsSinceEpoch;
      await file.writeAsString(jsonEncode(decoded));
    } catch (e) {
      debugPrint('StandaloneRecorder: could not mark sent — $e');
    }
  }

  /// True when a pending run has already been sent once and is still waiting
  /// on the phone's acknowledgement.
  static Future<bool> wasSent() async {
    final pending = await readPending();
    return pending != null && pending['sentAt'] != null;
  }

  /// Called only once the phone has confirmed it stored the run. Deleting on
  /// send rather than on acknowledgement would lose runs whenever a transfer
  /// failed halfway.
  static Future<void> clearPending() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$_fileName');
      if (await file.exists()) await file.delete();
    } catch (e) {
      debugPrint('StandaloneRecorder: could not clear pending run — $e');
    }
  }
}
