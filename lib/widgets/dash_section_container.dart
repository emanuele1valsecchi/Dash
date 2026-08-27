import 'package:dash/extensions/responsive_spacing.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

class DashSectionContainer extends StatelessWidget{
  final VoidCallback? onTap;

  final Icon? leading;
  final String title;
  final bool hasForwardIcon;

  final Widget child;

  const DashSectionContainer({
    super.key, 
    this.onTap,
    this.leading,
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
          spacing: ResponsiveSpacing().sm,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.start,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                ?leading,
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

  Widget _buildForwardIcon(Color iconColor, TextStyle textStyle){
    return Icon(
      Symbols.arrow_forward_ios_rounded,
      color: iconColor,
      size: textStyle.fontSize,
    );
  }
}