import 'package:flutter/material.dart';

import '../services/unit_preferences.dart';
import '../utils/unit_formatter.dart';
import '../widgets/units_scope.dart';

/// Settings → Units. Every measurement the app renders is controlled from
/// here.
///
/// Each dimension is exactly two choices, so every row is a two-segment
/// switch rather than a tile that pushes another page — the whole set is
/// visible and changeable without leaving the screen, and the sample card at
/// the top shows what a real run looks like as the switches move.
///
/// The page holds no state of its own: it reads `UnitPreferences.instance`
/// through [Units.of] and writes back to it, and the `UnitsScope` above
/// `MaterialApp` rebuilds this page (and every screen behind it) on change.
class UnitsSettingsPage extends StatelessWidget {
  const UnitsSettingsPage({super.key});

  static const Color _accent = Color(0xFF4A8C52);
  static const Color _accentSoft = Color(0xFFCAF0B8);
  static const Color _muted = Color(0xFF8A9389);
  static const Color _ink = Color(0xFF1E241D);
  static const Color _bg = Color(0xFFF5F6F0);

  @override
  Widget build(BuildContext context) {
    final prefs = UnitPreferences.instance;
    final units = Units.of(context);

    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Color(0xFF495348)),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text(
          'Units',
          style: TextStyle(
            color: _accent,
            fontSize: 16,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 40),
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            child: Text(
              'Choose how distances, areas and times are shown across the '
              'app. Your runs are always recorded the same way — this only '
              'changes what you see.',
              style: TextStyle(color: _muted, fontSize: 13),
            ),
          ),

          _sectionHeader('PRESET'),
          _buildPreset(context, prefs),

          _sectionHeader('MEASUREMENTS'),
          _UnitRow<DistanceUnit>(
            icon: Icons.straighten_rounded,
            title: 'Distance',
            subtitle: 'Run length, route length, distance to go',
            value: prefs.distance,
            options: const {
              DistanceUnit.kilometers: 'km',
              DistanceUnit.miles: 'mi',
            },
            onChanged: prefs.setDistance,
          ),
          _UnitRow<AreaUnit>(
            icon: Icons.crop_free_rounded,
            title: 'Area',
            subtitle: 'Territory you claim on the map',
            value: prefs.area,
            options: const {AreaUnit.metric: 'km²', AreaUnit.imperial: 'mi²'},
            onChanged: prefs.setArea,
          ),
          _UnitRow<RateDisplay>(
            icon: Icons.speed_rounded,
            title: 'Pace or speed',
            subtitle:
                'Pace counts time per '
                '${units.distanceUnitLabel}; speed counts '
                '${units.distanceUnitLabel} per hour',
            value: prefs.rate,
            options: const {
              RateDisplay.pace: 'Pace',
              RateDisplay.speed: 'Speed',
            },
            onChanged: prefs.setRate,
          ),
          _UnitRow<ElevationUnit>(
            icon: Icons.terrain_rounded,
            title: 'Elevation',
            subtitle: 'Height gained over a run',
            value: prefs.elevation,
            options: const {
              ElevationUnit.meters: 'm',
              ElevationUnit.feet: 'ft',
            },
            onChanged: prefs.setElevation,
          ),
          _UnitRow<EnergyUnit>(
            icon: Icons.local_fire_department_rounded,
            title: 'Energy',
            subtitle: 'Calories burned',
            value: prefs.energy,
            options: const {
              EnergyUnit.kcal: 'kcal',
              EnergyUnit.kilojoules: 'kJ',
            },
            onChanged: prefs.setEnergy,
          ),

          _sectionHeader('DATE & TIME'),
          _UnitRow<ClockFormat>(
            icon: Icons.schedule_rounded,
            title: 'Clock',
            subtitle: 'Times on your activities and notifications',
            value: prefs.clock,
            options: const {ClockFormat.h24: '24h', ClockFormat.h12: '12h'},
            onChanged: prefs.setClock,
          ),
          _UnitRow<WeekStart>(
            icon: Icons.calendar_month_rounded,
            title: 'Week starts on',
            subtitle: 'Calendar layout and weekly stats',
            value: prefs.weekStart,
            options: const {WeekStart.monday: 'Mon', WeekStart.sunday: 'Sun'},
            onChanged: prefs.setWeekStart,
          ),

