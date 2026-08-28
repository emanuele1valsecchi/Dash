import 'package:dash/decorations/card_decorations.dart';
import 'package:dash/extensions/responsive_spacing.dart';
import 'package:flutter/material.dart';

class DashGestureCardContainer extends StatelessWidget{
  final VoidCallback? onTap;

  final Widget? leading;
  final String? title;
  final List<Widget>? actions;

  final Widget child;
  
  const DashGestureCardContainer({
    super.key, 
    this.onTap, 
    this.leading, 
    this.title, 
    this.actions,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final hasTopBar = leading != null || title != null || actions != null;

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: MediaQuery.widthOf(context),
        padding: EdgeInsets.all(ResponsiveSpacing().md),
        decoration: getDashCardDecoration(context),
        child: hasTopBar
          ? _buildWithInternalTopBar(context, child)
          : child
      ),
    );
  }

  Widget _buildWithInternalTopBar(BuildContext context, Widget child){
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: ResponsiveSpacing().sm,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.start,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            ?leading,
            if ( title != null )
              Text(
                title!,
                style: Theme.of(context).textTheme.bodySmall!.copyWith(
                  color: Theme.of(context).colorScheme.outline,
                  fontWeight: FontWeight.bold
                ),
              ),
            Spacer(),
            ...?actions,
          ],
        ),

        child
      ],
    );
  }
}