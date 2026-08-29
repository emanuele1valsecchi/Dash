import 'package:dash/extensions/responsive_spacing.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

class DashSectionContainer extends StatelessWidget{
  final VoidCallback? onTap;

  final IconData? leadingIcon;
  final bool leadingIconFilled;
  final String title;
  final bool hasForwardIcon;

  final bool _applyFadingEdge;

  final Widget child;

  const DashSectionContainer({
    super.key, 
    this.onTap,
    this.leadingIcon,
    this.leadingIconFilled = false,
    required this.title,
    this.hasForwardIcon = true,
    required this.child, 
  }): _applyFadingEdge = false;

  const DashSectionContainer.withFadeEdge({
    super.key, 
    this.onTap,
    this.leadingIcon,
    this.leadingIconFilled = false,
    required this.title,
    this.hasForwardIcon = true,
    required this.child, 
  }): _applyFadingEdge = true;

  @override
  Widget build(BuildContext context) {
    final TextStyle textStyle = Theme.of(context).textTheme.titleMedium!;
    final Color headerColor = Theme.of(context).colorScheme.secondary;

    Widget finalChild = child;

    if( _applyFadingEdge ){
      finalChild = ShaderMask(
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
            stops: [0.0, 0.03, 0.97, 1.0], 
          ).createShader(bounds);
        },
        blendMode: BlendMode.dstIn,
        child: SingleChildScrollView(
          physics: const ClampingScrollPhysics(),
          scrollDirection: Axis.horizontal,
          child: child
        )
      );
    }

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
            finalChild
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
      fill: (leadingIconFilled) ? 1.0 : 0.0,
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