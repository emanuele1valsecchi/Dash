import 'package:flutter/widgets.dart';

import '../services/unit_preferences.dart';
import '../utils/unit_formatter.dart';

/// Publishes the app's [UnitPreferences] to the whole widget tree and rebuilds
/// every screen that reads it the moment a unit changes.
///
/// **Why an `InheritedNotifier` and not just a `ListenableBuilder` around
/// `MaterialApp`:** rebuilding `MaterialApp` does *not* rebuild the routes
/// already pushed on top of it — `_ModalScopeState` caches each route's page
/// widget and only rebuilds it when the route itself says so. So a user
/// flipping km→mi on the settings page would return to a stale home screen.
/// An inherited widget has no such problem: `dependOnInheritedWidgetOfExactType`
/// registers the *dependent element*, wherever it sits, and marks it dirty
/// directly — straight through the route boundary.
///
/// Mounted once, above `MaterialApp`, in `main.dart`.
class UnitsScope extends InheritedNotifier<UnitPreferences> {
  const UnitsScope({
    super.key,
    required UnitPreferences preferences,
    required super.child,
  }) : super(notifier: preferences);

  /// The formatter for the current preferences, **registering the caller as a
  /// dependent** so it rebuilds when the user changes a unit.
  ///
  /// Call this from `build` (directly, or from a getter/helper that `build`
  /// invokes). Outside build — in a button callback, or while assembling a
  /// dialog's arguments — use [Units.current] instead, which reads the same
  /// values without subscribing.
  ///
  /// Falls back to [UnitFormatter.metric] when no scope is above the caller,
  /// so a widget test can pump a bare screen without wiring up the app root.
  static UnitFormatter of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<UnitsScope>();
    final prefs = scope?.notifier;
    return prefs == null ? UnitFormatter.metric : UnitFormatter.from(prefs);
  }
}

/// Short entry point for the unit formatter.
abstract final class Units {
  /// Reactive: use inside `build`. See [UnitsScope.of].
  static UnitFormatter of(BuildContext context) => UnitsScope.of(context);

  /// A non-reactive snapshot of the current preferences, for code that has no
  /// `BuildContext` or runs outside a build (callbacks, `initState`, service
  /// code). Nothing rebuilds when the preferences change, which is exactly
  /// right for a string that is computed once and handed to a dialog.
  static UnitFormatter get current =>
      UnitFormatter.from(UnitPreferences.instance);
}
