import 'package:dash/extensions/responsive_border_radius.dart';
import 'package:dash/extensions/responsive_spacing.dart';
import 'package:dash/models/home_badge_ui_model.dart';
import 'package:dash/widgets/badge/dash_badge.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

class BadgeOverlayContainer extends StatelessWidget{
  final HomeBadgeUiModel badge;
  final double? progress;

  const BadgeOverlayContainer({
    super.key, 
    required this.badge,
    required this.progress,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: context.paddingSm,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        spacing: ResponsiveSpacing().md,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              if ( progress != null && progress == 1.0 )
                IconButton(
                  icon: const Icon(Symbols.share_rounded),
                  onPressed: () {
                    // TODO: Implement share
                  },
                )
              else
                SizedBox(
                  height: Theme.of(context).iconTheme.size,
                  width: Theme.of(context).iconTheme.size,
                ),

              IconButton(
                icon: const Icon(
                  Symbols.close_rounded,
                ),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),

          DashBadge(
            badge: badge,
            progress: badge.progress,
            dimFactor: 0.44,
            clickable: false,
          ),

          _BadgeStatusIndicator(
            progress: progress,
          ),

          Text(
            badge.description,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),

          SizedBox(
            height: Theme.of(context).iconTheme.size,
            width: Theme.of(context).iconTheme.size,
          )
        ],
      ),
    );
  }
}

class _BadgeStatusIndicator extends StatelessWidget {
  final double? progress;

  const _BadgeStatusIndicator({
    required this.progress,
  });

  @override
  Widget build(BuildContext context) {
    if ( progress == 1.0 ) {
      return Container(
        padding: EdgeInsets.symmetric(
          horizontal: ResponsiveSpacing().md, 
          vertical: ResponsiveSpacing().sm
        ),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHigh,
          borderRadius: context.radiusXl,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Symbols.flag_rounded,
              color: Theme.of(context).colorScheme.outline
            ),
            
            Text(
              "You have completed this badge",
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: Theme.of(context).colorScheme.outline,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      );
    } else if (progress != null && progress! > 0.0) {
      final percentage = (progress! * 100).toInt();

      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(8.0),
        ),
        child: Text(
          "$percentage% Completed",
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: Theme.of(context).colorScheme.outline,
                fontWeight: FontWeight.bold,
              ),
        ),
      );
    } else {
      return FilledButton.icon(
        onPressed: () {
          // TODO: Navigate to challenge screen
          Navigator.of(context).pop();
        },
        style: FilledButton.styleFrom(
          backgroundColor: Colors.green.shade100,
          foregroundColor: Colors.green.shade800,
          padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 12.0),
        ),
        icon: const Icon(Symbols.play_arrow, size: 20),
        label: const Text("Complete it now",
            style: TextStyle(fontWeight: FontWeight.bold)),
      );
    }
  }
}