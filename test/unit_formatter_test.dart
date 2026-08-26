import 'package:dash/services/unit_preferences.dart';
import 'package:dash/utils/unit_formatter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The whole point of [UnitFormatter] being a pure value object is that the
/// conversion layer can be pinned down without a device, a widget tree or a
/// `SharedPreferences` mock — every screen in the app renders through these
/// methods, so a rounding or inversion bug here is an app-wide bug.
void main() {
  // The `UnitPreferences` group below drives the real singleton, which
  // persists on every set. Mocking the store keeps that from failing into a
  // caught-but-noisy error; the Firebase mirror still logs one handled
  // failure per set, which is itself the degradation this asserts is safe.
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  const metric = UnitFormatter.metric;

  const imperial = UnitFormatter(
    distanceUnit: DistanceUnit.miles,
    areaUnit: AreaUnit.imperial,
    rateDisplay: RateDisplay.pace,
    elevationUnit: ElevationUnit.feet,
    energyUnit: EnergyUnit.kilojoules,
    clockFormat: ClockFormat.h12,
    weekStart: WeekStart.sunday,
  );

  group('distance', () {
    test('metric switches to metres below a kilometre', () {
      expect(metric.distance(850), '850 m');
      expect(metric.distance(1000), '1.00 km');
      expect(metric.distance(8420), '8.42 km');
    });

    test('imperial switches to feet below a tenth of a mile', () {
      // 100 m is well under 0.1 mi (160.9 m), so it reads in feet.
      expect(imperial.distance(100), '328 ft');
      expect(imperial.distance(8420), '5.23 mi');
    });

    test('distanceMajor never falls back to the sub-unit', () {
      // The whole reason it exists: a stat grid must not mix "850 m" and
      // "8.42 km" in adjacent cells.
      expect(metric.distanceMajor(850), '0.85 km');
      expect(imperial.distanceMajor(100), '0.06 mi');
    });

    test('major/metres round-trip exactly', () {
      for (final units in [metric, imperial]) {
        expect(units.metersToMajor(units.majorToMeters(5)), closeTo(5, 1e-9));
      }
    });

    test('a typed distance converts to the metres search actually uses', () {
      expect(metric.majorToMeters(5), 5000);
      expect(imperial.majorToMeters(5), closeTo(8046.72, 0.01));
    });

    test('short distances round in the displayed unit, not the stored one', () {
      // Rounding after conversion is what keeps the imperial reading a round
      // number too — rounding 83 m to 80 m and then converting would give
      // "262 ft".
      expect(metric.shortDistance(83, roundTo: 10), '80 m');
      expect(imperial.shortDistance(83, roundTo: 10), '270 ft');
    });
  });

  group('area', () {
    test('always the major unit, with precision scaling by magnitude', () {
      expect(metric.area(2500000), '2.50 km²');
      expect(metric.area(640000), '0.640 km²');
      expect(metric.area(2000), '0.0020 km²');
    });

    test('imperial uses square miles on the same ladder', () {
      expect(imperial.area(2589988.110336), '1.00 mi²');
      expect(imperial.area(640000), '0.247 mi²');
    });
  });

  group('pace and speed', () {
    test('pace converts per-km to per-mile', () {
      expect(metric.pace(5.5), '5:30');
      // 5.5 min/km × 1.609344 = 8.851 min/mi → 8:51.
      expect(imperial.pace(5.5), '8:51');
    });

    test('a 59.6-second remainder carries instead of rendering :60', () {
      // 5.993 min → 5 min 59.6 s, which rounds to 60 seconds.
      expect(metric.pace(5.9932), '6:00');
    });

    test('speed display inverts pace, and vice versa', () {
      const speedMetric = UnitFormatter(
        distanceUnit: DistanceUnit.kilometers,
        areaUnit: AreaUnit.metric,
        rateDisplay: RateDisplay.speed,
        elevationUnit: ElevationUnit.meters,
        energyUnit: EnergyUnit.kcal,
        clockFormat: ClockFormat.h24,
        weekStart: WeekStart.monday,
      );
      // 5.5 min/km is 10.909… km/h.
      expect(speedMetric.rateFromPace(5.5), '10.9 km/h');
      expect(metric.rateFromSpeedKmh(10.909), '5:30 /km');
    });

    test('label and unit always agree with the value', () {
      expect(metric.rateLabel, 'Pace');
      expect(metric.rateUnitLabel, '/km');
      expect(imperial.rateUnitLabel, '/mi');
    });

    test('a run that has not moved has no rate, not a rate of zero', () {
      // Zero would divide to infinity on the pace↔speed flip, so it must be
      // rejected rather than rendered.
      for (final v in <double?>[null, 0, -1, double.infinity, double.nan]) {
        expect(metric.rateFromPace(v), '--:--');
        expect(metric.rateFromSpeedKmh(v), '--:--');
      }
    });
  });

  group('elevation and energy', () {
    test('elevation converts to feet and stays whole', () {
      expect(metric.elevation(96), '96 m');
      expect(imperial.elevation(96), '315 ft');
    });

    test('energy converts kcal to kJ', () {
      expect(metric.energy(512), '512 kcal');
      expect(imperial.energy(512), '2142 kJ');
    });

    test('a typed energy target converts back to the kcal search uses', () {
      expect(
        imperial.displayToKcal(imperial.kcalToDisplay(512)),
        closeTo(512, 1e-9),
      );
    });
  });

  group('clock', () {
    test('24-hour pads both halves', () {
      expect(metric.time(DateTime(2026, 3, 14, 9, 5)), '09:05');
      expect(metric.time(DateTime(2026, 3, 14, 18, 35)), '18:35');
    });

    test('12-hour renders midnight and noon as 12, not 0', () {
      expect(imperial.time(DateTime(2026, 3, 14, 0, 5)), '12:05 AM');
      expect(imperial.time(DateTime(2026, 3, 14, 12, 5)), '12:05 PM');
      expect(imperial.time(DateTime(2026, 3, 14, 18, 35)), '6:35 PM');
    });
  });

  group('UnitPreferences.system', () {
    tearDown(() => UnitPreferences.instance.resetForTest());

    test('reads as custom when the measurement rows disagree', () {
      final prefs = UnitPreferences.instance;
      expect(prefs.system, UnitSystem.metric);

      prefs.setDistance(DistanceUnit.miles);
      expect(prefs.system, UnitSystem.custom);

      prefs.setArea(AreaUnit.imperial);
      prefs.setElevation(ElevationUnit.feet);
      expect(prefs.system, UnitSystem.imperial);
    });

    test('clock and week start do not affect the preset', () {
      final prefs = UnitPreferences.instance;
      prefs.setClock(ClockFormat.h12);
      prefs.setWeekStart(WeekStart.sunday);
      // Neither belongs to the metric or imperial system, so the preset must
      // still read as metric rather than dropping to custom.
      expect(prefs.system, UnitSystem.metric);
    });
  });
}
