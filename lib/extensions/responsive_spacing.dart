import 'dart:ui' as ui;
import 'package:flutter/material.dart';

class ResponsiveSpacing extends ThemeExtension<ResponsiveSpacing> {
  final double sm; 
  final double md; 
  final double lg; 

  const ResponsiveSpacing({this.sm = 8.0, this.md = 16.0, this.lg = 24.0});

  @override
  ThemeExtension<ResponsiveSpacing> copyWith({double? sm, double? md, double? lg}) {
    return ResponsiveSpacing(
      sm: sm ?? this.sm,
      md: md ?? this.md,
      lg: lg ?? this.lg,
    );
  }

  @override
  ThemeExtension<ResponsiveSpacing> lerp(ThemeExtension<ResponsiveSpacing>? other, double t) {
    if (other is! ResponsiveSpacing) return this;
    return ResponsiveSpacing(
      sm: ui.lerpDouble(sm, other.sm, t)!,
      md: ui.lerpDouble(md, other.md, t)!,
      lg: ui.lerpDouble(lg, other.lg, t)!,
    );
  }
}