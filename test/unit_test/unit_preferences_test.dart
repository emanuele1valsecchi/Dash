import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dash/services/unit_preferences.dart';

/// `UnitPreferences` is an app-lifetime singleton, so every test resets it.
/// Without that, one test choosing miles leaks into every test that runs
/// afterwards — and since the runner does not guarantee an order, the
/// resulting failure comes and goes.
void main() {
  final prefs = UnitPreferences.instance;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    prefs.resetForTesting();
  });

  tearDown(prefs.resetForTesting);

  Future<Map<String, Object?>> stored() async {
    final p = await SharedPreferences.getInstance();
    return {for (final k in p.getKeys()) k: p.get(k)};
  }

  group('defaults', () {
    test('are metric on every device', () async {
      // Deliberately not guessed from the platform locale: landing on
      // imperial for someone who never asked was reported as far more
      // jarring than metric is for a miles user, who flips one switch.
      await prefs.warmUp();

      expect(prefs.distance, DistanceUnit.kilometers);
      expect(prefs.area, AreaUnit.metric);
      expect(prefs.rate, RateDisplay.pace);
      expect(prefs.elevation, ElevationUnit.meters);
      expect(prefs.energy, EnergyUnit.kcal);
      expect(prefs.clock, ClockFormat.h24);
      expect(prefs.weekStart, WeekStart.monday);
    });

    test('a first launch is not treated as a deliberate choice', () async {
      // If it were, `syncFromCloud` could never adopt the user's settings on
      // a new device.
      await prefs.warmUp();

      expect(prefs.isConfigured, isFalse);
    });

    test('the preset reads as metric', () async {
      await prefs.warmUp();

      expect(prefs.system, UnitSystem.metric);
    });
  });

  group('warmUp', () {
    test('restores what was stored', () async {
      SharedPreferences.setMockInitialValues({
        'units_distance_v1': 'miles',
        'units_area_v1': 'imperial',
        'units_configured_v1': true,
      });

      await prefs.warmUp();

      expect(prefs.distance, DistanceUnit.miles);
      expect(prefs.area, AreaUnit.imperial);
      expect(prefs.isConfigured, isTrue);
    });

    test('an unrecognised stored value falls back to the default', () async {
      // Values persist by `name`, so a renamed or removed enum entry must
      // degrade rather than throw on launch.
      SharedPreferences.setMockInitialValues({
        'units_distance_v1': 'furlongs',
      });

      await prefs.warmUp();

      expect(prefs.distance, DistanceUnit.kilometers);
    });

    test('runs only once', () async {
      await prefs.warmUp();
      await prefs.setDistance(DistanceUnit.miles);

      await prefs.warmUp();

      expect(prefs.distance, DistanceUnit.miles,
          reason: 'a second warm-up must not undo a live choice');
    });
  });

  group('setting a unit', () {
    test('takes effect immediately', () async {
      await prefs.setDistance(DistanceUnit.miles);

      expect(prefs.distance, DistanceUnit.miles);
    });

    test('notifies listeners so the whole app repaints', () async {
      var notifications = 0;
      void listener() => notifications++;
      prefs.addListener(listener);
      addTearDown(() => prefs.removeListener(listener));

      await prefs.setDistance(DistanceUnit.miles);

      expect(notifications, greaterThanOrEqualTo(1));
    });

    test('is persisted to disk', () async {
      await prefs.setDistance(DistanceUnit.miles);

      expect((await stored())['units_distance_v1'], 'miles');
    });

    test('marks the device as configured', () async {
      // This is what stops a stale cloud copy overwriting a deliberate local
      // choice on the next launch.
      await prefs.setClock(ClockFormat.h12);

      expect(prefs.isConfigured, isTrue);
      expect((await stored())['units_configured_v1'], isTrue);
    });

    test('every setter persists under its own key', () async {
      await prefs.setDistance(DistanceUnit.miles);
      await prefs.setArea(AreaUnit.imperial);
      await prefs.setRate(RateDisplay.speed);
      await prefs.setElevation(ElevationUnit.feet);
      await prefs.setEnergy(EnergyUnit.kilojoules);
      await prefs.setClock(ClockFormat.h12);
      await prefs.setWeekStart(WeekStart.sunday);

      final s = await stored();
      expect(s['units_distance_v1'], 'miles');
      expect(s['units_area_v1'], 'imperial');
      expect(s['units_rate_v1'], 'speed');
      expect(s['units_elevation_v1'], 'feet');
      expect(s['units_energy_v1'], 'kilojoules');
      expect(s['units_clock_v1'], 'h12');
      expect(s['units_week_start_v1'], 'sunday');
    });

    test('survives a restart', () async {
      await prefs.setDistance(DistanceUnit.miles);
      final saved = await stored();

      prefs.resetForTesting();
      SharedPreferences.setMockInitialValues(saved.cast<String, Object>());
      await prefs.warmUp();

      expect(prefs.distance, DistanceUnit.miles);
    });
  });

  group('the imperial/metric preset', () {
    test('applying imperial switches the measurement rows', () async {
      await prefs.applySystem(UnitSystem.imperial);

      expect(prefs.distance, DistanceUnit.miles);
      expect(prefs.area, AreaUnit.imperial);
      expect(prefs.elevation, ElevationUnit.feet);
      expect(prefs.system, UnitSystem.imperial);
    });

    test('and back to metric', () async {
      await prefs.applySystem(UnitSystem.imperial);

      await prefs.applySystem(UnitSystem.metric);

      expect(prefs.distance, DistanceUnit.kilometers);
      expect(prefs.system, UnitSystem.metric);
    });

    test('a mixed selection reads as custom', () async {
      await prefs.setDistance(DistanceUnit.miles);

      expect(prefs.system, UnitSystem.custom);
    });

    test('clock and week start do not affect the preset', () async {
      // Neither is a property of the metric or imperial system, so choosing
      // a 12-hour clock must not make the preset row read "custom".
      await prefs.setClock(ClockFormat.h12);
      await prefs.setWeekStart(WeekStart.sunday);

      expect(prefs.system, UnitSystem.metric);
    });
  });

  group('the cloud mirror', () {
    late FakeFirebaseFirestore db;

    void signedInAs(String uid) {
      db = FakeFirebaseFirestore();
      prefs.firestoreOverride = db;
      prefs.authOverride = MockFirebaseAuth(
        signedIn: true,
        mockUser: MockUser(uid: uid),
      );
    }

    test('writes the choice up so it follows the user to a new device',
        () async {
      signedInAs('me');

      await prefs.setDistance(DistanceUnit.miles);
      // The mirror is deliberately not awaited by the setter.
      await Future<void>.delayed(Duration.zero);

      final doc = await db.collection('profiles').doc('me').get();
      expect(doc.data()!['unitPreferences']['distance'], 'miles');
    });

    test('merges, so it cannot wipe the rest of the profile', () async {
      signedInAs('me');
      await db.collection('profiles').doc('me').set({'totalPoints': 4200});

      await prefs.setDistance(DistanceUnit.miles);
      await Future<void>.delayed(Duration.zero);

      final doc = await db.collection('profiles').doc('me').get();
      expect(doc.data()!['totalPoints'], 4200);
    });

    test('writes nothing when nobody is signed in', () async {
      db = FakeFirebaseFirestore();
      prefs.firestoreOverride = db;
      prefs.authOverride = MockFirebaseAuth();

      await prefs.setDistance(DistanceUnit.miles);
      await Future<void>.delayed(Duration.zero);

      expect((await db.collection('profiles').get()).docs, isEmpty);
    });
  });

  group('syncFromCloud', () {
    late FakeFirebaseFirestore db;

    void signedInAs(String uid) {
      db = FakeFirebaseFirestore();
      prefs.firestoreOverride = db;
      prefs.authOverride = MockFirebaseAuth(
        signedIn: true,
        mockUser: MockUser(uid: uid),
      );
    }

    Future<void> cloudSays(Map<String, String> units) =>
        db.collection('profiles').doc('me').set({'unitPreferences': units});

    test('adopts the stored choice on a device that has none', () async {
      signedInAs('me');
      await cloudSays({'distance': 'miles', 'area': 'imperial'});

      await prefs.syncFromCloud();

      expect(prefs.distance, DistanceUnit.miles);
      expect(prefs.area, AreaUnit.imperial);
    });

    test('never overrides a choice made on this device', () async {
      // The deciding rule: a stale cloud copy must not undo something the
      // user deliberately picked here.
      //
      // Order matters, and getting it wrong makes this test vacuous: the
      // setter mirrors its own value up, so writing the conflicting cloud
      // value *first* just gets overwritten and the two agree by the time
      // sync runs. The cloud has to start disagreeing after the local
      // choice has settled.
      signedInAs('me');
      await prefs.setDistance(DistanceUnit.kilometers);
      await Future<void>.delayed(Duration.zero);
      await cloudSays({'distance': 'miles'});

      await prefs.syncFromCloud();

      expect(prefs.distance, DistanceUnit.kilometers);
    });

    test('pushes the local choice up instead', () async {
      signedInAs('me');
      await prefs.setDistance(DistanceUnit.kilometers);
      await Future<void>.delayed(Duration.zero);
      await cloudSays({'distance': 'miles'});

      await prefs.syncFromCloud();
      await Future<void>.delayed(Duration.zero);

      final doc = await db.collection('profiles').doc('me').get();
      expect(doc.data()!['unitPreferences']['distance'], 'kilometers',
          reason: 'the cloud converges on the most recent deliberate choice');
    });

    test('an adopted value is not marked as this device\'s own choice',
        () async {
      // It came from the cloud, not from a tap here, so a newer cloud value
      // must still be able to replace it next launch.
      signedInAs('me');
      await cloudSays({'distance': 'miles'});

      await prefs.syncFromCloud();

      expect(prefs.isConfigured, isFalse);
    });

    test('an adopted value is cached so the next launch needs no network',
        () async {
      signedInAs('me');
      await cloudSays({'distance': 'miles'});

      await prefs.syncFromCloud();

      expect((await stored())['units_distance_v1'], 'miles');
    });

    test('an unknown value in the cloud falls back rather than throwing',
        () async {
      signedInAs('me');
      await cloudSays({'distance': 'parsecs'});

      await prefs.syncFromCloud();

      expect(prefs.distance, DistanceUnit.kilometers);
    });

    test('a profile with no stored preferences changes nothing', () async {
      signedInAs('me');
      await db.collection('profiles').doc('me').set({'totalPoints': 1});

      await prefs.syncFromCloud();

      expect(prefs.distance, DistanceUnit.kilometers);
    });

    test('does nothing when nobody is signed in', () async {
      db = FakeFirebaseFirestore();
      prefs.firestoreOverride = db;
      prefs.authOverride = MockFirebaseAuth();

      await prefs.syncFromCloud();

      expect(prefs.distance, DistanceUnit.kilometers);
    });
  });
}
