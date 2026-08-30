import 'package:dash/decorations/card_decorations.dart';
import 'package:dash/extensions/responsive_spacing.dart';
import 'package:flutter/material.dart';

/// One labelled measurement in the same card treatment as the rest of a
/// detail screen — a small icon-and-label caption over a bold value.
///
/// Shared by the route and run detail pages so a distance reads the same on
/// both.
class DashStatTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const DashStatTile({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final labelStyle = theme.textTheme.bodySmall!.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    return Container(
      padding: context.paddingMd,
      decoration: getDashCardDecoration(context),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: ResponsiveSpacing().sm / 2,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            spacing: ResponsiveSpacing().sm / 2,
            children: [
              Icon(
                icon,
                size: labelStyle.fontSize,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              Flexible(
                child: Text(
                  label,
                  style: labelStyle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          Text(
            value,
            style: theme.textTheme.titleMedium!.copyWith(
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.secondary,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}
