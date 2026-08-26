import '../services/unit_preferences.dart';

/// Every measurement string the app renders, in the user's chosen units.
///
/// Deliberately a **pure value object**: it holds the seven enum choices and
/// nothing else — no `BuildContext`, no `SharedPreferences`, no singleton
/// reach-through — so the whole conversion/formatting layer is unit-testable
/// without a device or a widget tree, the same way `GeometryUtils` is.
///
/// Get one with `Units.of(context)` (rebuilds the caller when the user
/// changes a setting) or `Units.current` (a snapshot, for callbacks and
/// other non-build code). See `lib/widgets/units_scope.dart`.
///
/// Internally the app stays **metric end to end** — every stored value, every
/// Firestore field and every geometry calculation is metres, m², min/km and
/// kcal. Conversion happens here and only here, at the moment of display,
/// which is why nothing server-side (XP, areas, territory) has to know this
/// setting exists.
class UnitFormatter {
  const UnitFormatter({
    required this.distanceUnit,
    required this.areaUnit,
    required this.rateDisplay,
    required this.elevationUnit,
    required this.energyUnit,
    required this.clockFormat,
    required this.weekStart,
  });

  /// The shipped metric defaults — used as the fallback when no `UnitsScope`
  /// is above the caller (tests, and any widget built outside the app root).
  static const UnitFormatter metric = UnitFormatter(
    distanceUnit: DistanceUnit.kilometers,
    areaUnit: AreaUnit.metric,
    rateDisplay: RateDisplay.pace,
    elevationUnit: ElevationUnit.meters,
    energyUnit: EnergyUnit.kcal,
    clockFormat: ClockFormat.h24,
    weekStart: WeekStart.monday,
  );

  factory UnitFormatter.from(UnitPreferences prefs) => UnitFormatter(
    distanceUnit: prefs.distance,
    areaUnit: prefs.area,
    rateDisplay: prefs.rate,
    elevationUnit: prefs.elevation,
    energyUnit: prefs.energy,
    clockFormat: prefs.clock,
    weekStart: prefs.weekStart,
  );

  final DistanceUnit distanceUnit;
  final AreaUnit areaUnit;
  final RateDisplay rateDisplay;
  final ElevationUnit elevationUnit;
  final EnergyUnit energyUnit;
  final ClockFormat clockFormat;
  final WeekStart weekStart;

  // ── Conversion factors ──────────────────────────────────────────────────
  //
  // Exact definitions, not approximations: the international mile and foot
  // are *defined* as these values, and the thermochemical calorie is defined
  // as exactly 4.184 J.
  static const double metersPerMile = 1609.344;
  static const double metersPerFoot = 0.3048;
  static const double m2PerSquareMile = 2589988.110336;
  static const double kJPerKcal = 4.184;

  bool get _imperialDistance => distanceUnit == DistanceUnit.miles;
  bool get _imperialArea => areaUnit == AreaUnit.imperial;

  // ── Distance ────────────────────────────────────────────────────────────

  /// `'km'` or `'mi'` — the major unit's own label, for input-field suffixes
  /// and column headers where the number is rendered separately.
  String get distanceUnitLabel => _imperialDistance ? 'mi' : 'km';

  /// `'m'` or `'ft'` — the sub-unit used by [distance] for short lengths.
  String get shortDistanceUnitLabel => _imperialDistance ? 'ft' : 'm';

  /// Metres → the user's major unit (km or miles). The inverse of
  /// [majorToMeters]; the pair is what input fields round-trip through.
  double metersToMajor(double meters) =>
      _imperialDistance ? meters / metersPerMile : meters / 1000.0;

  /// The user's major unit (km or miles) → metres. Use this on **every**
  /// numeric distance the user types, so what reaches the routing/search
  /// layer is always metric regardless of what they see.
  double majorToMeters(double value) =>
      _imperialDistance ? value * metersPerMile : value * 1000.0;

  double metersToShort(double meters) =>
      _imperialDistance ? meters / metersPerFoot : meters;

