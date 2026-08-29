import 'package:dash/extensions/responsive_spacing.dart';
import 'package:dash/models/home_badge_ui_model.dart';
import 'package:dash/screens/badge_page.dart';
import 'package:dash/widgets/badge/dash_badge.dart';
import 'package:dash/widgets/dash_gesture_card_container.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

class ProfileBadgeSection extends StatelessWidget {
  final List<HomeBadgeUiModel> badges;
  final String userId;

  const ProfileBadgeSection({
    super.key,
    required this.badges,
    required this.userId,
  });

  @override
  Widget build(BuildContext context) {
    if ( badges.isEmpty ){
      return Center(
        child: Padding(
          padding: context.paddingSm,
          child: CircularProgressIndicator(),
        ),
      );
    }

    final displayBadges = badges;

    return DashGestureCardContainer(
      title: "Badges",
      onTap: () => _showBadgePage(context),
      actions: [
        Icon(
          Symbols.arrow_forward_ios_rounded,
          color: Theme.of(context).colorScheme.outline,
          size: Theme.of(context).textTheme.bodySmall!.fontSize,
        )
      ],
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.max,
        children: displayBadges.map((badge) {
          return DashBadge(
            badge: badge, 
            progress: badge.progress,
            dimFactor: 0.16,
            clickable: false,
          );
        }).toList()
      )
    );
  }

  void _showBadgePage(BuildContext context){
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (context) => BadgePage(
          userId: userId,
        )
      ),
    );
  }
}