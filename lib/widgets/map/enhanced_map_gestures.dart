import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

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
///     before landing here). This widget tracks the first two fingers
///     directly via a raw [Listener]
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
///  3. **Correcting a real flutter_map/Flutter-framework gesture bug**: a
///     fast pinch released with the two fingers lifting even a few
///     milliseconds apart (rather than at the exact same instant, which no
///     real touch ever is) makes the map jump sideways in a
///     seemingly-random direction in addition to the zoom, which is
///     otherwise correct. Root cause, confirmed directly against the
///     Flutter SDK (`packages/flutter/lib/src/gestures/scale.dart`,
///     `ScaleGestureRecognizer`): the recognizer's focal point is defined
///     as the live average of *currently touching* pointers, recomputed
///     synchronously the instant a pointer is removed — going from
///     "midpoint of two fingers" to "position of the one remaining
///     finger" in a single step, with no interpolation — and it fires
///     `onUpdate` with that jumped value immediately, in the same event
///     that removed the pointer (`handleEvent` → `_update()` →
///     `_advanceStateMachine`). flutter_map's own pan math
///     (`MapInteractiveViewerState._calculatePinchZoomAndMove`) consumes
///     that absolute focal point directly, so the discontinuity becomes a
///     real camera pan. This is a framework/library-level interaction, not
///     something introduced by this app, and not something a plain
///     [Listener] can prevent outright — a `Listener` observes events
///     without competing in the gesture arena, so it has no way to cancel
///     or filter pointer events flutter_map's own recognizer has already
///     claimed. What it *can* do: continuously remember the camera's own
///     center/zoom while a genuine 2+-finger touch is ongoing
///     (`_lastStableCenter`/`_lastStableZoom`), and the instant the touch
///     drops below 2 fingers, restore the camera to that last known-good
///     state via `_settleMultiTouchRelease` — deferred to a microtask so it
///     runs after whatever flutter_map's recognizer just did to the camera
///     synchronously, but still before that frame is ever built/painted,
///     so the jump is never actually visible. That same microtask *then*
///     starts zoom inertia (point 2), in that fixed order, rather than the
///     two being independent actions — they used to race (the correction's
///     one-time `.move()` and the inertia animation's own recurring
///     `.move()` calls both mutate the same camera, and whichever landed
///     last for a given frame won), and the correction winning was what
///     made the inertia animation appear to stop happening entirely after
///     this fix first landed. Ordering them explicitly inside one
///     microtask — correct once, *then* kick off inertia from that
///     already-corrected basis — removes the race by construction. This is
///     paired with a *targeted* cancellation of flutter_map's own native
///     fling — the same focal-point discontinuity can also corrupt the
///     gesture's *velocity* reading right as the whole touch ends, which
///     independently risks a spurious fling in a similarly "random"
///     direction. Blanket-disabling `InteractiveFlag.flingAnimation`
///     (an earlier version of this fix) stopped that, but also killed the
///     ordinary, wanted momentum glide after a plain single-finger drag —
///     flutter_map doesn't distinguish "fling from a clean drag" from
///     "fling from a corrupted multi-touch release", so an
///     `InteractiveFlag` alone can't express "only sometimes". Instead,
///     fling stays enabled, and `_multiFingerDropTime` records exactly when
///     a touch dropped below 2 fingers; if the *final* release (all
///     fingers up — the actual moment flutter_map's recognizer decides
///     whether to start a fling, per `didStopTrackingLastPointer`) follows
///     within `_flingCorruptionWindow`, `_cancelAnyNativeFling` fires a
///     `MapController.move()` back to `_lastStableCenter`/
///     `_lastStableZoom` — which, being a real move via the public API
///     (tagged `MapEventSource.mapController`), makes flutter_map's own
///     `interruptAnimatedMovement` stop the fling as a side effect (see
///     `MapControllerImpl._emitMapEvent` in the flutter_map source). A
///     plain single-finger drag never sets `_multiFingerDropTime` at all,
///     so its fling is completely untouched.
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

  // ── Multi-touch release jump correction ─────────────────────────────────
  //
  // See point 3 of the class doc comment above for the full rationale.
  // Continuously refreshed to the camera's own center/zoom while a genuine
  // 2+-finger touch is ongoing, so there's always a "last known-good"
  // camera state to restore to the instant a finger lifts mid-gesture.
  LatLng? _lastStableCenter;
  double? _lastStableZoom;

  /// Set the instant a 2+-finger touch drops below 2 fingers (see
  /// `_settleMultiTouchRelease`); cleared once the whole touch fully ends.
  /// Used only to decide whether the *final* release (the one remaining
  /// finger lifting) is close enough in time to that transition to still
  /// risk a fling computed from the corrupted velocity reading — a user
  /// who keeps panning with the one remaining finger for a while after the
  /// other lifts is doing a perfectly ordinary single-finger drag by the
  /// time they release it, and its fling should be left completely alone.
  DateTime? _multiFingerDropTime;

  /// How soon after a multi-finger touch drops below 2 fingers a *full*
  /// release still risks a fling built from the corrupted velocity —
  /// matches roughly how far back a velocity tracker's recent-samples
  /// window reaches, not an arbitrary guess.
  static const Duration _flingCorruptionWindow = Duration(milliseconds: 300);

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
      _multiFingerDropTime = DateTime.now();
      _settleMultiTouchRelease();
    }

    if (_pointers.isEmpty) {
      // The whole touch has now fully ended — this is the exact moment
      // flutter_map's own recognizer decides whether to start a native
      // fling, from a velocity reading that's only at risk of being
      // corrupted if a multi-finger drop happened moments ago (see
      // `_flingCorruptionWindow`). A plain single-finger drag never sets
      // `_multiFingerDropTime` at all, so its fling is never touched here.
      final dropTime = _multiFingerDropTime;
      if (dropTime != null && DateTime.now().difference(dropTime) < _flingCorruptionWindow) {
        _cancelAnyNativeFling();
      }
      _multiFingerDropTime = null;
    }
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (!_pointers.containsKey(event.pointer)) return;
    _pointers[event.pointer] = event.localPosition;

    if (_pointers.length >= 2) {
      _lastMultiFingerFocal = _averageOffset(_pointers.values);
      _recordZoomSample();
      _lastStableCenter = widget.mapController.camera.center;
      _lastStableZoom = widget.mapController.camera.zoom;
    }

    _updateRotation();
  }

  /// Called once, the instant a 2+-finger touch drops below 2 fingers.
  /// Combines the release-jump correction and the zoom-inertia kickoff into
  /// a single, strictly-ordered microtask — they used to be two independent
  /// actions (a corrective `.move()` plus `_maybeStartZoomInertia`'s own
  /// `.move()` calls via its animation), which could race: whichever landed
  /// last for a given frame won, and the one-time correction winning masked
  /// the inertia animation's visible start entirely. Ordering them
  /// explicitly — correct first, *then* start inertia from that
  /// already-corrected basis — removes the race by construction. Deferred
  /// to a microtask (rather than run synchronously here) so it lands after
  /// whatever flutter_map's own recognizer just did to the camera
  /// synchronously (see the class doc comment, point 3), but still before
  /// this frame is ever painted.
  void _settleMultiTouchRelease() {
    final center = _lastStableCenter;
    final zoom = _lastStableZoom;
    scheduleMicrotask(() {
      if (!mounted) return;
      if (center != null && zoom != null) {
        widget.mapController.move(center, zoom);
      }
      _maybeStartZoomInertia();
      _zoomSamples.clear();
    });
  }

  /// Cancels a native fling that flutter_map's own recognizer may have just
  /// started from a velocity reading corrupted by the release-jump
  /// discontinuity (see the class doc comment, point 3). A plain
  /// `MapController.move()` call — the public API, tagged
  /// `MapEventSource.mapController` — is what does the cancelling:
  /// flutter_map's `MapControllerImpl._emitMapEvent` calls
  /// `interruptAnimatedMovement` (which stops its internal fling/
  /// double-tap-zoom controllers) for exactly that event source, as a side
  /// effect of it being a real, public-API-triggered move — not because of
  /// anything specific to fling. Moving back to `_lastStableCenter`/
  /// `_lastStableZoom` both supplies that real move (a move to the exact
  /// current position emits no event at all, so this only works because
  /// it's a move to a genuinely *different*, correct position) and
  /// re-settles the camera if a fling had already nudged it before this
  /// ran. No-ops harmlessly if no fling was actually started.
  void _cancelAnyNativeFling() {
    final center = _lastStableCenter;
    final zoom = _lastStableZoom;
    if (center == null || zoom == null) return;
    scheduleMicrotask(() {
      if (!mounted) return;
      widget.mapController.move(center, zoom);
    });
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
      offset: midpoint,
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
      _inertiaFocal,
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
