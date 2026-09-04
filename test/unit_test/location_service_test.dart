import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';

import 'package:dash/services/location_service.dart';

import '../helpers/fake_location_platform.dart';

/// `LocationService` is the app's single GPS entry point: one Geolocator
/// stream started once and kept warm for the app's lifetime, so no screen
/// re-requests a fix of its own. Almost everything worth pinning down here is
/// about *not* doing work twice (one permission prompt, one stream, however
/// many screens ask) and about a refusal or a dropped fix never becoming
/// permanent — the failure modes are "the map never loads again until
/// restart", which no widget test would catch.
///
/// The real service is driven throughout: both plugins are substituted at
/// their platform-interface `instance`, so the code under test is the same
/// code that ships.
void main() {
  final service = LocationService.instance;

  late FakeGeolocator geolocator;
  late FakePermissions permissions;

  /// Builds a fix. Only latitude/longitude are ever asserted on, so the rest
  /// is plausible filler.
  Position fix(double latitude, double longitude) => Position(
        latitude: latitude,
        longitude: longitude,
        timestamp: DateTime.utc(2026, 1, 1),
        accuracy: 5,
        altitude: 120,
        altitudeAccuracy: 3,
        heading: 90,
        headingAccuracy: 5,
        speed: 3,
        speedAccuracy: 1,
      );

  setUp(() async {
    // Installs the fakes and registers the teardown that resets the
    // `LocationService` singleton — without that reset every test inherits
    // the previous one's permission, fix and live subscription.
    final platform = installFakeLocationPlatform();
    geolocator = platform.geolocator;
    permissions = platform.permissions;
    await service.resetForTest();
  });

  group('permission', () {
    test('a refusal leaves the service idle rather than half-started',
        () async {
      permissions.status = PermissionStatus.denied;

      await service.start();

      expect(service.permissionGranted, isFalse);
      expect(service.current, isNull);
      // The important half: no stream was opened behind a refusal, so the
      // app is not quietly holding a GPS subscription the user said no to.
      expect(geolocator.positionStreamCalls, 0);
      expect(geolocator.currentPositionCalls, 0);
    });

    test('a permanent refusal is treated the same as a plain one', () async {
      permissions.status = PermissionStatus.permanentlyDenied;

      await service.start();

      expect(service.permissionGranted, isFalse);
      expect(geolocator.positionStreamCalls, 0);
    });

    test('a refusal is not memoised, so granting it later still works',
        () async {
      // The documented reason: the user leaves, flips the switch in system
      // Settings, and comes back. If the first denial stuck, the map would
      // stay broken until the app was force-quit.
      permissions.status = PermissionStatus.denied;
      await service.start();
      expect(service.permissionGranted, isFalse);

      permissions.status = PermissionStatus.granted;
      geolocator.nextPosition = fix(45.4642, 9.1900);
      await service.start();

      expect(service.permissionGranted, isTrue);
      expect(service.current?.latitude, closeTo(45.4642, 1e-9));
      expect(geolocator.positionStreamCalls, 1);
    });
  });

  group('first fix', () {
    test('is fetched once and published as current', () async {
      geolocator.nextPosition = fix(45.4642, 9.1900);

      await service.start();

      expect(geolocator.currentPositionCalls, 1);
      expect(service.current, isNotNull);
      expect(service.current!.latitude, closeTo(45.4642, 1e-9));
      expect(service.current!.longitude, closeTo(9.1900, 1e-9));
    });

    test('is published to listeners before any stream fix arrives', () async {
      // Screens read `current` for their initial camera position; if the
      // one-shot fix were not published, the first map frame would have
      // nowhere to point until the user physically moved 5 m.
      geolocator.nextPosition = fix(45.4642, 9.1900);
      final seen = <double>[];
      final sub = service.updates.listen((p) => seen.add(p.latitude));
      addTearDown(sub.cancel);

      await service.start();
      await pumpEventQueue();

      expect(seen, [closeTo(45.4642, 1e-9)]);
    });

    test('failing to get one still leaves the live stream running', () async {
      // Documented intent: a single failed fix must not cost the app its
      // background stream, which may well recover on its own.
      geolocator.currentPositionError = Exception('no fix');

      await service.start();

      expect(service.current, isNull);
      expect(geolocator.positionStreamCalls, 1);

      geolocator.emit(fix(45.50, 9.20));
      await pumpEventQueue();

      expect(service.current!.latitude, closeTo(45.50, 1e-9));
    });

  });

  group('updates stream', () {
    test('broadcasts every fix and keeps current in step', () async {
      geolocator.nextPosition = fix(45.4642, 9.1900);
      final seen = <double>[];
      final sub = service.updates.listen((p) => seen.add(p.latitude));
      addTearDown(sub.cancel);

      await service.start();
      geolocator.emit(fix(45.50, 9.20));
      geolocator.emit(fix(45.51, 9.21));
      await pumpEventQueue();

      expect(seen, [
        closeTo(45.4642, 1e-9),
        closeTo(45.50, 1e-9),
        closeTo(45.51, 1e-9),
      ]);
      expect(service.current!.latitude, closeTo(45.51, 1e-9));
    });

    test('does not replay the current fix to a late subscriber', () async {
      // The contract screens are written against: read `current` first, then
      // listen. A replaying stream would make that double-count.
      geolocator.nextPosition = fix(45.4642, 9.1900);
      await service.start();

      final seen = <double>[];
      final sub = service.updates.listen((p) => seen.add(p.latitude));
      addTearDown(sub.cancel);
      await pumpEventQueue();

      expect(seen, isEmpty);
      expect(service.current, isNotNull);
    });

    test('serves several listeners at once', () async {
      // It is a broadcast stream precisely because every map screen listens.
      geolocator.nextPosition = fix(45.4642, 9.1900);
      await service.start();

      final a = <double>[], b = <double>[];
      final subA = service.updates.listen((p) => a.add(p.latitude));
      final subB = service.updates.listen((p) => b.add(p.latitude));
      addTearDown(subA.cancel);
      addTearDown(subB.cancel);

      geolocator.emit(fix(45.50, 9.20));
      await pumpEventQueue();

      expect(a, hasLength(1));
      expect(b, hasLength(1));
    });
  });

  group('starting more than once', () {
    test('a second start is a no-op once running', () async {
      geolocator.nextPosition = fix(45.4642, 9.1900);

      await service.start();
      await service.start();
      await service.start();

      expect(permissions.requests, 1,
          reason: 'the user should be prompted once, not once per screen');
      expect(geolocator.positionStreamCalls, 1);
      expect(geolocator.currentPositionCalls, 1);
    });

    test('concurrent starts are coalesced into one', () async {
      // Several screens can call start() in the same frame during startup.
      // Without the in-flight future each would open its own stream.
      geolocator.nextPosition = fix(45.4642, 9.1900);

      await Future.wait([service.start(), service.start(), service.start()]);

      expect(permissions.requests, 1);
      expect(geolocator.positionStreamCalls, 1);
    });

    test('a retry after the stream failed to open reuses the known fix',
        () async {
      // The one path that reaches the `_current == null` guard: the one-shot
      // fix lands, then opening the stream throws, leaving the service
      // granted-with-a-position but unsubscribed. The retry should pick up
      // where it left off — open the stream again, without spending a second
      // one-shot GPS request on a position it already has.
      geolocator.nextPosition = fix(45.4642, 9.1900);
      geolocator.positionStreamFailures = 1;

      await expectLater(service.start(), throwsException);
      expect(service.current!.latitude, closeTo(45.4642, 1e-9));
      expect(geolocator.currentPositionCalls, 1);

      await service.start();

      expect(geolocator.positionStreamCalls, 2);
      expect(geolocator.currentPositionCalls, 1,
          reason: 'the fix was already known, so it should not be re-requested');

      geolocator.emit(fix(45.50, 9.20));
      await pumpEventQueue();
      expect(service.current!.latitude, closeTo(45.50, 1e-9));
    });

    test('a failed start does not block a later retry', () async {
      // whenComplete clears the in-flight future on the failure path too —
      // if it did not, one denial would wedge start() forever.
      permissions.status = PermissionStatus.denied;
      await service.start();

      permissions.status = PermissionStatus.granted;
      geolocator.nextPosition = fix(45.4642, 9.1900);
      await service.start();

      expect(permissions.requests, 2);
      expect(service.permissionGranted, isTrue);
    });
  });
}
