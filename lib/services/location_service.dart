import 'dart:async';

import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:permission_handler/permission_handler.dart';

/// App-wide GPS position, kept warm from shortly after login so individual
/// screens don't each show a "Getting your location" spinner and re-request
/// a fresh fix every time they're opened.
///
/// A single Geolocator position stream is started once ([start], called from
/// `HomeScreen`) and kept running for the app's lifetime — including while
/// the user is on a screen with no map — rather than every map screen
/// managing its own independent stream.
class LocationService {
  static final LocationService instance = LocationService._();
  LocationService._();

  StreamSubscription<Position>? _positionSub;
  final _controller = StreamController<LatLng>.broadcast();

  LatLng? _current;
  bool _permissionGranted = false;
  Future<void>? _inFlight;

  /// Latest known position, if any fix has been obtained yet. Screens should
  /// read this first (it may already be populated) before falling back to
  /// showing a loading state and listening to [updates].
  LatLng? get current => _current;

  /// Whether location permission has been granted, as of the last [start].
  bool get permissionGranted => _permissionGranted;

  /// Broadcasts every position update after the listener subscribes. Does
  /// not replay [current] — callers should read [current] first.
  Stream<LatLng> get updates => _controller.stream;

  /// Requests permission (if needed) and starts the shared position stream.
  /// Safe to call from every screen that needs location: a no-op once
  /// permission is granted and the stream is already running, and safe to
  /// call again after a prior denial (e.g. the user grants it from system
  /// Settings and returns to the app) since that doesn't memoize forever.
  Future<void> start() {
    if (_permissionGranted && _positionSub != null) return Future.value();
    return _inFlight ??= _doStart().whenComplete(() => _inFlight = null);
  }

  Future<void> _doStart() async {
    final status = await Permission.locationWhenInUse.request();
    _permissionGranted = status.isGranted;
    if (!_permissionGranted) return;

    if (_current == null) {
      try {
        final pos = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
        );
        _current = LatLng(pos.latitude, pos.longitude);
        _controller.add(_current!);
      } catch (_) {
        // A single fix failing shouldn't stop the background stream below
        // from starting — it may still recover on its own.
      }
    }

    _positionSub ??= Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 5,
      ),
    ).listen((pos) {
      _current = LatLng(pos.latitude, pos.longitude);
      _controller.add(_current!);
    });
  }
}
