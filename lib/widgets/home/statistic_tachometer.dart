import 'dart:math' as math;

import 'package:dash/extensions/responsive_spacing.dart';
import 'package:dash/models/home_models.dart';
import 'package:flutter/material.dart';

class StatisticTachometer extends StatelessWidget{
  final MonthlyStatData stat;

  const StatisticTachometer({
    super.key, 
    required this.stat
  });

  @override
  Widget build(BuildContext context) {
    final TextStyle statTextStyle = Theme.of(context).textTheme.headlineSmall!.copyWith(
      color: Theme.of(context).colorScheme.outline,
      fontWeight: FontWeight.bold,
    );

    TextStyle minorTextStyle = Theme.of(context).textTheme.bodyMedium!.copyWith(
      color: Theme.of(context).colorScheme.outline
    );

    return Column(
      mainAxisAlignment: MainAxisAlignment.start,
      children: [
        Stack(
          alignment: Alignment.center,
          children: [
            CustomPaint(
              size: const Size(130, 130),
              painter: _GaugePainter(
                progress: stat.progress, 
                strokeWidth: ResponsiveSpacing().sm,
                trackColor: Theme.of(context).colorScheme.surfaceContainerHigh,
                progressColor: Theme.of(context).colorScheme.tertiary,
              ),
            ),
            Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              spacing: ResponsiveSpacing().sm,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  spacing: ResponsiveSpacing().sm,
                  children: [
                    Icon(
                      stat.icon, 
                      size: minorTextStyle.fontSize! * 2, 
                      color: minorTextStyle.color
                    ),

                    Text(
                      stat.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: minorTextStyle,
                    ),
                  ],
                ),

                Text(
                  stat.value,
                  style: statTextStyle,
                ),
              ],
            ),
          ],
        ),

        Text(
          stat.bottomText,
          textAlign: TextAlign.center,
          style: minorTextStyle,
        ),
      ],
    );
  }
}

class _GaugePainter extends CustomPainter {
  final double progress;
  final double strokeWidth;
  final Color trackColor;
  final Color progressColor;

  const _GaugePainter({
    required this.progress,
    required this.strokeWidth,
    required this.trackColor,
    required this.progressColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.width - strokeWidth) / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);

    final trackPaint = Paint()
      ..color = trackColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    final progressPaint = Paint()
      ..color = progressColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    const startAngle = math.pi * 0.75;
    const sweepAngle = math.pi * 1.5;

    canvas.drawArc(rect, startAngle, sweepAngle, false, trackPaint);

    if (progress > 0) {
      // Garantiamo che il valore rimanga entro i limiti
      final validProgress = progress.clamp(0.0, 1.0);
      canvas.drawArc(rect, startAngle, sweepAngle * validProgress, false, progressPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _GaugePainter oldDelegate) {
    return oldDelegate.progress != progress;
  }
}