import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:dash/extensions/responsive_border_radius.dart';
import 'package:dash/extensions/responsive_spacing.dart';
import 'package:dash/models/home_badge_ui_model.dart';
import 'package:dash/widgets/badge/badge_overlay_container.dart';
import 'package:flutter/material.dart';
import 'dart:math';

import 'package:material_symbols_icons/symbols.dart';

class DashBadge extends StatelessWidget{
  final HomeBadgeUiModel badge;
  
  final double dimFactor;

  ///Set progress to:
  /// * null -> the badge is blocked without the round circol around it
  /// * 0.0 -> the badge is blocked but with a round circol around
  /// * double -> the badge is unlocking with a circol that colors up
  /// * 1.0 -> the badge is fully unlocked
  final double? progress;

  final bool clickable;

  static const ColorFilter _greyscale = ColorFilter.matrix(<double>[
    0.2126, 0.7152, 0.0722, 0, 0,
    0.2126, 0.7152, 0.0722, 0, 0,
    0.2126, 0.7152, 0.0722, 0, 0,
    0,      0,      0,      1, 0,
  ]);

  const DashBadge({
    super.key, 
    required this.badge,
    required this.progress,
    required this.clickable,

    this.dimFactor = 0.26,
  });

  @override
  Widget build(BuildContext context) {
    final double size = MediaQuery.widthOf(context) * dimFactor;

    final double strokeWidth = ResponsiveSpacing().sm * 2 / 3;

    CachedNetworkImage image = CachedNetworkImage(
      imageUrl: badge.imageUrl,
      width: size,
      height: size,
      fit: BoxFit.cover,

      placeholder: (context, url) => Container(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        alignment: Alignment.center,
        child: const CircularProgressIndicator(),
      ),

      errorWidget: (context, url, error) => Container(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        alignment: Alignment.center,
        child: Icon(
          Symbols.workspace_premium_rounded,
          fill: 1,
          color: Theme.of(context).colorScheme.tertiary,
        ),
      ),
    );

    return GestureDetector(
      onTap: clickable
        ? () => showBadgeOverlay(
          context: context, 
          badge: badge, 
          progress: progress
          )
        : null,
      behavior: HitTestBehavior.opaque,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        spacing: ResponsiveSpacing().sm,
        children: [
          CustomPaint(
            painter: _RingPainter(
              progress: progress, 
              unlockedColor: Theme.of(context).colorScheme.primary, 
              trackColor: Theme.of(context).colorScheme.surfaceContainerHigh, 
              progressColor: Theme.of(context).colorScheme.tertiary,
              strokeWidth: strokeWidth
            ),
            
            child: Padding(
              padding: context.paddingSm,
                child: SizedBox(
                width: size,
                height: size,
                child: ClipOval(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      ( progress == 1.0 )
                        ? image
                        : ColorFiltered(
                            colorFilter: _greyscale, 
                            child: image
                          ),
                      if ( progress != null && progress! > 0.0 && progress! < 1.0 )
                        ClipPath(
                          clipper: _WedgeClipper(progress!),
                          child: image,
                        )
                    ],
                  ),
                ),
              ) 
            ),
          ),

          SizedBox(
            width: size + (context.responsiveSpacing.sm * 2) + (strokeWidth * 2),
            child: Text(
              badge.title,
              maxLines: 2,
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyMedium!.copyWith(
                color: ( progress != null ) 
                  ? Theme.of(context).colorScheme.outline
                  : null,
                fontWeight: ( progress == null )
                  ? FontWeight.bold
                  : null,
              )
            )
          ),
        ],
      )
    );
  }

  void showBadgeOverlay({
    required BuildContext context,
    required HomeBadgeUiModel badge,
    required double? progress,
  }) {
    showDialog(
      context: context,
      barrierColor: Theme.of(context).colorScheme.onSurface.withAlpha(140),
      builder: (BuildContext context) {
        return BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 8.0, sigmaY: 8.0),
          child: Dialog(
            backgroundColor: Theme.of(context).colorScheme.surface,
            shape: RoundedRectangleBorder(
              borderRadius: context.radiusXl,
            ),
            child: BadgeOverlayContainer(
              badge: badge,
              progress: progress,
            )
          ),
        );
      },
    );
  }
}

class _RingPainter extends CustomPainter {
  final double? progress;
  final Color unlockedColor;
  final Color trackColor;
  final Color progressColor;
  final double strokeWidth;

  _RingPainter({
    required this.progress, 
    required this.unlockedColor, 
    required this.trackColor, 
    required this.progressColor, 
    required this.strokeWidth,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = ( size.width - strokeWidth ) / 2;

    final backgroundPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;

    if ( progress != null ){
      backgroundPaint.color = (progress == 1.0) ? unlockedColor : trackColor;
      canvas.drawCircle(center, radius, backgroundPaint);
    }

    if (progress != null && progress! > 0 && progress! < 1.0) {
      final progressPaint = Paint()
        ..color = progressColor 
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round;

      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        -pi / 2, 
        progress! * 2 * pi, 
        false, 
        progressPaint,
      );
    }
  }

  @override
  bool shouldRepaint(_RingPainter oldDelegate) => 
      oldDelegate.progress != progress || 
      oldDelegate.unlockedColor != unlockedColor ||
      oldDelegate.trackColor != trackColor ||
      oldDelegate.progressColor != progressColor;
}

class _WedgeClipper extends CustomClipper<Path> {
  final double progress;
  _WedgeClipper(this.progress);

  @override
  Path getClip(Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width; 
    
    Path path = Path()
      ..moveTo(center.dx, center.dy)
      ..lineTo(center.dx, 0)
      ..arcTo(
        Rect.fromCircle(center: center, radius: radius),
        -pi / 2,          
        progress * 2 * pi,
        false,
      )
      ..lineTo(center.dx, center.dy)
      ..close();
      
    return path;
  }

  @override
  bool shouldReclip(_WedgeClipper oldClipper) => oldClipper.progress != progress;
}