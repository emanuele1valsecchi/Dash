import 'package:dash/extensions/responsive_spacing.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

class DashSectionContainer extends StatelessWidget{
  final VoidCallback? onTap;

  final IconData? leadingIcon;
  final String title;
  final bool hasForwardIcon;

  final Widget child;

  const DashSectionContainer({
    super.key, 
    this.onTap,
    this.leadingIcon,
    required this.title,
    this.hasForwardIcon = true,
    required this.child, 
  });

  @override
  Widget build(BuildContext context) {
    final TextStyle textStyle = Theme.of(context).textTheme.titleMedium!;
    final Color headerColor = Theme.of(context).colorScheme.secondary;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        width: MediaQuery.widthOf(context),
        padding: EdgeInsets.symmetric(vertical: ResponsiveSpacing().md),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: ResponsiveSpacing().md,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.start,
              crossAxisAlignment: CrossAxisAlignment.center,
              spacing: ResponsiveSpacing().sm,
              children: [
                ?_buildLeadingIcon(textStyle, headerColor),
                Text(
                  title,
                  style: textStyle.copyWith(
                    fontWeight: FontWeight.bold,
                    color: headerColor
                  ),
                ),
                Spacer(),
                if (hasForwardIcon) _buildForwardIcon(headerColor, textStyle)
              ],
            ),
            child
          ],
        )
      ),
    );
  }

  Widget? _buildLeadingIcon(TextStyle textStyle, Color headerColor){
    if( leadingIcon == null ) return null;

    return Icon(
      leadingIcon,
      size: textStyle.fontSize,
      color: headerColor,
    );
  }

  Widget _buildForwardIcon(Color iconColor, TextStyle textStyle){
    return Icon(
      Symbols.arrow_forward_ios_rounded,
      color: iconColor,
      size: textStyle.fontSize,
    );
  }
}