import 'package:flutter/material.dart';

class DashActionButton extends StatelessWidget{
  final String? label;
  final double? labelSize;

  final IconData? icon;
  final double? iconSize;
  final double? iconFill;

  final Function()? onPressed;



  const DashActionButton({
    super.key, 
    this.label,
    this.labelSize, 
    this.icon, 
    this.iconSize,
    this.iconFill = 0.0,
    required this.onPressed
  }): assert(
    label != null || icon != null,
    'DashActionButton must be provided with a label, an icon, or both.',
  );

  @override
  Widget build(BuildContext context) {
    ThemeData contextTheme = Theme.of(context);

    TextStyle textStyle = contextTheme.textTheme.bodyMedium!.copyWith(
      fontSize: labelSize
    );

    final ButtonStyle style = ElevatedButton.styleFrom(
      foregroundColor: contextTheme.colorScheme.secondary,
      backgroundColor: contextTheme.colorScheme.primaryContainer,
      textStyle: textStyle
    );

    Icon? buttonIcon;

    if ( icon != null ){
      buttonIcon = Icon(
        icon,
        size: iconSize ?? textStyle.fontSize,
        fill: iconFill ?? 0.0,
        weight: 700,
      );

      if ( label == null ){
        return IconButton(
          onPressed: onPressed, 
          icon: buttonIcon,
          style: style
        );
      }
    }

    return ElevatedButton.icon(
      style: style,
      icon: buttonIcon,
      label: Text(
        label!
      ),
      onPressed: onPressed,
    );
  }
}