import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:permission_handler_platform_interface/permission_handler_platform_interface.dart'
    show PermissionHandlerPlatform;
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'package:dash/services/location_service.dart';

/// Substitutes the Geolocator and permission_handler platform channels, so
/// anything sitting on top of `LocationService` — the service itself, or a
/// screen that calls `LocationService.instance.start()` from `initState` —
/// can be driven with synthetic fixes instead of a device.
///
/// Both plugins are replaced at their platform-interface `instance`, which
/// means the *real* `LocationService` runs: this is a fake device, not a fake
/// service. `MockPlatformInterfaceMixin` is what lets each fake past the
/// interface's own token check.
///
/// Call [installFakeLocationPlatform] from `setUp`. It registers its own
/// teardown, including resetting the `LocationService` singleton — without
/// that, one test's granted permission and last known fix leak into the next.
class FakeLocationPlatform {
  FakeLocationPlatform._(this.geolocator, this.permissions);

  final FakeGeolocator geolocator;
  final FakePermissions permissions;

  /// Grants permission and makes [position] the fix `start()` will find.
  void grant(LatLng position) {
    permissions.status = PermissionStatus.granted;
    geolocator.nextPosition = positionAt(position.latitude, position.longitude);
  }

  /// Refuses permission, so `start()` returns with nothing running.
  void deny() {
    permissions.status = PermissionStatus.denied;
  }

  /// Pushes a fix onto the live stream, as a moving device would.
  void move(LatLng position) => geolocator
      .emit(positionAt(position.latitude, position.longitude));
}

/// Installs the fakes for one test and returns the handle to drive them.
FakeLocationPlatform installFakeLocationPlatform() {
  final geolocator = FakeGeolocator();
  final permissions = FakePermissions();
  GeolocatorPlatform.instance = geolocator;
  PermissionHandlerPlatform.instance = permissions;

  addTearDown(() async {
    await LocationService.instance.resetForTest();
    await geolocator.dispose();
  });

  return FakeLocationPlatform._(geolocator, permissions);
}

/// Builds a GPS fix. Defaults are deliberately "good" — accurate, at running
/// speed, with a valid heading — so a test only states the field it is about.
Position positionAt(
  double latitude,
  double longitude, {
  DateTime? timestamp,
  double accuracy = 5,
  double altitude = 120,
  double speed = 3,
  double heading = 90,
}) {
  return Position(
    latitude: latitude,
    longitude: longitude,
    timestamp: timestamp ?? DateTime.utc(2026, 1, 1),
    accuracy: accuracy,
    altitude: altitude,
    altitudeAccuracy: 3,
    heading: heading,
    headingAccuracy: 5,
    speed: speed,
    speedAccuracy: 1,
  );
}

/// Stands in for the Geolocator platform channel.
class FakeGeolocator extends GeolocatorPlatform with MockPlatformInterfaceMixin {
  final _controller = StreamController<Position>.broadcast();

  /// Returned by the next [getCurrentPosition] call.
  Position? nextPosition;

  /// When set, [getCurrentPosition] throws this instead of returning.
  Object? currentPositionError;

  /// When > 0, that many [getPositionStream] calls throw before one succeeds.
  int positionStreamFailures = 0;

  int currentPositionCalls = 0;
  int positionStreamCalls = 0;

  void emit(Position p) => _controller.add(p);

  Future<void> dispose() => _controller.close();

  @override
  Future<Position> getCurrentPosition({LocationSettings? locationSettings}) async {
    currentPositionCalls++;
    if (currentPositionError != null) throw currentPositionError!;
    return nextPosition!;
  }

  @override
  Stream<Position> getPositionStream({LocationSettings? locationSettings}) {
    positionStreamCalls++;
    if (positionStreamFailures > 0) {
      positionStreamFailures--;
      throw Exception('stream unavailable');
    }
    return _controller.stream;
  }
}

/// Stands in for the permission_handler platform channel, answering every
/// requested permission with [status].
class FakePermissions extends PermissionHandlerPlatform
    with MockPlatformInterfaceMixin {
  PermissionStatus status = PermissionStatus.granted;
  int requests = 0;

  @override
  Future<Map<Permission, PermissionStatus>> requestPermissions(
    List<Permission> permissions,
  ) async {
    requests++;
    return {for (final p in permissions) p: status};
  }

  @override
  Future<PermissionStatus> checkPermissionStatus(Permission permission) async =>
      status;
}
