import 'package:flutter/material.dart';

extension ResponsiveMargins on BuildContext {
  /// Material 3 standard breakpoints
  double get m3PageMargin {
    final width = MediaQuery.sizeOf(this).width;
    if (width < 600) return 16.0; // Compact (Mobile)
    if (width < 840) return 24.0; // Medium (Tablet)
    return 24.0;                  // Expanded (Desktop/Web)
  }

  /// Use this for the outer padding of all your Scaffold bodies
  EdgeInsets get pagePadding => EdgeInsets.all(m3PageMargin);
  EdgeInsets get pagePaddingHorizontal => EdgeInsets.symmetric(horizontal: m3PageMargin);
}