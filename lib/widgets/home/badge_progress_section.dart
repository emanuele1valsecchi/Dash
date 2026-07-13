import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../models/home_badge_ui_model.dart';

class BadgeProgressSection extends StatelessWidget {
  final List<HomeBadgeUiModel> badges;
  final ValueChanged<HomeBadgeUiModel>? onBadgeTap;

  const BadgeProgressSection({
    super.key,
    required this.badges,
    this.onBadgeTap,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Row(
          children: [
            Icon(
              Icons.workspace_premium_outlined,
              color: Color(0xFF4A554A),
              size: 24,
            ),
            SizedBox(width: 8),
            Text(
              'Badge Progress',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: Color(0xFF394137),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        SizedBox(
          height: 185,
          child: ListView.separated(
            physics: const ClampingScrollPhysics(),
            scrollDirection: Axis.horizontal,
            itemCount: badges.length,
            separatorBuilder: (_, _) => const SizedBox(width: 18),
            itemBuilder: (context, index) {
              final badge = badges[index];
              return _BadgeProgressItem(
                badge: badge,
                onTap: onBadgeTap,
              );
            },
          ),
        ),
      ],
    );
  }
}

class _BadgeProgressItem extends StatelessWidget {
  final HomeBadgeUiModel badge;
  final ValueChanged<HomeBadgeUiModel>? onTap;

  const _BadgeProgressItem({
    required this.badge,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final progress = badge.progress.clamp(0.0, 1.0);
    final isUnlocked = badge.unlocked || progress >= 1.0;
    final isActive = progress > 0.0;

    return GestureDetector(
      onTap: () => onTap?.call(badge),
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 128,
        child: Column(
          children: [
            SizedBox(
              width: 112,
              height: 112,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  CustomPaint(
                    size: const Size(112, 112),
                    painter: _BadgeRingPainter(
                      progress: progress,
                      trackColor: const Color(0xFFE0E4DA),
                      progressColor: const Color(0xFF4D6F79),
                      strokeWidth: 8,
                    ),
                  ),
                  Container(
                    width: 92,
                    height: 92,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: const Color(0xFFF2F4EE),
                      border: Border.all(
                        color: const Color(0xFFE2E5DD),
                        width: 3,
                      ),
                    ),
                    child: ClipOval(
                      child: ColorFiltered(
                        colorFilter: isUnlocked || isActive
                            ? const ColorFilter.mode(
                                Colors.transparent,
                                BlendMode.multiply,
                              )
                            : const ColorFilter.matrix(<double>[
                                0.2126, 0.7152, 0.0722, 0, 0,
                                0.2126, 0.7152, 0.0722, 0, 0,
                                0.2126, 0.7152, 0.0722, 0, 0,
                                0, 0, 0, 1, 0,
                              ]),
                        child: CachedNetworkImage(
                          imageUrl: badge.imageUrl,
                          fit: BoxFit.cover,
                          placeholder: (context, url) => Container(
                            color: const Color(0xFFE7EAE2),
                            alignment: Alignment.center,
                            child: const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Color(0xFF4D6F79),
                              ),
                            ),
                          ),
                          errorWidget: (context, url, error) => Container(
                            color: const Color(0xFFE7EAE2),
                            alignment: Alignment.center,
                            child: const Icon(
                              Icons.workspace_premium_outlined,
                              size: 34,
                              color: Color(0xFF7A8477),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            Text(
              badge.title,
              maxLines: 2,
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: isUnlocked || isActive
                    ? const Color(0xFF4D574A)
                    : const Color(0xFF7F877C),
                height: 1.15,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BadgeRingPainter extends CustomPainter {
  final double progress;
  final Color trackColor;
  final Color progressColor;
  final double strokeWidth;

  const _BadgeRingPainter({
    required this.progress,
    required this.trackColor,
    required this.progressColor,
    required this.strokeWidth,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final progressValue = progress.clamp(0.0, 1.0);
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.width - strokeWidth) / 2;

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

    final rect = Rect.fromCircle(center: center, radius: radius);

    const startAngle = -math.pi / 2;
    const fullSweep = math.pi * 2;

    canvas.drawArc(
      rect,
      startAngle,
      fullSweep,
      false,
      trackPaint,
    );

    if (progressValue > 0) {
      canvas.drawArc(
        rect,
        startAngle,
        fullSweep * progressValue,
        false,
        progressPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _BadgeRingPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.trackColor != trackColor ||
        oldDelegate.progressColor != progressColor ||
        oldDelegate.strokeWidth != strokeWidth;
  }
}