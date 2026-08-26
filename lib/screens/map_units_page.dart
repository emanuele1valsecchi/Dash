import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../services/unit_preferences.dart';
import '../utils/dash_snackbar.dart';
import '../utils/unit_formatter.dart';
import '../widgets/units_scope.dart';

/// Settings → Map & Units. Every measurement the app renders is controlled
/// from here.
///
/// Backed by `UnitPreferences.instance` rather than this page's own
/// `SharedPreferences` read: the choices have to be readable synchronously
/// from every screen that formats a number (see [UnitFormatter]), which a
/// per-page `getBool` could not provide. That also removes the `_isLoading`
/// spinner this page used to need — `UnitPreferences.warmUp()` is awaited in
/// `main()` before the first frame, so the values are always already there.
///
/// The page holds no state of its own; the `UnitsScope` above `MaterialApp`
/// rebuilds it — and every screen behind it in the navigation stack — when a
/// value changes.
class MapUnitsPage extends StatelessWidget {
  const MapUnitsPage({super.key});

  static const Color _accent = Color(0xFF4A8C52);

  @override
  Widget build(BuildContext context) {
    final prefs = UnitPreferences.instance;
    final units = Units.of(context);

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        elevation: 0,
        backgroundColor: Colors.transparent,
        leading: IconButton(
          icon: Icon(
            Icons.arrow_back,
            color: Theme.of(context).colorScheme.secondary,
          ),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          'Map & Units',
          style: TextStyle(
            color: Theme.of(context).colorScheme.secondary,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          const SizedBox(height: 10),

          // --- MEASUREMENT SYSTEM (Wrapped in RadioGroup for Flutter 3.32+) ---
          _sectionHeader(context, 'MEASUREMENT SYSTEM'),
          _RadioSection<DistanceUnit>(
            groupValue: prefs.distance,
            onChanged: prefs.setDistance,
            options: const [
              _RadioOption(
                value: DistanceUnit.kilometers,
                title: 'Kilometers (km)',
                subtitle: 'Standard metric system',
                icon: Symbols.straighten_rounded,
              ),
              _RadioOption(
                value: DistanceUnit.miles,
                title: 'Miles (mi)',
                subtitle: 'Imperial system',
                icon: Symbols.social_distance_rounded,
              ),
            ],
          ),

          const Divider(height: 32),

          // Territory size — the app's core score, so it gets its own choice
          // rather than silently following the distance unit.
          _sectionHeader(context, 'AREA'),
          _RadioSection<AreaUnit>(
            groupValue: prefs.area,
            onChanged: prefs.setArea,
            options: const [
              _RadioOption(
                value: AreaUnit.metric,
                title: 'Square kilometers (km²)',
                subtitle: 'Standard metric system',
                icon: Symbols.crop_free_rounded,
              ),
              _RadioOption(
                value: AreaUnit.imperial,
                title: 'Square miles (mi²)',
                subtitle: 'Imperial system',
                icon: Symbols.crop_square_rounded,
              ),
            ],
          ),

          const Divider(height: 32),

          // Not a metric/imperial choice — the same quantity shown two ways.
          // The distance half of either follows the setting above.
          _sectionHeader(context, 'PACE OR SPEED'),
          _RadioSection<RateDisplay>(
            groupValue: prefs.rate,
            onChanged: prefs.setRate,
            options: [
              _RadioOption(
                value: RateDisplay.pace,
                title: 'Pace',
                subtitle:
                    'Time per ${units.distanceUnitLabel} — e.g. 5:30 '
                    '/${units.distanceUnitLabel}',
                icon: Symbols.speed_rounded,
              ),
              _RadioOption(
                value: RateDisplay.speed,
                title: 'Speed',
                subtitle:
                    '${units.distanceUnitLabel == 'mi' ? 'Miles' : 'Kilometers'} '
                    'per hour — e.g. 10.9 '
                    '${units.distanceUnitLabel == 'mi' ? 'mph' : 'km/h'}',
                icon: Symbols.shutter_speed_rounded,
              ),
            ],
          ),

          const Divider(height: 32),

          _sectionHeader(context, 'ELEVATION'),
          _RadioSection<ElevationUnit>(
            groupValue: prefs.elevation,
            onChanged: prefs.setElevation,
            options: const [
              _RadioOption(
                value: ElevationUnit.meters,
                title: 'Meters (m)',
                subtitle: 'Standard metric system',
                icon: Symbols.terrain_rounded,
              ),
              _RadioOption(
                value: ElevationUnit.feet,
                title: 'Feet (ft)',
                subtitle: 'Imperial system',
                icon: Symbols.landscape_rounded,
              ),
            ],
          ),

          const Divider(height: 32),

          _sectionHeader(context, 'ENERGY'),
          _RadioSection<EnergyUnit>(
            groupValue: prefs.energy,
            onChanged: prefs.setEnergy,
            options: const [
              _RadioOption(
                value: EnergyUnit.kcal,
                title: 'Calories (kcal)',
                subtitle: 'Most common worldwide',
                icon: Symbols.local_fire_department_rounded,
              ),
              _RadioOption(
                value: EnergyUnit.kilojoules,
                title: 'Kilojoules (kJ)',
                subtitle: 'Standard in Australia and New Zealand',
                icon: Symbols.bolt_rounded,
              ),
            ],
          ),

          const Divider(height: 32),

          _sectionHeader(context, 'DATE & TIME'),
          _RadioSection<ClockFormat>(
            groupValue: prefs.clock,
            onChanged: prefs.setClock,
            options: const [
              _RadioOption(
                value: ClockFormat.h24,
                title: '24-hour clock',
                subtitle: 'e.g. 18:35',
                icon: Symbols.schedule_rounded,
              ),
              _RadioOption(
                value: ClockFormat.h12,
                title: '12-hour clock',
                subtitle: 'e.g. 6:35 PM',
                icon: Symbols.av_timer_rounded,
              ),
            ],
          ),
          _RadioSection<WeekStart>(
            groupValue: prefs.weekStart,
            onChanged: prefs.setWeekStart,
            options: const [
              _RadioOption(
                value: WeekStart.monday,
                title: 'Week starts Monday',
                subtitle: 'Calendar layout and weekly stats',
                icon: Symbols.calendar_month_rounded,
              ),
              _RadioOption(
                value: WeekStart.sunday,
                title: 'Week starts Sunday',
                subtitle: 'Calendar layout and weekly stats',
                icon: Symbols.calendar_today_rounded,
              ),
            ],
          ),

          const Divider(height: 32),

          _sectionHeader(context, 'PREVIEW'),
          _buildPreview(context, units),

          const Divider(height: 32),

          // You can expand this section later with Map Styles
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 20),
            leading: const Icon(Symbols.map_rounded),
            title: const Text('Map Theme'),
            subtitle: const Text('Coming soon'),
            trailing: const Icon(
              Icons.lock_rounded,
              color: Colors.grey,
              size: 20,
            ),
            onTap: () => context.showInformationSnackBar(
              'Map Themes will be unlocked in a future update! 🗺️',
            ),
          ),
        ],
      ),
    );
  }

  /// A fixed sample run put through the live formatter, so the effect of a
  /// choice is visible without leaving the page. The numbers are the metric
  /// constants the rest of the app stores, taking the same conversion path
  /// every real screen uses.
  Widget _buildPreview(BuildContext context, UnitFormatter units) {
    const sampleMeters = 8420.0;
    const samplePaceMinPerKm = 5.5;
    const sampleAreaM2 = 640000.0;
    const sampleElevationM = 96.0;
    const sampleKcal = 512.0;
    final sampleTime = DateTime(2026, 3, 14, 18, 35);

    final rows = <(String, String)>[
      ('Distance', units.distanceMajor(sampleMeters)),
      (units.rateLabel, units.rateFromPace(samplePaceMinPerKm)),
      ('Area claimed', units.area(sampleAreaM2)),
      ('Elevation', units.elevation(sampleElevationM)),
      ('Energy', units.energy(sampleKcal)),
      ('Finished at', units.time(sampleTime)),
    ];

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'A sample run',
            style: Theme.of(
              context,
            ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 10),
          for (final (label, value) in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(label, style: Theme.of(context).textTheme.bodySmall),
                  Text(
                    value,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _sectionHeader(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      child: Text(
        title,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: Colors.grey,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}

/// One selectable unit within a [_RadioSection].
class _RadioOption<T> {
  const _RadioOption({
    required this.value,
    required this.title,
    required this.subtitle,
    required this.icon,
  });

  final T value;
  final String title;
  final String subtitle;
  final IconData icon;
}

/// A `RadioGroup` of unit choices.
///
/// Generic over the enum so each section keeps its own type end to end —
/// there is no stringly-typed key in the middle that could drift from the
/// enum it names. `groupValue`/`onChanged` live on the parent `RadioGroup`,
/// per the Flutter 3.32+ API.
class _RadioSection<T extends Enum> extends StatelessWidget {
  const _RadioSection({
    required this.groupValue,
    required this.onChanged,
    required this.options,
  });

  final T groupValue;
  final ValueChanged<T> onChanged;
  final List<_RadioOption<T>> options;

  @override
  Widget build(BuildContext context) {
    return RadioGroup<T>(
      groupValue: groupValue,
      onChanged: (value) {
        if (value != null) onChanged(value);
      },
      child: Column(
        children: [
          for (final option in options)
            RadioListTile<T>(
              title: Text(option.title),
              subtitle: Text(option.subtitle),
              value: option.value,
              activeColor: MapUnitsPage._accent,
              secondary: Icon(option.icon),
            ),
        ],
      ),
    );
  }
}
