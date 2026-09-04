import 'dart:math' as math;

import 'package:dash/extensions/responsive_spacing.dart';
import 'package:dash/models/home_models.dart';
import 'package:flutter/material.dart';

class StatisticTachometer extends StatelessWidget{
  final MonthlyStatData stat;
  final List<MonthlyStatData> allStats;

  const StatisticTachometer({
    super.key, 
    required this.stat,
    required this.allStats,
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
      mainAxisSize: MainAxisSize.min,
      spacing: ResponsiveSpacing().sm,
      children: [
        CustomPaint(
          painter: _GaugePainter(
            progress: stat.progress, 
            strokeWidth: ResponsiveSpacing().sm,
            trackColor: Theme.of(context).colorScheme.surfaceContainerHigh,
            progressColor: Theme.of(context).colorScheme.tertiary,
          ),
          child: IntrinsicWidth(
            child: AspectRatio(
              aspectRatio: 1.0,
              child: Padding(
                padding: EdgeInsets.all(ResponsiveSpacing().lg),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    ExcludeSemantics(
                      child: Visibility(
                        visible: false,
                        maintainSize: true,
                        maintainAnimation: true,
                        maintainState: true,
                        child: Stack(
                          children: allStats.map((stat) {
                            return _buildInnerContent(stat, statTextStyle, minorTextStyle);
                          }).toList(),
                        ),
                      ),
                    ),
                    
                    _buildInnerContent(stat, statTextStyle, minorTextStyle),
                  ],
                ),
              ),
            ),
          ),
        ),
        
        Stack(
          alignment: Alignment.topCenter,
          children: [
            ExcludeSemantics(
              child: Visibility(
                visible: false,
                maintainSize: true,
                maintainAnimation: true,
                maintainState: true,
                child: Stack(
                  children: allStats.map((stat) {
                    return Text(
                      stat.bottomText,
                      textAlign: TextAlign.center,
                      style: minorTextStyle,
                    );
                  }).toList(),
                ),
              ),
            ),
            Text(
              stat.bottomText,
              textAlign: TextAlign.center,
              style: minorTextStyle,
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildInnerContent(MonthlyStatData itemData, TextStyle statStyle, TextStyle minorStyle) {
    return Column(
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
              itemData.icon, 
              size: minorStyle.fontSize! * 2, 
              color: minorStyle.color
            ),
            Text(
              itemData.title,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: minorStyle,
            ),
          ],
        ),
        Text(
          itemData.value,
          style: statStyle,
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
      final validProgress = progress.clamp(0.0, 1.0);
      canvas.drawArc(rect, startAngle, sweepAngle * validProgress, false, progressPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _GaugePainter oldDelegate) {
    return oldDelegate.progress != progress;
  }
}