import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

/// Wraps a [FlutterMap] (as [child]) with two gesture refinements
/// flutter_map doesn't offer on its own, applied consistently to every map
/// screen in the app that allows multi-finger interaction:
///
///  1. **Two-finger rotate with a persistent dead zone.** The wrapped map is
///     expected to have flutter_map's own rotate handling disabled (pass
///     `interactionOptions: InteractionOptions(flags: InteractiveFlag.all &
///     ~InteractiveFlag.rotate)`, adjusted for whatever other flags that
///     screen already restricts) — flutter_map's own
///     `enableMultiFingerGestureRace` can't express "always-smooth zoom +
///     a persistent rotation dead zone that doesn't lock zoom out", because
///     its gesture race picks one winner for an entire touch, not
///     continuously (this was investigated at length on the explore page
///     before landing here — see CLAUDE.md for the full history). This
///     widget tracks the first two fingers directly via a raw [Listener]
///     (which observes touches without competing in the gesture arena, so
///     it can't conflict with flutter_map's own zoom/pan handling) and only
///     starts rotating the map once cumulative twist since the two-finger
///     touch began exceeds [rotationThresholdDeg] — picking up smoothly
///     from zero past that point, not jumping ahead by the dead-zone
///     amount.
///  2. **A little zoom inertia on release.** flutter_map has fling/momentum
///     for panning but none for pinch-zoom — lifting fingers mid-pinch just
///     stops dead. This samples the zoom level during any 2+-finger touch
///     and, if it was still changing with enough speed at release, animates
///     a small, quickly-decaying continuation around the same focal point
///     — hard-capped at a fraction of a zoom level over a couple hundred
///     milliseconds (see `_maxInertiaZoomLevels`/`_inertiaDuration` below).
///     Deliberately subtle, not a full physical-style fling.
class EnhancedMapGestures extends StatefulWidget {
  final MapController mapController;
  final Widget child;

  /// Cumulative twist, in degrees, required before rotation starts.
  final double rotationThresholdDeg;

  const EnhancedMapGestures({
    super.key,
    required this.mapController,
    required this.child,
    this.rotationThresholdDeg = 8.0,
  });

  @override
  State<EnhancedMapGestures> createState() => _EnhancedMapGesturesState();
}