  /// The main distance label, switching to the sub-unit for short lengths:
  /// `'4.21 km'` / `'850 m'`, or `'2.62 mi'` / `'930 ft'`.
  ///
  /// The switch happens below one tenth of the major unit rather than below
  /// a whole one — `'0.06 mi'` carries barely two significant digits, while
  /// `'320 ft'` reads exactly. Metric keeps its familiar 1 km threshold
  /// because `'0.85 km'` and `'850 m'` are equally readable and the latter is
  /// what the app has always shown.
  String distance(double meters, {int decimals = 2}) {
    if (_imperialDistance) {
      if (meters < metersPerMile * 0.1) {
        return '${metersToShort(meters).round()} ft';
      }
      return '${(meters / metersPerMile).toStringAsFixed(decimals)} mi';
    }
    if (meters < 1000) return '${meters.round()} m';
    return '${(meters / 1000).toStringAsFixed(decimals)} km';
  }

  /// Always the major unit, never the sub-unit — for stat grids and result
  /// rows where a neighbouring cell showing `'m'` next to one showing `'km'`
  /// would read as a mistake.
  String distanceMajor(double meters, {int decimals = 2}) =>
      '${metersToMajor(meters).toStringAsFixed(decimals)} $distanceUnitLabel';

  /// Always the sub-unit — for the short, imprecise distances turn guidance
  /// deals in. [roundTo] is applied in the *displayed* unit, so metric rounds
  /// to 10 m and imperial to 10 ft rather than to a converted-and-therefore
  /// odd-looking figure.
  String shortDistance(double meters, {int roundTo = 1}) {
    final v = metersToShort(meters);
    final rounded = roundTo <= 1
        ? v.roundToDouble()
        : (v / roundTo).round() * roundTo.toDouble();
    return '${rounded.round()} $shortDistanceUnitLabel';
  }

  // ── Area ────────────────────────────────────────────────────────────────

  /// `'km²'` or `'mi²'`.
  String get areaUnitLabel => _imperialArea ? 'mi²' : 'km²';

  double m2ToMajor(double m2) =>
      _imperialArea ? m2 / m2PerSquareMile : m2 / 1000000.0;

  /// Area in the major unit **always** — never switching to hectares/acres
  /// by magnitude.
  ///
  /// That is a deliberate carry-over of the app-wide rule this replaced
  /// (`GeometryUtils.formatAreaKm2`): a claimed territory that reads `'2 ha'`
  /// on one screen and `'0.02 km²'` on another is impossible to compare at a
  /// glance, and territory sizes are the app's core score. Precision scales
  /// with magnitude instead, so a small claim still shows real digits.
  String area(double m2) {
    final major = m2ToMajor(m2);
    if (major >= 1) return '${major.toStringAsFixed(2)} $areaUnitLabel';
    if (major >= 0.01) return '${major.toStringAsFixed(3)} $areaUnitLabel';
    return '${major.toStringAsFixed(4)} $areaUnitLabel';
  }

  // ── Pace / speed ────────────────────────────────────────────────────────

  bool get showsPace => rateDisplay == RateDisplay.pace;

  /// `'Pace'` or `'Speed'` — for a stat tile's caption, so the label and the
  /// value can never disagree about which one is being shown.
  String get rateLabel => showsPace ? 'Pace' : 'Speed';

  /// `'/km'`, `'/mi'`, `'km/h'` or `'mph'`.
  String get rateUnitLabel {
    if (showsPace) return _imperialDistance ? '/mi' : '/km';
    return _imperialDistance ? 'mph' : 'km/h';
  }

