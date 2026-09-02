import 'package:dash/config/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Test harness shared by every widget test.
///
/// **Why this exists rather than each test writing its own `MaterialApp`:**
/// a number of Dash widgets resolve theme *extensions* with a non-null
/// assertion — `context.paddingMd` is
/// `Theme.of(this).extension<ResponsiveSpacing>()!` — so a widget pumped
/// under a bare `MaterialApp()` throws a null-check error before it renders
/// anything. Wrapping in [buildAppTheme] (the app's real theme, extracted
/// from `main.dart` for exactly this reason) makes that a non-issue and keeps
/// tests honest: they see the widget as the app actually draws it.
///
/// Widgets that read units via `Units.of(context)` degrade to
/// [UnitFormatter.metric] with no scope above them — see `UnitsScope.of` —
/// so nothing here needs to wire up `UnitPreferences`, which is a
/// private-constructor singleton and cannot be substituted in a test.
Future<void> pumpDashWidget(
  WidgetTester tester,
  Widget widget, {
  /// Rendered inside a [Scaffold] body by default. Pass false for a widget
  /// that supplies its own `Scaffold` (a whole screen), or that must be the
  /// route itself (a dialog under test).
  bool wrapInScaffold = true,

  /// Some cards size themselves from their parent and overflow the default
  /// 800x600 test surface. Give those a realistic phone viewport instead.
  Size? surfaceSize,

  /// Observer for tests that assert on navigation.
  NavigatorObserver? navigatorObserver,
}) async {
  if (surfaceSize != null) {
    // Set the *view*, not `binding.setSurfaceSize`: the latter resizes the
    // render surface but leaves `MediaQuery` reporting the default 800x600,
    // so a widget that sizes itself from `MediaQuery.sizeOf` would compute
    // against 800 and then get clipped to the real surface — the assertion
    // passes or fails for reasons that have nothing to do with the widget.
    // A device pixel ratio of 1.0 keeps logical and physical pixels equal so
    // the numbers in a test read as the widths they actually are.
    tester.view.physicalSize = surfaceSize;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(),
      navigatorObservers: [?navigatorObserver],
      home: wrapInScaffold ? Scaffold(body: widget) : widget,
    ),
  );
}

/// A typical phone viewport, for cards that measure themselves against the
/// screen (`DashMapCard` and friends size to a fraction of screen width).
const Size kPhoneSurface = Size(390, 844);
