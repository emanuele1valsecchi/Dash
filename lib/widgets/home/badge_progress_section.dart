import 'package:dash/widgets/badge/dash_badge.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import '../../models/home_badge_ui_model.dart';

class BadgeProgressSection extends StatelessWidget {
  final List<HomeBadgeUiModel> badges;

  const BadgeProgressSection({
    super.key,
    required this.badges,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              Symbols.workspace_premium_rounded,
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
        SizedBox(
          height: 185,
          child: ShaderMask(
            shaderCallback: (Rect bounds) {
              return const LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [
                  Colors.transparent, // 1. Sfuma in entrata a sinistra
                  Colors.white,       // 2. Diventa solido
                  Colors.white,       // 3. Resta solido
                  Colors.transparent, // 4. Sfuma in uscita a destra
                ],
                // I valori indicano le percentuali (0.0 = 0%, 1.0 = 100%)
                // Qui la sfumatura dura solo per il 5% a sinistra e il 5% a destra
                stops: [0.0, 0.03, 0.97, 1.0], 
              ).createShader(bounds);
            },
            blendMode: BlendMode.dstIn,
            child: ListView.separated(
              physics: const ClampingScrollPhysics(),
              scrollDirection: Axis.horizontal,
              itemCount: badges.length,
              separatorBuilder: (_, _) => const SizedBox(width: 20),
              itemBuilder: (context, index) {
                final badge = badges[index];
                return DashBadge(
                  badge: badge,
                  progress: badge.progress,
                  clickable: true,
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}