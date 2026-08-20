import 'package:flutter/material.dart';
import 'package:wear_plus/wear_plus.dart';

/// Colours and layout constants for the watch app.
///
/// The palette is deliberately **not** the phone app's. Dash on the phone is
/// light green-on-cream, which on a watch would be both hard to read outdoors
/// at a glance and expensive: these are OLED panels, where a black pixel is an
/// unlit pixel, so a light background costs real battery on a screen that has
/// to stay on for the length of a run.
class WatchTheme {
  /// Unlit on OLED. Not near-black — actual black.
  static const Color background = Color(0xFF000000);

  /// Dash's accent, lightened for legibility on black.
  static const Color accent = Color(0xFF8FE9A8);

  static const Color primaryText = Color(0xFFFFFFFF);
  static const Color secondaryText = Color(0xFF9AA294);

  /// Off-route / attention. Amber rather than red: red on black at a glance
  /// reads as "something broke", not "you took a wrong turn".
  static const Color warning = Color(0xFFF4C97A);

  /// Ends a run. The only destructive control on the watch.
  static const Color danger = Color(0xFFE88B7D);

  /// In ambient mode the whole UI drops to this: no fills, thin strokes, one
  /// colour. Burn-in protection means large solid bright areas must be avoided
  /// entirely, and low-bit ambient panels cannot render subtle shades anyway.
  static const Color ambientText = Color(0xFFBFC4BC);

  static ThemeData get theme => ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: background,
        useMaterial3: true,
        colorScheme: const ColorScheme.dark(
          surface: background,
          primary: accent,
        ),
      );
}

/// Insets content away from the edge of the display.
///
/// On a round watch the corners of the layout box are simply not on the glass,
/// so anything drawn there is invisible — the usable region is the inscribed
/// circle. This pads by a fraction of the shortest side rather than a fixed
/// number of pixels, because Wear screens run from roughly 384 to 450 px and a
/// fixed inset that looks right on one is wrong on the others.
///
/// Square Wear devices exist (some Fossil and TicWatch models) and need much
/// less, hence reading the real shape rather than assuming round.
class RoundSafe extends StatelessWidget {
  final Widget child;

  /// Extra inset on top of the shape default, as a fraction of the shortest
  /// side. Useful for pages whose content reaches unusually wide.
  final double extra;

  const RoundSafe({super.key, required this.child, this.extra = 0});

  @override
  Widget build(BuildContext context) {
    return WatchShape(
      builder: (context, shape, _) {
        final side = MediaQuery.sizeOf(context).shortestSide;
        final fraction = (shape == WearShape.round ? 0.105 : 0.045) + extra;
        // SizedBox.expand is load-bearing, not decoration: without it the
        // width constraint reaching the child stays loose, so a Column
        // shrink-wraps to its widest child and lands against the left edge
        // while still looking correctly centred vertically. Forcing tight
        // constraints makes CrossAxisAlignment.center mean what it says.
        return SizedBox.expand(
          child: Padding(
            padding: EdgeInsets.all(side * fraction),
            child: child,
          ),
        );
      },
    );
  }
}
