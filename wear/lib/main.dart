import 'package:flutter/material.dart';

import 'phone_relay_stats_source.dart';
import 'run_stats_source.dart';
import 'screens/watch_home.dart';
import 'watch_theme.dart';

void main() {
  runApp(const DashWearApp());
}

/// Dash's Wear OS companion.
///
/// Driven by [PhoneRelayStatsSource] — live data relayed from the phone over
/// the Wearable Data Layer. Swap in [FakeRunStatsSource] to develop the screens
/// without a phone in the room; nothing else changes, because every screen is
/// written against the [RunStatsSource] interface rather than a transport.
///
/// A standalone local-GPS source, for recording with the phone left at home,
/// slots into the same place later.
class DashWearApp extends StatefulWidget {
  const DashWearApp({super.key});

  @override
  State<DashWearApp> createState() => _DashWearAppState();
}

class _DashWearAppState extends State<DashWearApp> {
  final PhoneRelayStatsSource _source = PhoneRelayStatsSource();

  @override
  void initState() {
    super.initState();
    // Asks the phone for a snapshot straight away — messages are ephemeral, so
    // opening the watch app mid-run would otherwise show idle until the phone's
    // next tick.
    _source.start();
  }

  @override
  void dispose() {
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