  /// `'5:30'` in the user's distance unit. Pure minutes-per-distance — the
  /// unit itself is [rateUnitLabel], kept separate because most stat tiles
  /// render it in a smaller caption.
  ///
  /// Returns `'--:--'` for a missing or nonsensical value: a run that has not
  /// moved yet has *no* pace, which is not the same as a pace of zero.
  String pace(double? minPerKm) {
    if (minPerKm == null || !minPerKm.isFinite || minPerKm <= 0) return '--:--';
    final adjusted = _imperialDistance
        ? minPerKm * (metersPerMile / 1000.0)
        : minPerKm;
    final minutes = adjusted.floor();
    final seconds = ((adjusted - minutes) * 60).round();
    // A 59.6 s remainder rounds to 60 and would render as `'5:60'`.
    if (seconds == 60) return '${minutes + 1}:00';
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  /// `'10.4'` — the numeric half of a speed, unit in [rateUnitLabel].
  String speedValue(double? kmh) {
    if (kmh == null || !kmh.isFinite || kmh <= 0) return '--';
    final v = _imperialDistance ? kmh / (metersPerMile / 1000.0) : kmh;
    return v.toStringAsFixed(1);
  }

  /// `'10.4 km/h'` / `'6.5 mph'`, unit included.
  String speed(double? kmh) {
    final v = speedValue(kmh);
    return v == '--' ? '--' : '$v $rateUnitLabel';
  }

  /// A rate given as **pace**, rendered as whichever of pace/speed the user
  /// asked for — the bare number, no unit.
  ///
  /// This and [rateValueFromSpeedKmh] are the two entry points every rate
  /// readout should use: pace and speed are the same quantity, so a screen
  /// holding either can always show the other. Use the `rateFrom…` pair
  /// below when the unit belongs inline, and this pair when the unit lives in
  /// a neighbouring caption (a big live pace readout, a stat tile).
  String rateValueFromPace(double? minPerKm) {
    if (!_isUsableRate(minPerKm)) return showsPace ? '--:--' : '--';
    return showsPace ? pace(minPerKm) : speedValue(60.0 / minPerKm!);
  }

  /// A rate given as **speed in km/h**, rendered as whichever of pace/speed
  /// the user asked for — the bare number, no unit.
  String rateValueFromSpeedKmh(double? kmh) {
    if (!_isUsableRate(kmh)) return showsPace ? '--:--' : '--';
    return showsPace ? pace(60.0 / kmh!) : speedValue(kmh);
  }

  /// [rateValueFromPace] with the unit appended.
  String rateFromPace(double? minPerKm) {
    if (!_isUsableRate(minPerKm)) return showsPace ? '--:--' : '--';
    return '${rateValueFromPace(minPerKm)} $rateUnitLabel';
  }

  /// [rateValueFromSpeedKmh] with the unit appended.
  String rateFromSpeedKmh(double? kmh) {
    if (!_isUsableRate(kmh)) return showsPace ? '--:--' : '--';
    return '${rateValueFromSpeedKmh(kmh)} $rateUnitLabel';
  }

  /// A run that has not moved yet has *no* rate, which is not the same as a
  /// rate of zero — and zero would divide to infinity on the pace/speed
  /// flip, so it is rejected rather than rendered.
  static bool _isUsableRate(double? v) => v != null && v.isFinite && v > 0;

  // ── Elevation ───────────────────────────────────────────────────────────

  String get elevationUnitLabel =>
      elevationUnit == ElevationUnit.feet ? 'ft' : 'm';

  double metersToElevation(double meters) =>
      elevationUnit == ElevationUnit.feet ? meters / metersPerFoot : meters;

  /// `'128 m'` / `'420 ft'`. Always whole units — GPS altitude is nowhere
  /// near accurate enough to justify a decimal.
  String elevation(double meters) =>
      '${metersToElevation(meters).round()} $elevationUnitLabel';

  // ── Energy ──────────────────────────────────────────────────────────────

  String get energyUnitLabel =>
      energyUnit == EnergyUnit.kilojoules ? 'kJ' : 'kcal';

  double kcalToDisplay(double kcal) =>
      energyUnit == EnergyUnit.kilojoules ? kcal * kJPerKcal : kcal;

  /// The inverse — for the calorie *target* field on the route search page,
  /// so a number typed in kJ reaches the search logic as kcal.
  double displayToKcal(double value) =>
      energyUnit == EnergyUnit.kilojoules ? value / kJPerKcal : value;

  /// `'420 kcal'` / `'1757 kJ'`.
  String energy(double kcal) =>
      '${kcalToDisplay(kcal).round()} $energyUnitLabel';

  // ── Clock ───────────────────────────────────────────────────────────────

  /// `'14:05'` or `'2:05 PM'`.
  ///
  /// Hand-rolled rather than routed through `intl`'s `DateFormat`, because
  /// this has to honour the *user's* choice, not the device locale's — a
  /// locale-driven `jm` pattern would ignore the setting entirely.
  String time(DateTime t) {
    if (clockFormat == ClockFormat.h24) {
      return '${t.hour.toString().padLeft(2, '0')}:'
          '${t.minute.toString().padLeft(2, '0')}';
    }
    final suffix = t.hour < 12 ? 'AM' : 'PM';
    // Midnight and noon are hour 0 and 12 respectively on a 12-hour clock.
    final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
    return '$h:${t.minute.toString().padLeft(2, '0')} $suffix';
  }

  /// Monday = 1 … Sunday = 7, matching `DateTime.weekday`, for grouping runs
  /// into weeks.
  int get firstWeekdayNumber =>
      weekStart == WeekStart.sunday ? DateTime.sunday : DateTime.monday;
}
