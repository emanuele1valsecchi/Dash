import 'dart:async';

import 'package:dash_watch_protocol/dash_watch_protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wear_plus/wear_plus.dart';

import '../run_stats_source.dart';
import '../watch_theme.dart';
import '../widgets/controls_page.dart';
import '../widgets/metric.dart';
import '../widgets/metrics_page.dart';
import '../widgets/navigation_page.dart';
import '../widgets/territory_page.dart';

/// Root of the watch app: routes on run phase, and while running presents the
/// four pages as a **vertical** pager.
///
/// Vertical, not horizontal, and that is not a style preference: Wear OS's
/// system back gesture is a swipe in from the left edge, so a horizontal
/// PageView fights the OS for every swipe and users end up leaving the app by
/// accident. Scrolling vertically also matches how the rotating bezel and crown
/// already scroll on these devices.
class WatchHome extends StatefulWidget {
  final RunStatsSource source;

  const WatchHome({super.key, required this.source});

  @override
  State<WatchHome> createState() => _WatchHomeState();
}

class _WatchHomeState extends State<WatchHome> {
  final PageController _pager = PageController();
  late RunStats _stats = widget.source.current;
  StreamSubscription<RunStats>? _sub;
  int _lastLoopCount = 0;

  @override
  void initState() {
    super.initState();
    _sub = widget.source.stats.listen(_onStats);
  }

  void _onStats(RunStats stats) {
    if (!mounted) return;

    // A closed loop is the one event worth interrupting a run for. Buzz rather
    // than rely on the runner happening to be looking at the territory page —
    // the whole point of a wrist device is being told without looking.
    if (stats.loopsCompleted > _lastLoopCount) {
      HapticFeedback.heavyImpact();
    }
    _lastLoopCount = stats.loopsCompleted;

    setState(() => _stats = stats);
  }

  @override
  void dispose() {
    _sub?.cancel();
    _pager.dispose();
    super.dispose();
  }

  void _send(WatchCommand command) => widget.source.send(command);

  @override
  Widget build(BuildContext context) {
    return AmbientMode(
      builder: (context, mode, _) {
        final ambient = mode == WearMode.ambient;
        return Scaffold(
          backgroundColor: WatchTheme.background,
          body: switch (_stats.phase) {
            RunPhase.idle => _IdleScreen(onStart: () => _send(WatchCommand.start)),
            RunPhase.countdown => _CountdownScreen(value: _stats.countdownValue),
            RunPhase.finished => _FinishedScreen(stats: _stats),
            RunPhase.running || RunPhase.paused => _buildPager(ambient),
          },
        );
      },
    );
  }

  Widget _buildPager(bool ambient) {
    // Ambient updates arrive about once a minute and burn-in protection rules
    // out large bright areas, so ambient collapses to the metrics page only —
    // paging through screens nobody is looking at would just cost battery.
    if (ambient) return MetricsPage(stats: _stats, ambient: true);

    return PageView(
      controller: _pager,
      scrollDirection: Axis.vertical,
      children: [
        MetricsPage(stats: _stats, ambient: false),
        NavigationPage(stats: _stats, ambient: false),
        TerritoryPage(stats: _stats, ambient: false),
        ControlsPage(stats: _stats, onCommand: _send),
      ],
    );
  }
}

class _IdleScreen extends StatelessWidget {
  final VoidCallback onStart;

  const _IdleScreen({required this.onStart});

  @override
  Widget build(BuildContext context) {
    return RoundSafe(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text(
            'DASH',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w800,
              letterSpacing: 3,
              color: WatchTheme.accent,
            ),
          ),
          const SizedBox(height: 14),
          Material(
            color: WatchTheme.accent,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onStart,
              child: const Padding(
                padding: EdgeInsets.all(18),
                child: Icon(Icons.play_arrow_rounded,
                    size: 34, color: Colors.black),
              ),
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            'START RUN',
            style: TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.w700,
              letterSpacing: 1,
              color: WatchTheme.secondaryText,
            ),
          ),
        ],
      ),
    );
  }
}

/// Mirrors the phone's 5-second pre-run countdown, so a run started from either
/// device behaves identically.
class _CountdownScreen extends StatelessWidget {
  final int value;

  const _CountdownScreen({required this.value});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        '$value',
        style: const TextStyle(
          fontSize: 76,
          fontWeight: FontWeight.w800,
          color: WatchTheme.accent,
          fontFeatures: [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

/// The run is over and the phone owns what happens next — naming it, saving it,
/// claiming territory. The watch deliberately offers no save/discard choice:
/// duplicating that decision on two screens invites making it twice.
class _FinishedScreen extends StatelessWidget {
  final RunStats stats;

  const _FinishedScreen({required this.stats});

  @override
  Widget build(BuildContext context) {
    return RoundSafe(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.check_circle_outline,
              size: 26, color: WatchTheme.accent),
          const SizedBox(height: 8),
          Metric(
            value: WatchFormat.distanceKm(stats.distanceMeters),
            label: 'KM',
            valueSize: 30,
          ),
          const SizedBox(height: 6),
          Metric(
            value: WatchFormat.duration(stats.elapsed),
            label: 'TIME',
            valueSize: 19,
          ),
          const SizedBox(height: 10),
          const Text(
            'Finish on\nyour phone',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 10, color: WatchTheme.secondaryText),
          ),
        ],
      ),
    );
  }
}
