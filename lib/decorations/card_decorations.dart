import 'package:dash/extensions/responsive_border_radius.dart';
import 'package:flutter/material.dart';

BoxDecoration getDashCardDecoration(BuildContext context){
  return BoxDecoration(
    borderRadius: getDashCardDecorationBorderRadius(context),
    color: Theme.of(context).colorScheme.surfaceContainer,
    border: Border.all(
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      width: 1.8
    )
  );
}

BorderRadiusGeometry getDashCardDecorationBorderRadius(BuildContext context){
  return context.radiusXl;
}