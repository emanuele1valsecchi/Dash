import 'dart:ui' as ui;
import 'package:flutter/material.dart';

class ResponsiveBorderRadius extends ThemeExtension<ResponsiveBorderRadius> {
  final double xs; // for checkboxes, small chips
  final double sm; // for text fields, buttons
  final double md; // for small cards
  final double lg; // for standard cards, dialogs
  final double xl; // for large bottom sheets, massive containers

  const ResponsiveBorderRadius({
    this.xs = 4.0,
    this.sm = 8.0,
    this.md = 12.0,
    this.lg = 16.0,
    this.xl = 28.0,
  });

  @override
  ThemeExtension<ResponsiveBorderRadius> copyWith({
    double? xs, double? sm, double? md, double? lg, double? xl,
  }) {
    return ResponsiveBorderRadius(
      xs: xs ?? this.xs,
      sm: sm ?? this.sm,
      md: md ?? this.md,
      lg: lg ?? this.lg,
      xl: xl ?? this.xl,
    );
  }

  @override
  ThemeExtension<ResponsiveBorderRadius> lerp(ThemeExtension<ResponsiveBorderRadius>? other, double t) {
    if (other is! ResponsiveBorderRadius) return this;
    return ResponsiveBorderRadius(
      xs: ui.lerpDouble(xs, other.xs, t)!,
      sm: ui.lerpDouble(sm, other.sm, t)!,
      md: ui.lerpDouble(md, other.md, t)!,
      lg: ui.lerpDouble(lg, other.lg, t)!,
      xl: ui.lerpDouble(xl, other.xl, t)!,
    );
  }
}

extension RadiusContext on BuildContext {
  ResponsiveBorderRadius get responsiveBorderRadius => Theme.of(this).extension<ResponsiveBorderRadius>()!;

  BorderRadius get radiusXs => BorderRadius.circular(responsiveBorderRadius.xs);
  BorderRadius get radiusSm => BorderRadius.circular(responsiveBorderRadius.sm);
  BorderRadius get radiusMd => BorderRadius.circular(responsiveBorderRadius.md);
  BorderRadius get radiusLg => BorderRadius.circular(responsiveBorderRadius.lg);
  BorderRadius get radiusXl => BorderRadius.circular(responsiveBorderRadius.xl);
}