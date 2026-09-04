import 'dart:ui';

import 'package:flutter/material.dart';

/// The compact stats overlay shown on the expanded run map, in place of the
/// full stats panel. Tapping anywhere on it collapses the map again.

class ExpandedStatsBar extends StatelessWidget {
  final String time;
  final String distance;
  final String pace;

  final String rateUnitLabel;

  final int loopsCompleted;
  final VoidCallback onCollapse;

  const ExpandedStatsBar({
    super.key,
    required this.time,
    required this.distance,
    required this.pace,
    required this.rateUnitLabel,
    required this.loopsCompleted,
    required this.onCollapse,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      elevation: 4,
      shadowColor: Colors.black45,
      borderRadius: BorderRadius.circular(24),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: InkWell(
            onTap: onCollapse,
            child: Container(
              color: Colors.white.withValues(alpha: 0.92),
              padding: const EdgeInsets.fromLTRB(22, 18, 16, 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    time,
                    style: const TextStyle(
                      fontSize: 32,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF1F3020),
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Text(
                        '$distance  ·  $pace $rateUnitLabel',
                        style: const TextStyle(
                          fontSize: 16,
                          color: Color(0xFF425143),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (loopsCompleted > 0) ...[
                        const SizedBox(width: 10),
                        const Icon(Icons.crop_free_rounded, size: 17, color: Color(0xFF2E7D32)),
                        const SizedBox(width: 3),
                        Text(
                          '$loopsCompleted',
                          style: const TextStyle(
                              fontSize: 16, color: Color(0xFF2E7D32), fontWeight: FontWeight.w800),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
