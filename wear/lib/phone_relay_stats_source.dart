import 'dart:async';

import 'package:dash_watch_protocol/dash_watch_protocol.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'run_stats_source.dart';

/// Live run data relayed from the phone over the Wearable Data Layer.
///
/// The watch is a display and a remote control, never a source of truth: it
/// recomputes nothing, so the two devices can never disagree about how far you
/// have run. Commands go the other way and are *requests* — the phone owns the
/// session and may ignore them.
///
/// Messages are ephemeral (see the Kotlin bridge for why `MessageClient` rather
/// than `DataClient`), so this asks the phone for a snapshot on startup via
/// [WearPaths.requestSync]. Without that, opening the watch app mid-run would
/// show an idle screen until the phone's next tick — and show nothing at all if
/// the phone were paused.
class PhoneRelayStatsSource implements RunStatsSource {
  static const MethodChannel _channel = MethodChannel('dash/wear_bridge');
  static const EventChannel _messages =
      EventChannel('dash/wear_bridge/messages');

  /// How long to wait for the phone before admitting it isn't there. Generous:
  /// a Bluetooth link that has gone idle can take a couple of seconds to carry
  /// the first message.
  static const Duration _syncTimeout = Duration(seconds: 6);

  final _controller = StreamController<RunStats>.broadcast();
  StreamSubscription<dynamic>? _incoming;
  Timer? _syncTimer;

  RunStats _current = RunStats.idle;
  bool _heardFromPhone = false;

  /// The watch's own sensor. Merged into every snapshot below rather than
  /// waiting for the phone to echo it back — a round trip would add a second of
  /// latency to a number measured on this very device, and would blank out
  /// entirely whenever the link dropped.
  HeartRateReading _heartRate = const HeartRateReading();
  Timer? _heartRateUplink;

  /// True once any message has arrived. Lets the UI distinguish "the phone says
  /// the run is idle" from "no phone here" — which look identical otherwise and
  /// mean very different things to someone standing at a start line.
  bool get isConnected => _heardFromPhone;

  @override
  Stream<RunStats> get stats => _controller.stream;

  @override
  RunStats get current => _current;

  Future<void> start() async {
    _incoming = _messages.receiveBroadcastStream().listen(
          _onMessage,
          onError: (Object error) =>
              debugPrint('PhoneRelay: stream error — $error'),
        );

    await _requestSync();
    // Retry once: the very first message after a link wakes up is the one most
    // likely to be dropped.
    _syncTimer = Timer(_syncTimeout, () {
      if (!_heardFromPhone) _requestSync();
    });
  }

  Future<void> _requestSync() =>
      _send(WearPaths.requestSync, payload: '');

  void _onMessage(dynamic raw) {
    if (raw is! Map) return;
    if (raw['path'] != WearPaths.stats) return;

    final decoded = RunStats.decode(raw['payload'] as String? ?? '');
    // decode returns null on anything malformed rather than throwing, so a
    // corrupt message leaves the last good reading on screen instead of taking
    // the watch down mid-run.
    if (decoded == null) {
      debugPrint('PhoneRelay: dropped an undecodable stats message');
      return;
    }

    _heardFromPhone = true;
    _current = decoded.copyWith(heartRateBpm: _heartRate.currentBpm);
    if (!_controller.isClosed) _controller.add(_current);
  }

  /// Feeds the watch's own heart rate into the display and starts relaying it
  /// to the phone. Separate from [start] so the sensor stays optional — a watch
  /// without one, or without permission, simply never calls this.
  void attachHeartRate(Stream<HeartRateReading> readings) {
    _heartRateSub = readings.listen((reading) {
      _heartRate = reading;
      // Show it immediately; the uplink below is a slower, separate concern.
      _current = _current.copyWith(heartRateBpm: reading.currentBpm);
      if (!_controller.isClosed) _controller.add(_current);
    });

    // Uplink on its own timer rather than per sample: the sensor fires several
    // times a second and the phone only needs it often enough to store an
    // up-to-date average and maximum at the end of the run.
    _heartRateUplink = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!_heartRate.hasReading) return;
      _send(WearPaths.heartRate, payload: _heartRate.encode());
    });
  }

  StreamSubscription<HeartRateReading>? _heartRateSub;

  @override
  Future<void> send(WatchCommand command) =>
      _send(WearPaths.command, payload: command.name);

  Future<void> _send(String path, {required String payload}) async {
    try {
      await _channel.invokeMethod<int>('send', {
        'path': path,
        'payload': payload,
      });
    } on PlatformException catch (e) {
      // The phone being out of range is an ordinary state on a wrist, not a
      // failure worth surfacing as an error.
      debugPrint('PhoneRelay: send on $path failed — ${e.message}');
    }
  }

  @override
  void dispose() {
    _syncTimer?.cancel();
    _heartRateUplink?.cancel();
    _heartRateSub?.cancel();
    _incoming?.cancel();
    _controller.close();
  }
}
