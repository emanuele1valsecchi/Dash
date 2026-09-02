import 'package:flutter/material.dart';

import '../extensions/responsive_border_radius.dart';
import '../extensions/responsive_spacing.dart';

/// The app's one and only [ThemeData].
///
/// Lives here rather than as a private method on `main.dart`'s state class
/// **so tests can render against the real theme instead of a hand-rolled
/// copy of it**. That is not a stylistic preference: several widgets reach
/// for theme *extensions* with a non-null assertion — `context.paddingMd`
/// resolves `Theme.of(this).extension<ResponsiveSpacing>()!` — so a widget
/// pumped under a bare `ThemeData()` throws rather than rendering. A second
/// copy of the theme in a test helper would work until someone added an
/// extension here and not there, at which point the tests would fail for a
/// reason that has nothing to do with what they are testing.
ThemeData buildAppTheme() {
  const ResponsiveSpacing responsiveSpacing = ResponsiveSpacing();
  const ResponsiveBorderRadius responsiveBorderRadius = ResponsiveBorderRadius();

  final ColorScheme materialColorScheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF37693D),
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: materialColorScheme,
    extensions: const [
      responsiveSpacing,
      responsiveBorderRadius,
    ],
    cardTheme: CardThemeData(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(responsiveBorderRadius.md),
      ),
    ),
    dialogTheme: DialogThemeData(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(responsiveBorderRadius.lg),
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(responsiveBorderRadius.xl),
        ),
      ),
    ),
    iconTheme: const IconThemeData(
      weight: 600,
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: materialColorScheme.tertiary,
      circularTrackColor: materialColorScheme.surfaceContainer,
    ),
  );
}