          _sectionHeader('PREVIEW'),
          _buildPreview(units),
        ],
      ),
    );
  }

  // ── Preset ──────────────────────────────────────────────────────────────

  /// Flips distance, area and elevation together. Reads as "Custom" — a
  /// third, unselectable segment — whenever those three no longer agree, so
  /// the control never claims a system the user is not actually on.
  Widget _buildPreset(BuildContext context, UnitPreferences prefs) {
    final system = prefs.system;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SegmentedButton<UnitSystem>(
            segments: [
              const ButtonSegment(
                value: UnitSystem.metric,
                label: Text('Metric'),
              ),
              const ButtonSegment(
                value: UnitSystem.imperial,
                label: Text('Imperial'),
              ),
              ButtonSegment(
                value: UnitSystem.custom,
                label: const Text('Custom'),
                enabled: system == UnitSystem.custom,
              ),
            ],
            selected: {system},
            showSelectedIcon: false,
            onSelectionChanged: (selection) =>
                prefs.applySystem(selection.first),
            style: ButtonStyle(
              textStyle: const WidgetStatePropertyAll(
                TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
              backgroundColor: WidgetStateProperty.resolveWith(
                (states) => states.contains(WidgetState.selected)
                    ? _accentSoft
                    : Colors.white,
              ),
              foregroundColor: WidgetStateProperty.resolveWith(
                (states) => states.contains(WidgetState.selected)
                    ? const Color(0xFF2E7D32)
                    : _muted,
              ),
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Sets distance, area and elevation at once. Everything below can '
            'still be changed individually.',
            style: TextStyle(color: _muted, fontSize: 12),
          ),
        ],
      ),
    );
  }

  // ── Preview ─────────────────────────────────────────────────────────────

  /// A fixed sample run rendered through the live formatter, so the effect of
  /// a switch is visible without leaving the page. The numbers are metric
  /// constants — exactly what the rest of the app stores — put through the
  /// same conversion path every real screen uses.
  Widget _buildPreview(UnitFormatter units) {
    const sampleMeters = 8420.0;
    const samplePaceMinPerKm = 5.5;
    const sampleAreaM2 = 640000.0;
    const sampleElevationM = 96.0;
    const sampleKcal = 512.0;
    final sampleTime = DateTime(2026, 3, 14, 18, 35);

    return Container(
      margin: const EdgeInsets.fromLTRB(20, 4, 20, 0),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'A sample run',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: _ink,
            ),
          ),
          const SizedBox(height: 10),
          _previewRow('Distance', units.distanceMajor(sampleMeters)),
          _previewRow(units.rateLabel, units.rateFromPace(samplePaceMinPerKm)),
          _previewRow('Area claimed', units.area(sampleAreaM2)),
          _previewRow('Elevation', units.elevation(sampleElevationM)),
          _previewRow('Energy', units.energy(sampleKcal)),
          _previewRow('Finished at', units.time(sampleTime)),
        ],
      ),
    );
  }

  Widget _previewRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(fontSize: 13, color: _muted)),
          Text(
            value,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: _ink,
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 20, right: 20, top: 22, bottom: 8),
      child: Text(
        title,
        style: const TextStyle(
          color: _muted,
          fontSize: 12,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}

/// One dimension: an icon, a name, what it affects, and a two-segment switch.
///
/// Generic over the enum so each row keeps its own type end to end — there is
/// no stringly-typed key in the middle that could drift from the enum it is
/// meant to name.
class _UnitRow<T extends Enum> extends StatelessWidget {
  const _UnitRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final T value;
  final Map<T, String> options;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      child: Row(
        children: [
          Icon(icon, size: 22, color: UnitsSettingsPage._accent),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: UnitsSettingsPage._ink,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: const TextStyle(
                    fontSize: 12,
                    color: UnitsSettingsPage._muted,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          _Switcher<T>(value: value, options: options, onChanged: onChanged),
        ],
      ),
    );
  }
}

/// A compact two-option toggle. Hand-built rather than a `SegmentedButton`
/// because that one sizes itself to the available width, which would push the
/// row's label off screen; this stays as narrow as its labels need.
class _Switcher<T extends Enum> extends StatelessWidget {
  const _Switcher({
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final T value;
  final Map<T, String> options;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: const Color(0xFFECEFE6),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final entry in options.entries)
            _segment(entry.key, entry.value, entry.key == value),
        ],
      ),
    );
  }

  Widget _segment(T option, String label, bool selected) {
    return Semantics(
      selected: selected,
      button: true,
      child: GestureDetector(
        onTap: selected ? null : () => onChanged(option),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOut,
          constraints: const BoxConstraints(minWidth: 48),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: selected ? Colors.white : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            boxShadow: selected
                ? const [
                    BoxShadow(
                      color: Color(0x14000000),
                      blurRadius: 4,
                      offset: Offset(0, 1),
                    ),
                  ]
                : null,
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: selected
                  ? const Color(0xFF2E7D32)
                  : UnitsSettingsPage._muted,
            ),
          ),
        ),
      ),
    );
  }
}
