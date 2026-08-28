import 'package:flutter/material.dart';

class DashActionButton extends StatelessWidget{
  final String? label;
  final IconData? icon;

  final Function()? onPressed;

  const DashActionButton({
    super.key, 
    this.label, 
    this.icon, 
    required this.onPressed
  }): assert(
    label != null || icon != null,
    'DashActionButton must be provided with a label, an icon, or both.',
  );

  @override
  Widget build(BuildContext context) {
    ThemeData contextTheme = Theme.of(context);
    TextStyle textStyle = contextTheme.textTheme.bodyMedium!;

    final ButtonStyle style = ElevatedButton.styleFrom(
      foregroundColor: contextTheme.colorScheme.secondary,
      backgroundColor: contextTheme.colorScheme.primaryContainer,
      textStyle: textStyle
    );

    Icon? buttonIcon;

    if ( icon != null ){
      buttonIcon = Icon(
        icon,
        size: textStyle.fontSize,
        weight: 700,
      );

      if ( label == null ){
        return IconButton(
          onPressed: onPressed, 
          icon: buttonIcon,
          style: style.copyWith(
            padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(EdgeInsets.all(1)),
            shape: const WidgetStatePropertyAll<OutlinedBorder>(CircleBorder())
          ),
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