import 'package:flutter/material.dart';

import 'heart_rate_service.dart';
import 'phone_relay_stats_source.dart';
import 'watch_run_coordinator.dart';
import 'run_stats_source.dart';
import 'screens/watch_home.dart';
import 'watch_theme.dart';

void main() {
  runApp(const DashWearApp());
}

/// Dash's Wear OS companion.
///
/// Driven by [PhoneRelayStatsSource] — live data relayed from the phone over
/// the Wearable Data Layer — or by the watch's own GPS when there is no phone
/// to relay from. Nothing else changes between the two, because every screen
/// is written against the [RunStatsSource] interface rather than a transport,
/// and [WatchRunCoordinator] presents whichever is active as that interface.
class DashWearApp extends StatefulWidget {
  const DashWearApp({super.key});

  @override
  State<DashWearApp> createState() => _DashWearAppState();
}

class _DashWearAppState extends State<DashWearApp> {
  late final WatchRunCoordinator _source =
      WatchRunCoordinator(relay: PhoneRelayStatsSource());
  final HeartRateService _heartRate = HeartRateService();

  @override
  void initState() {
    super.initState();
    // Asks the phone for a snapshot straight away — messages are ephemeral, so
    // opening the watch app mid-run would otherwise show idle until the phone's
    // next tick.
    _source.start();
    _startHeartRate();
  }

  /// Heart rate is entirely optional: no sensor, or permission refused, leaves
  /// the reading null and the UI showing "--". Nothing else changes.
  Future<void> _startHeartRate() async {
    await _heartRate.start();
    if (!_heartRate.isAvailable || !_heartRate.isPermitted) return;
    _source.attachHeartRate(_heartRate.readings);
  }

  @override
  void dispose() {
    _heartRate.dispose();
    _source.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Dash',
      debugShowCheckedModeBanner: false,
      theme: WatchTheme.theme,
      home: WatchHome(source: _source),
    );
  }
}
