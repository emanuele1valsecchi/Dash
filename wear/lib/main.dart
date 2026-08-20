import 'package:flutter/material.dart';

import 'run_stats_source.dart';
import 'screens/watch_home.dart';
import 'watch_theme.dart';

void main() {
  runApp(const DashWearApp());
}

/// Dash's Wear OS companion.
///
/// Currently driven by [FakeRunStatsSource] so the real screens can be built
/// and judged on a real wrist before any phone pairing exists. Swapping in the
/// Wearable Data Layer relay — and later a standalone local-GPS source — is a
/// one-line change here, because every screen is written against the
/// [RunStatsSource] interface rather than against a specific transport.
class DashWearApp extends StatefulWidget {
  const DashWearApp({super.key});

  @override
  State<DashWearApp> createState() => _DashWearAppState();
}

class _DashWearAppState extends State<DashWearApp> {
  final RunStatsSource _source = FakeRunStatsSource();

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
