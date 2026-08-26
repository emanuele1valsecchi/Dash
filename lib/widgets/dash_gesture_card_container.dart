import 'package:dash/extensions/responsive_border_radius.dart';
import 'package:dash/extensions/responsive_spacing.dart';
import 'package:flutter/material.dart';

class DashGestureCardContainer extends StatelessWidget{
  final VoidCallback? onTap;
  final Widget child;
  
  const DashGestureCardContainer({super.key, this.onTap, required this.child});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: EdgeInsets.all(ResponsiveSpacing().md),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainer,
          borderRadius: context.radiusXl,
          border: Border.all(
            color: Theme.of(context).colorScheme.surfaceContainerHigh,
            width: 1.5
          )
        ),
        child: child
      ),
    );
  }
}