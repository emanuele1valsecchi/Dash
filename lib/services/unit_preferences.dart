import 'dart:async' show unawaited;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Which distance unit every length in the app is rendered in.
///
/// The *sub*-unit (metres vs feet for short distances) is not a separate
/// choice — it follows this one, since nobody wants kilometres paired with
/// feet.
enum DistanceUnit { kilometers, miles }

/// Area rendering. Metric walks m² → ha → km²; imperial walks ft² → acres →
/// mi². Kept separate from [DistanceUnit] only because a preset switches
/// both together anyway, so supporting the odd mixed choice costs nothing.
enum AreaUnit { metric, imperial }

/// Whether a rate reads as *pace* (time per distance, what runners think in)
/// or *speed* (distance per time). Not a metric/imperial choice — the
/// distance half of either follows [DistanceUnit].
enum RateDisplay { pace, speed }

enum ElevationUnit { meters, feet }

/// kJ is the legally-mandated food-energy unit in Australia/New Zealand and
/// is shown alongside kcal across the EU, so it is a real preference rather
/// than a curiosity.
enum EnergyUnit { kcal, kilojoules }

enum ClockFormat { h24, h12 }

enum WeekStart { monday, sunday }

/// The presets offered at the top of the units settings page. [custom] is
/// never chosen directly — it is what the preset reads as once the
/// individual rows no longer all agree with one system.
enum UnitSystem { metric, imperial, custom }

/// App-wide unit preferences, owned by a single app-lifetime instance
/// (`UnitPreferences.instance`) the same way `LocationService.instance` and
/// `WaterFountainService.instance` are.
///
/// **`SharedPreferences` is the source of truth**, not Firestore: every
/// measurement the app renders goes through this, so a read has to be
/// synchronous and has to keep working offline mid-run. Firestore is a
/// one-way mirror written in the background purely so the choice follows the
/// user to a new device — see [_mirrorToCloud]/[syncFromCloud] for how the
/// two are reconciled (local always wins once the user has actually touched
/// a setting here).
///
/// It is a [ChangeNotifier] so `UnitsScope` (an `InheritedNotifier` above
/// `MaterialApp`) can rebuild every dependent screen the instant a setting
/// flips — including screens sitting *underneath* the settings page in the
/// navigation stack, which a plain `setState` could never reach.
class UnitPreferences extends ChangeNotifier {
  UnitPreferences._();

  static final UnitPreferences instance = UnitPreferences._();

  // ── Storage keys ────────────────────────────────────────────────────────
  //
  // Versioned (`_v1`) so a future change to what a value means can be
  // migrated rather than silently misread — same convention as
  // `water_fountain_cache_v1`.
  static const String _kDistance = 'units_distance_v1';
  static const String _kArea = 'units_area_v1';
  static const String _kRate = 'units_rate_v1';
  static const String _kElevation = 'units_elevation_v1';
  static const String _kEnergy = 'units_energy_v1';
  static const String _kClock = 'units_clock_v1';
  static const String _kWeekStart = 'units_week_start_v1';

  /// Set the first time the user changes anything here. Distinguishes
  /// "these are the locale-guessed defaults" from "the user chose this" —
  /// only the former may be overwritten by [syncFromCloud].
  static const String _kConfigured = 'units_configured_v1';

  /// The Firestore field on `profiles/{uid}` this mirrors into. A map, so it
  /// merges cleanly alongside `pushPreferences` without either clobbering
  /// the other.
  static const String _cloudField = 'unitPreferences';

  DistanceUnit _distance = DistanceUnit.kilometers;
  AreaUnit _area = AreaUnit.metric;
  RateDisplay _rate = RateDisplay.pace;
  ElevationUnit _elevation = ElevationUnit.meters;
  EnergyUnit _energy = EnergyUnit.kcal;
  ClockFormat _clock = ClockFormat.h24;
  WeekStart _weekStart = WeekStart.monday;

  bool _configured = false;
  bool _warmedUp = false;

  DistanceUnit get distance => _distance;
  AreaUnit get area => _area;
  RateDisplay get rate => _rate;
  ElevationUnit get elevation => _elevation;
  EnergyUnit get energy => _energy;
  ClockFormat get clock => _clock;
  WeekStart get weekStart => _weekStart;

  /// True once the user has explicitly changed at least one setting. Decides
  /// whether the cloud copy may overwrite what is here.
  bool get isConfigured => _configured;