class _EnhancedMapGesturesState extends State<EnhancedMapGestures>
    with SingleTickerProviderStateMixin {
  // ── Shared pointer tracking ────────────────────────────────────────────
  //
  // Holds exactly the pointers currently down, keyed by pointer id in
  // touch-down order. Rotation only ever uses the first two — a third
  // finger touching down clears its tracking entirely (rather than risk
  // silently re-basing onto a different pair mid-gesture) until the count
  // settles back to exactly two; zoom-inertia sampling is less strict and
  // just watches "2 or more fingers down" as "a pinch may be happening".
  final Map<int, Offset> _pointers = {};

  // ── Rotation ────────────────────────────────────────────────────────────
  double? _rotationBaseAngleDeg;
  double? _rotationBaseMapRotation;
  bool _rotationDeadZoneCrossed = false;
  double _rotationCrossSign = 1.0;

  // ── Zoom inertia ────────────────────────────────────────────────────────
  /// Below this release speed, don't bother animating at all — avoids any
  /// visible motion after a deliberate, controlled pinch the user stopped
  /// precisely (zoom levels per second).
  static const double _minInertiaVelocity = 0.3;

  /// Hard cap on how far inertia can carry the zoom beyond wherever it was
  /// at release, regardless of how fast the flick was — keeps this "a
  /// little dynamism", not a full fling (zoom levels).
  static const double _maxInertiaZoomLevels = 0.5;

  /// Converts a release velocity (zoom levels/sec) into an extra-zoom
  /// amount before the cap above is applied. Tuned so a fast flick lands
  /// comfortably under the cap, not right at it.
  static const double _inertiaVelocityFactor = 0.12;

  static const Duration _inertiaDuration = Duration(milliseconds: 220);

  /// Only the last ~150ms of samples matter for a release-velocity
  /// estimate — older ones would blend in the start of the pinch, which
  /// usually moved at a different speed than the instant fingers lifted.
  static const Duration _zoomSampleWindow = Duration(milliseconds: 150);

  final List<_ZoomSample> _zoomSamples = [];
  Offset? _lastMultiFingerFocal;
  late final AnimationController _inertiaController;
  double _inertiaStartZoom = 0;
  double _inertiaExtraZoom = 0;
  Offset _inertiaFocal = Offset.zero;

  @override
  void initState() {
    super.initState();
    _inertiaController = AnimationController(vsync: this, duration: _inertiaDuration)
      ..addListener(_onInertiaTick);
  }

  @override
  void dispose() {
    _inertiaController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerUp,
      onPointerCancel: _onPointerUp,
      child: widget.child,
    );
  }

  // ── Pointer bookkeeping ────────────────────────────────────────────────

  void _onPointerDown(PointerDownEvent event) {
    // Any new touch cancels lingering inertia — continuing to auto-zoom
    // while the user is actively touching the screen again would fight
    // with whatever they're about to do.
    _inertiaController.stop();
    _pointers[event.pointer] = event.localPosition;
    _rearmOrClearRotationTracking();
  }

  void _onPointerUp(PointerEvent event) {
    final wasMultiFinger = _pointers.length >= 2;
    _pointers.remove(event.pointer);
    _rearmOrClearRotationTracking();
    if (wasMultiFinger && _pointers.length < 2) {
      _maybeStartZoomInertia();
      _zoomSamples.clear();
    }
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (!_pointers.containsKey(event.pointer)) return;
    _pointers[event.pointer] = event.localPosition;

    if (_pointers.length >= 2) {
      _lastMultiFingerFocal = _averageOffset(_pointers.values);
      _recordZoomSample();
    }

    _updateRotation();
  }

  Offset _averageOffset(Iterable<Offset> offsets) {
    var dx = 0.0, dy = 0.0;
    var count = 0;
    for (final o in offsets) {
      dx += o.dx;
      dy += o.dy;
      count++;
    }
    return Offset(dx / count, dy / count);
  }

  // ── Rotation ────────────────────────────────────────────────────────────

  /// Called after every change to which pointers are down. With exactly two
  /// down, (re)starts a fresh gesture reference — a new base angle/map
  /// rotation and an un-crossed dead zone — regardless of whether that
  /// two-finger state was just reached by a finger going down or by a third
  /// finger lifting back off. Any other count (0, 1, or 3+) stops rotation
  /// tracking entirely until the touch settles back to exactly two.
  void _rearmOrClearRotationTracking() {
    if (_pointers.length == 2) {
      final positions = _pointers.values.toList();
      _rotationBaseAngleDeg = _angleBetweenDeg(positions[0], positions[1]);
      _rotationBaseMapRotation = widget.mapController.camera.rotation;
      _rotationDeadZoneCrossed = false;
    } else {
      _rotationBaseAngleDeg = null;
      _rotationBaseMapRotation = null;
      _rotationDeadZoneCrossed = false;
    }
  }

  void _updateRotation() {
    final baseAngle = _rotationBaseAngleDeg;
    final baseMapRotation = _rotationBaseMapRotation;
    if (_pointers.length != 2 || baseAngle == null || baseMapRotation == null) {
      return;
    }

    final positions = _pointers.values.toList();
    final p1 = positions[0];
    final p2 = positions[1];
    final rawDelta = _normalizeAngleDeg(_angleBetweenDeg(p1, p2) - baseAngle);

    if (!_rotationDeadZoneCrossed) {
      if (rawDelta.abs() < widget.rotationThresholdDeg) return;
      // Fixed once, at the moment the dead zone is crossed — kept constant
      // for the rest of the gesture (see `appliedDelta` below) so a twist
      // that later reverses back past the starting angle doesn't cause a
      // sudden jump in which direction the threshold is subtracted from.
      _rotationCrossSign = rawDelta.isNegative ? -1.0 : 1.0;
      _rotationDeadZoneCrossed = true;
    }

    // Subtracting the (fixed-sign) threshold means rotation picks up from
    // exactly zero at the moment of crossing, rather than jumping ahead by
    // the whole dead-zone amount.
    final appliedDelta = rawDelta - _rotationCrossSign * widget.rotationThresholdDeg;
    final midpoint = Offset((p1.dx + p2.dx) / 2, (p1.dy + p2.dy) / 2);
    widget.mapController.rotateAroundPoint(
      baseMapRotation + appliedDelta,
      point: math.Point<double>(midpoint.dx, midpoint.dy),
    );
  }

  double _angleBetweenDeg(Offset a, Offset b) =>
      math.atan2(b.dy - a.dy, b.dx - a.dx) * 180 / math.pi;

  /// Normalizes a difference between two [_angleBetweenDeg] readings into
  /// (-180, 180] so a twist crossing the ±180° seam doesn't register as a
  /// near-360° jump.
  double _normalizeAngleDeg(double deg) {
    var d = deg % 360;
    if (d > 180) d -= 360;
    if (d <= -180) d += 360;
    return d;
  }

  // ── Zoom inertia ────────────────────────────────────────────────────────

  void _recordZoomSample() {
    final now = DateTime.now();
    _zoomSamples.add(_ZoomSample(widget.mapController.camera.zoom, now));
    _zoomSamples.removeWhere((s) => now.difference(s.time) > _zoomSampleWindow);
  }

  void _maybeStartZoomInertia() {
    if (_zoomSamples.length < 2) return;
    final focal = _lastMultiFingerFocal;
    if (focal == null) return;

    final first = _zoomSamples.first;
    final last = _zoomSamples.last;
    final dtSeconds = last.time.difference(first.time).inMicroseconds / 1e6;
    if (dtSeconds <= 0) return;

    final velocity = (last.zoom - first.zoom) / dtSeconds; // zoom levels/sec
    if (velocity.abs() < _minInertiaVelocity) return;

    final extraZoom = (velocity * _inertiaVelocityFactor)
        .clamp(-_maxInertiaZoomLevels, _maxInertiaZoomLevels);

    _inertiaStartZoom = widget.mapController.camera.zoom;
    _inertiaExtraZoom = extraZoom;
    _inertiaFocal = focal;
    _inertiaController
      ..stop()
      ..reset()
      ..forward();
  }

  void _onInertiaTick() {
    final curved = Curves.easeOut.transform(_inertiaController.value);
    final newZoom = _inertiaStartZoom + _inertiaExtraZoom * curved;
    final newCenter = widget.mapController.camera.focusedZoomCenter(
      math.Point<double>(_inertiaFocal.dx, _inertiaFocal.dy),
      newZoom,
    );
    widget.mapController.move(newCenter, newZoom);
  }
}

class _ZoomSample {
  final double zoom;
  final DateTime time;
  const _ZoomSample(this.zoom, this.time);
}
