import 'package:flutter/material.dart';

/// The lit "loop closed" banner under the live stats. Inert until the run
/// has actually closed a loop, so a runner can tell at a glance whether they
/// have claimed anything yet.

class LoopIndicator extends StatelessWidget {
  final int loopsCompleted;

  const LoopIndicator({super.key, required this.loopsCompleted});

  @override
  Widget build(BuildContext context) {
    final isActive = loopsCompleted > 0;
    final bg = isActive ? const Color(0xFFCAF0B8) : const Color(0xFFECEFE6);
    final fg = isActive ? const Color(0xFF2E7D32) : const Color(0xFF9AA294);

    return TweenAnimationBuilder<double>(
      key: ValueKey(loopsCompleted),
      tween: Tween(begin: isActive ? 0.85 : 1.0, end: 1.0),
      duration: const Duration(milliseconds: 320),
      curve: Curves.elasticOut,
      builder: (context, scale, child) => Transform.scale(scale: scale, child: child),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              isActive ? Icons.crop_free_rounded : Icons.crop_free_outlined,
              size: 20,
              color: fg,
            ),
            const SizedBox(width: 10),
            Text(
              isActive ? 'Loop closed — area claimed × $loopsCompleted' : 'No loop closed yet',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: fg),
            ),
          ],
        ),
      ),
    );
  }
}
