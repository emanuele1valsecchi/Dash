import 'dart:ui' as ui;
import 'package:flutter/material.dart';

class ResponsiveSpacing extends ThemeExtension<ResponsiveSpacing> {
  final double xs;
  final double sm; 
  final double md; 
  final double lg; 
  final double xl;

  const ResponsiveSpacing({
    this.xs = 4.0,
    this.sm = 8.0, 
    this.md = 16.0, 
    this.lg = 24.0,
    this.xl = 32.0,
  });

  @override
  ThemeExtension<ResponsiveSpacing> copyWith({
    double? xs, double? sm, double? md, double? lg, double? xl, double? xxl,
  }) {
    return ResponsiveSpacing(
      xs: xs ?? this.xs,
      sm: sm ?? this.sm,
      md: md ?? this.md,
      lg: lg ?? this.lg,
      xl: xl ?? this.xl,
    );
  }

  @override
  ThemeExtension<ResponsiveSpacing> lerp(ThemeExtension<ResponsiveSpacing>? other, double t) {
    if (other is! ResponsiveSpacing) return this;
    return ResponsiveSpacing(
      xs: ui.lerpDouble(xs, other.xs, t)!,
      sm: ui.lerpDouble(sm, other.sm, t)!,
      md: ui.lerpDouble(md, other.md, t)!,
      lg: ui.lerpDouble(lg, other.lg, t)!,
      xl: ui.lerpDouble(xl, other.xl, t)!,
    );
  }
}

extension SpacingContext on BuildContext {
  ResponsiveSpacing get responsiveSpacing => Theme.of(this).extension<ResponsiveSpacing>()!;

  EdgeInsets get paddingXs => EdgeInsets.all(responsiveSpacing.xs);
  EdgeInsets get paddingSm => EdgeInsets.all(responsiveSpacing.sm);
  EdgeInsets get paddingMd => EdgeInsets.all(responsiveSpacing.md);
  EdgeInsets get paddingLg => EdgeInsets.all(responsiveSpacing.lg);
  EdgeInsets get paddingXl => EdgeInsets.all(responsiveSpacing.xl);
}