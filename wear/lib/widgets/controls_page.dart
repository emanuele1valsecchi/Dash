import 'package:dash_watch_protocol/dash_watch_protocol.dart';
import 'package:flutter/material.dart';

import '../watch_theme.dart';

/// Pause/resume and finish.
///
/// Finish is deliberately **hold-to-confirm**, not a tap. A watch face is
/// brushed constantly while running — sleeves, doorframes, the other wrist —
/// and a single tap that ends a run (and with it the territory it was about to
/// claim) is unrecoverable. Holding also avoids a confirmation dialog, which
/// would be worse: a modal on a 203 dp screen is hard to hit accurately and
/// takes two interactions instead of one.
class ControlsPage extends StatefulWidget {
  final RunStats stats;
  final ValueChanged<WatchCommand> onCommand;

  const ControlsPage({
    super.key,
    required this.stats,
    required this.onCommand,
  });

  @override
  State<ControlsPage> createState() => _ControlsPageState();
}

class _ControlsPageState extends State<ControlsPage>
    with SingleTickerProviderStateMixin {
  static const Duration _holdDuration = Duration(milliseconds: 1400);

  late final AnimationController _hold = AnimationController(
    vsync: this,
    duration: _holdDuration,
  )..addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        widget.onCommand(WatchCommand.finish);
        _hold.reset();
      }
    });

  @override
  void dispose() {
    _hold.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final paused = widget.stats.phase == RunPhase.paused;

    return RoundSafe(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _RoundButton(
            icon: paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
            label: paused ? 'RESUME' : 'PAUSE',
            color: WatchTheme.accent,
            onTap: () => widget.onCommand(
              paused ? WatchCommand.resume : WatchCommand.pause,
            ),
          ),
          const SizedBox(height: 14),
          // Press-and-hold: the ring fills as confirmation is accumulated, and
          // lifting early abandons it. Visible progress matters — a hold with
          // no feedback reads as an unresponsive button.
          GestureDetector(
            onTapDown: (_) => _hold.forward(),
            onTapUp: (_) => _hold.reverse(),
            onTapCancel: () => _hold.reverse(),
            child: AnimatedBuilder(
              animation: _hold,
              builder: (context, _) => Stack(
                alignment: Alignment.center,
                children: [
                  SizedBox(
                    width: 56,
                    height: 56,
                    child: CircularProgressIndicator(
                      value: _hold.value,
                      strokeWidth: 3,
                      color: WatchTheme.danger,
                      backgroundColor: Colors.transparent,
                    ),
                  ),
                  _RoundButton(
                    icon: Icons.stop_rounded,
                    label: _hold.value > 0.02 ? 'KEEP HOLDING' : 'HOLD TO END',
                    color: WatchTheme.danger,
                    onTap: null, // hold only — a tap must never end a run
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RoundButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback? onTap;

  const _RoundButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: color.withValues(alpha: 0.16),
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(11),
              child: Icon(icon, size: 24, color: color),
            ),
          ),
        ),
        const SizedBox(height: 3),
        Text(
          label,
          style: TextStyle(
            fontSize: 8.5,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.5,
            color: WatchTheme.secondaryText,
          ),
        ),
      ],
    );
  }
}
