import 'package:flutter/material.dart';

class DashFloatingActionButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final Widget child;
  final double elevation;

  const DashFloatingActionButton({
    super.key,
    required this.onPressed,
    required this.child,
    this.elevation = 2.0,
  });

  @override
  Widget build(BuildContext context) {
    final ColorScheme colorScheme = Theme.of(context).colorScheme;

    return FloatingActionButton(
      heroTag: null,
      onPressed: onPressed,
      backgroundColor: colorScheme.primaryContainer,
      elevation: elevation,
      shape: const CircleBorder(),
      child: IconTheme(
        data: IconThemeData(
          color: colorScheme.onPrimaryContainer,
          size: Theme.of(context).textTheme.displaySmall?.fontSize,
          weight: 700
        ),
        child: child,
      ),
    );
  }
}