import 'dart:async';

import 'package:dash_watch_protocol/dash_watch_protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wear_plus/wear_plus.dart';

import '../run_stats_source.dart';
import '../watch_run_coordinator.dart';
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
  /// The phone publishes every second, so several missed messages in a row
  /// means something is wrong rather than merely slow.
  static const Duration _staleAfter = Duration(seconds: 5);

  final PageController _pager = PageController();
  late RunStats _stats = widget.source.current;
  StreamSubscription<RunStats>? _sub;
  int _lastLoopCount = 0;

  /// When the last snapshot arrived from the phone, so the clock can be carried
  /// forward locally between messages — see [_displayStats].
  DateTime _lastMessageAt = DateTime.now();

  /// Repaints between phone messages. Nothing to do with the data rate: it
  /// exists purely so the seconds tick over smoothly.
  Timer? _clockTicker;

  @override
  void initState() {
    super.initState();
    _sub = widget.source.stats.listen(_onStats);

    final source = widget.source;
    if (source is WatchRunCoordinator) {
      _sendState = source.sendState;
      _sendSub = source.sendStates.listen((state) {
        if (mounted) setState(() => _sendState = state);
      });
    }
    _clockTicker = Timer.periodic(
      const Duration(milliseconds: 200),
      (_) {
        if (mounted && _stats.phase == RunPhase.running) setState(() {});
      },
    );
  }

  /// The phone publishes once a second, which left the watch's clock visibly
  /// lagging and jumping a second at a time. Rather than publish faster — which
  /// costs Bluetooth radio time and battery on both devices for no extra
  /// information — the watch carries the clock forward itself using the time
  /// since the last snapshot.
  ///
  /// Only the clock is extrapolated. Distance, pace and heart rate hold their
  /// last received values, because those genuinely are unknown until the phone
  /// says otherwise; elapsed time is the one quantity the watch can derive
  /// without guessing. Paused and finished runs are shown exactly as received,
  /// since their clock is not moving.
  RunStats get _displayStats {
    if (_stats.phase != RunPhase.running) return _stats;
    final sinceMessage = DateTime.now().difference(_lastMessageAt);
    // Safety net: if the phone has gone quiet for longer than a few ticks, the
    // link is down or the run ended without us hearing. Freeze rather than
    // count into fiction — a stopped clock reads as a problem, a clock still
    // running reads as a run still happening.
    if (sinceMessage > _staleAfter) return _stats;
    return _stats.copyWith(elapsed: _stats.elapsed + sinceMessage);
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

    setState(() {
      _stats = stats;
      _lastMessageAt = DateTime.now();
    });
  }

  @override
  void dispose() {
    _clockTicker?.cancel();
    _sub?.cancel();
    _sendSub?.cancel();
    _pager.dispose();
    super.dispose();
  }

  /// Non-null only while this watch is holding a run of its own to hand over.
  RunSendState? _sendState;
  StreamSubscription<RunSendState>? _sendSub;

  void _sendRun() {
    final source = widget.source;
    if (source is WatchRunCoordinator) source.sendPendingRun();
  }

  void _send(WatchCommand command) {
    widget.source.send(command);

    // Show the summary straight away rather than waiting for the phone to
    // confirm. Ending is already deliberate — it took a 1.4 s hold — so there
    // is nothing left to confirm, and a wrist that appears to ignore a
    // long-press reads as broken. The phone's own `finished` message follows
    // and simply agrees.
    if (command == WatchCommand.finish) {
      setState(() => _stats = _stats.copyWith(phase: RunPhase.finished));
    }
  }

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
            RunPhase.finished => _FinishedScreen(
              stats: _displayStats,
              onDismiss: widget.source.dismissSummary,
              // Only a run the watch recorded itself has anything to send.
              sendState: _sendState,
              onSend: _sendState == null ? null : _sendRun,
            ),
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
    final stats = _displayStats;
    if (ambient) return MetricsPage(stats: stats, ambient: true);

    return PageView(
      controller: _pager,
      scrollDirection: Axis.vertical,
      children: [
        MetricsPage(stats: stats, ambient: false),
        NavigationPage(stats: stats, ambient: false),
        TerritoryPage(stats: stats, ambient: false),
        ControlsPage(stats: stats, onCommand: _send),
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

  /// Clears the summary. For a run the watch recorded itself this is the only
  /// way back to the start screen — nothing on the phone dismisses it, and
  /// without it the watch sits on a finished run forever.
  final VoidCallback onDismiss;

  /// Null when there is nothing to hand over, i.e. the phone recorded this run.
  final RunSendState? sendState;
  final VoidCallback? onSend;

  const _FinishedScreen({
    required this.stats,
    required this.onDismiss,
    required this.sendState,
    required this.onSend,
  });

  @override
  Widget build(BuildContext context) {
    // A scroll view, not a Column: five stats plus the footer overflow a
    // ~203 dp round screen, and this is the one screen a runner reads standing
    // still, so scrolling costs nothing here.
    return GestureDetector(
      onTap: onDismiss,
      // Opaque so a tap on the black around the text still counts — a precise
      // target is the wrong ask on a wrist.
      behavior: HitTestBehavior.opaque,
      child: RoundSafe(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.check_circle_outline,
                size: 24, color: WatchTheme.accent),
            const SizedBox(height: 6),
            Metric(
              value: WatchFormat.distanceKm(stats.distanceMeters),
              label: 'KM',
              valueSize: 30,
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                Metric(
                  value: WatchFormat.duration(stats.elapsed),
                  label: 'TIME',
                  valueSize: 18,
                ),
                Metric(
                  value: WatchFormat.pace(stats.paceMinPerKm),
                  label: '/KM',
                  valueSize: 18,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                Metric(
                  value: WatchFormat.areaKm2(stats.claimedAreaM2),
                  label: 'KM² WON',
                  valueSize: 18,
                  valueColor:
                      stats.loopsCompleted > 0 ? WatchTheme.accent : null,
                ),
                Metric(
                  value: '${stats.loopsCompleted}',
                  label: 'LOOPS',
                  valueSize: 18,
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (onSend != null) _SendButton(state: sendState!, onSend: onSend!),
            const SizedBox(height: 8),
            Text(
              onSend == null
                  ? 'Save or discard\non your phone'
                  : 'Tap outside to dismiss',
              textAlign: TextAlign.center,
              style:
                  const TextStyle(fontSize: 9, color: WatchTheme.secondaryText),
            ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Hands a finished standalone run to the phone, on the runner's say-so.
///
/// Explicit rather than automatic on finish. The transfer is invisible and can
/// take a while — the phone may be at home — so a runner who has just stopped
/// deserves to be told it happened rather than left wondering. It also puts the
/// runner in control of when their run leaves the watch.
class _SendButton extends StatelessWidget {
  final RunSendState state;
  final VoidCallback onSend;

  const _SendButton({required this.state, required this.onSend});

  @override
  Widget build(BuildContext context) {
    final (String label, IconData icon, Color colour) = switch (state) {
      RunSendState.idle => ('SEND TO PHONE', Icons.upload_rounded, WatchTheme.accent),
      RunSendState.sending => ('SENDING…', Icons.more_horiz_rounded, WatchTheme.accent),
      // "Queued", not "Delivered": the Data Layer holds it until the phone is
      // next in range, which may be much later. Claiming it had arrived would
      // be a lie whenever the phone is still at home.
      RunSendState.sent => ('QUEUED', Icons.check_rounded, WatchTheme.accent),
      RunSendState.failed => ('RETRY', Icons.refresh_rounded, WatchTheme.warning),
    };

    final done = state == RunSendState.sent || state == RunSendState.sending;

    return Material(
      color: colour.withValues(alpha: done ? 0.10 : 0.20),
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: done ? null : onSend,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 15, color: colour),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                  color: colour,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
