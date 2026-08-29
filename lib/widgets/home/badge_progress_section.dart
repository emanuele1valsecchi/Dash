import 'package:dash/widgets/badge/dash_badge.dart';
import 'package:dash/widgets/dash_section_container.dart';
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

    return DashSectionContainer.withFadeEdge(
      leadingIcon: Symbols.workspace_premium_rounded,
      title: "Badge Progress", 
      hasForwardIcon: false,
      child: SingleChildScrollView(
        physics: const ClampingScrollPhysics(),
        scrollDirection: Axis.horizontal,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: List.generate(badges.length, (i){
            return DashBadge(
              badge: badges[i],
              progress: badges[i].progress,
              clickable: true,
            );
          }),
        ),
      )
    );
  }
}