  /// Which preset row the settings page shows as selected. Reads
  /// [UnitSystem.custom] whenever the measurement rows do not all agree.
  /// Clock format and week start are deliberately excluded — neither is a
  /// property of the metric or imperial system.
  UnitSystem get system {
    final metric =
        _distance == DistanceUnit.kilometers &&
        _area == AreaUnit.metric &&
        _elevation == ElevationUnit.meters;
    if (metric) return UnitSystem.metric;

    final imperial =
        _distance == DistanceUnit.miles &&
        _area == AreaUnit.imperial &&
        _elevation == ElevationUnit.feet;
    if (imperial) return UnitSystem.imperial;

    return UnitSystem.custom;
  }

  // ── Startup ─────────────────────────────────────────────────────────────

  /// Loads the stored preferences from disk. Called once before `runApp`, so
  /// the very first frame already renders in the right units rather than
  /// flashing metric and correcting itself.
  ///
  /// On a device that has never stored anything, the field initialisers'
  /// **metric** defaults stand. This is deliberately *not* guessed from the
  /// device locale: an earlier version did that (US/GB/etc. → miles) and it
  /// meant a first launch could land on imperial for someone who never asked
  /// for it, which is far more jarring than metric is for a miles user who
  /// can flip one switch. Nothing is marked configured either way, so a later
  /// [syncFromCloud] may still replace these.
  Future<void> warmUp() async {
    if (_warmedUp) return;
    _warmedUp = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      _configured = prefs.getBool(_kConfigured) ?? false;

      if (prefs.containsKey(_kDistance)) {
        _distance = _read(prefs, _kDistance, DistanceUnit.values, _distance);
        _area = _read(prefs, _kArea, AreaUnit.values, _area);
        _rate = _read(prefs, _kRate, RateDisplay.values, _rate);
        _elevation = _read(
          prefs,
          _kElevation,
          ElevationUnit.values,
          _elevation,
        );
        _energy = _read(prefs, _kEnergy, EnergyUnit.values, _energy);
        _clock = _read(prefs, _kClock, ClockFormat.values, _clock);
        _weekStart = _read(prefs, _kWeekStart, WeekStart.values, _weekStart);
      }
      notifyListeners();
    } catch (e) {
      // A failed disk read must never stop the app launching — the metric
      // defaults are a perfectly usable fallback.
      debugPrint('UnitPreferences.warmUp failed: $e');
    }
  }

  /// Enum values are stored by `name`, never `index`, so reordering an enum
  /// cannot silently reinterpret everyone's saved choice.
  T _read<T extends Enum>(
    SharedPreferences prefs,
    String key,
    List<T> values,
    T fallback,
  ) {
    final raw = prefs.getString(key);
    if (raw == null) return fallback;
    for (final v in values) {
      if (v.name == raw) return v;
    }
    return fallback;
  }

  // ── Mutation ────────────────────────────────────────────────────────────

  Future<void> setDistance(DistanceUnit v) =>
      _set(() => _distance = v, _kDistance, v.name);

  Future<void> setArea(AreaUnit v) => _set(() => _area = v, _kArea, v.name);

  Future<void> setRate(RateDisplay v) => _set(() => _rate = v, _kRate, v.name);

  Future<void> setElevation(ElevationUnit v) =>
      _set(() => _elevation = v, _kElevation, v.name);

  Future<void> setEnergy(EnergyUnit v) =>
      _set(() => _energy = v, _kEnergy, v.name);

  Future<void> setClock(ClockFormat v) =>
      _set(() => _clock = v, _kClock, v.name);

  Future<void> setWeekStart(WeekStart v) =>
      _set(() => _weekStart = v, _kWeekStart, v.name);

  /// Flips every measurement row to one system at once. Clock format and
  /// week start are untouched — neither belongs to either system, and
  /// silently changing someone's clock because they picked miles would be
  /// surprising.
  Future<void> applySystem(UnitSystem system) async {
    if (system == UnitSystem.custom) return;
    final imperial = system == UnitSystem.imperial;
    _distance = imperial ? DistanceUnit.miles : DistanceUnit.kilometers;
    _area = imperial ? AreaUnit.imperial : AreaUnit.metric;
    _elevation = imperial ? ElevationUnit.feet : ElevationUnit.meters;
    _configured = true;
    notifyListeners();

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kDistance, _distance.name);
      await prefs.setString(_kArea, _area.name);
      await prefs.setString(_kElevation, _elevation.name);
      await prefs.setBool(_kConfigured, true);
    } catch (e) {
      debugPrint('UnitPreferences.applySystem persist failed: $e');
    }
    unawaited(_mirrorToCloud());
  }

  /// Notifies listeners *first*, then persists — the UI must never wait on a
  /// disk write to redraw a toggle, and a failed write costs a preference,
  /// not a working app.
  Future<void> _set(VoidCallback apply, String key, String value) async {
    apply();
    _configured = true;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, value);
      await prefs.setBool(_kConfigured, true);
    } catch (e) {
      debugPrint('UnitPreferences persist failed for $key: $e');
    }
    unawaited(_mirrorToCloud());
  }

  // ── Cloud mirror ────────────────────────────────────────────────────────

  Map<String, String> _toMap() => {
    'distance': _distance.name,
    'area': _area.name,
    'rate': _rate.name,
    'elevation': _elevation.name,
    'energy': _energy.name,
    'clock': _clock.name,
    'weekStart': _weekStart.name,
  };

  /// Best-effort background write, never awaited by a caller and never
  /// surfaced to the user — the local copy is authoritative, so a failure
  /// here costs nothing but cross-device sync until the next change.
  Future<void> _mirrorToCloud() async {
    // The `try` has to cover `FirebaseAuth.instance` itself, not just the
    // write: reading it throws synchronously when Firebase has not been
    // initialised, and this runs unawaited — an escape here becomes an
    // unhandled async error rather than a caught one.
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) return;
      await FirebaseFirestore.instance.collection('profiles').doc(uid).set({
        _cloudField: _toMap(),
      }, SetOptions(merge: true));
    } catch (e) {
      debugPrint('UnitPreferences cloud mirror failed: $e');
    }
  }

  /// Adopts the signed-in user's stored preferences from Firestore — but
  /// **only on a device where they have never picked anything themselves**
  /// ([isConfigured] false). That is the fresh-install/new-device case; once
  /// a user has touched the settings here, that choice is theirs and a stale
  /// cloud copy must not undo it. In that direction the local copy is pushed
  /// up instead, so the cloud converges on the most recent deliberate
  /// choice.
  ///
  /// Called once from `HomeScreen.initState` alongside the other warm-up
  /// work, since that is the first point the user is certainly signed in.
  Future<void> syncFromCloud() async {
    try {
      // Same reasoning as `_mirrorToCloud`: the auth read is inside the
      // `try`, since it throws when Firebase is not initialised.
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) return;

      if (_configured) {
        unawaited(_mirrorToCloud());
        return;
      }

      final doc = await FirebaseFirestore.instance
          .collection('profiles')
          .doc(uid)
          .get();
      final raw = doc.data()?[_cloudField];
      if (raw is! Map) return;

      T pick<T extends Enum>(String key, List<T> values, T fallback) {
        final name = raw[key];
        for (final v in values) {
          if (v.name == name) return v;
        }
        return fallback;
      }

      _distance = pick('distance', DistanceUnit.values, _distance);
      _area = pick('area', AreaUnit.values, _area);
      _rate = pick('rate', RateDisplay.values, _rate);
      _elevation = pick('elevation', ElevationUnit.values, _elevation);
      _energy = pick('energy', EnergyUnit.values, _energy);
      _clock = pick('clock', ClockFormat.values, _clock);
      _weekStart = pick('weekStart', WeekStart.values, _weekStart);
      notifyListeners();

      // Persisted so the next cold start does not need the network — but
      // deliberately *not* marked configured: these came from the cloud, not
      // from this user tapping a row here, so a newer cloud value should
      // still be able to replace them next launch.
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kDistance, _distance.name);
      await prefs.setString(_kArea, _area.name);
      await prefs.setString(_kRate, _rate.name);
      await prefs.setString(_kElevation, _elevation.name);
      await prefs.setString(_kEnergy, _energy.name);
      await prefs.setString(_kClock, _clock.name);
      await prefs.setString(_kWeekStart, _weekStart.name);
    } catch (e) {
      debugPrint('UnitPreferences.syncFromCloud failed: $e');
    }
  }

  /// App-lifetime singleton — never disposed, same contract as
  /// `RunSessionController.instance`.
  @override
  void dispose() {
    assert(false, 'UnitPreferences is an app-lifetime singleton');
    super.dispose();
  }

  /// Test hook: restores the shipped defaults without touching disk.
  @visibleForTesting
  void resetForTest() {
    _distance = DistanceUnit.kilometers;
    _area = AreaUnit.metric;
    _rate = RateDisplay.pace;
    _elevation = ElevationUnit.meters;
    _energy = EnergyUnit.kcal;
    _clock = ClockFormat.h24;
    _weekStart = WeekStart.monday;
    _configured = false;
    _warmedUp = false;
    notifyListeners();
  }
}
