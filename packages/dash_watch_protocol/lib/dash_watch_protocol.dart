/// Wire format shared by the Dash phone app and its Wear OS companion.
///
/// Pure Dart with no Flutter dependency, so it can be unit-tested standalone
/// and imported by either side without dragging a UI framework along.
///
/// **The two apps are installed and updated independently.** A user can update
/// the phone app and not the watch, or vice versa, so every message carries a
/// [protocolVersion] and every parser is deliberately tolerant: unknown fields
/// are ignored, missing optional fields decode to null, and an unparseable
/// enum falls back rather than throwing. A stale watch showing slightly less
/// information is a far better failure than one that crashes mid-run.
library;

import 'dart:convert';

/// Bumped only on a breaking change to the shapes below. Receivers should warn
/// (not fail) on a mismatch — see the tolerance note above.
const int protocolVersion = 1;

/// Wearable Data Layer message paths.
///
/// Must be byte-identical on both sides. A typo is invisible at runtime — the
/// Data Layer delivers to whoever is listening on that exact path and silently
/// drops the rest, so a mismatched path looks exactly like "the watch isn't
/// connected". Defined once here so neither app can spell them differently.
class WearPaths {
  WearPaths._();

  /// Phone → watch: a [RunStats] snapshot.
  static const String stats = '/dash/stats';

  /// Watch → phone: a [WatchCommand].
  static const String command = '/dash/command';

  /// Watch → phone: a [HeartRateReading].
  ///
  /// Separate from [command] because it is a continuous feed rather than a
  /// one-off request, and separate from [stats] because it travels the other
  /// way — the watch is the only device that can measure it.
  static const String heartRate = '/dash/heart_rate';

  /// Watch → phone: "send me the current state now".
  ///
  /// Needed because messages are ephemeral rather than persisted — a watch that
  /// reconnects mid-run, or whose app is opened after a run has already
  /// started, has no way to learn the current state except by asking.
  static const String requestSync = '/dash/request_sync';
}

/// Where a run currently is in its lifecycle. Mirrors the phone's
/// `RunSessionController` flags, flattened into one value because a watch face
/// renders one state at a time and combinations like "counting down while
/// paused" are not separately meaningful to it.
enum RunPhase {
  /// No run in progress — the watch shows its start screen.
  idle,

  /// The pre-run countdown is ticking; [RunStats.countdownValue] is live.
  countdown,

  /// Recording.
  running,

  /// Recording suspended; the clock is stopped.
  paused,

  /// Finished, awaiting save or discard on the phone.
  finished;

  static RunPhase _parse(Object? raw) {
    for (final phase in RunPhase.values) {
      if (phase.name == raw) return phase;
    }
    // A newer phone sending a phase this watch build doesn't know about.
    // Showing "idle" is wrong but harmless; throwing mid-run is not.
    return RunPhase.idle;
  }
}

/// Turn-by-turn-ish guidance for the direction arrow, mirrored from the
/// phone's `RouteGuidance`. Null on the wire whenever no route is planned.
///
/// Carries [targetBearingDegrees] and [headingDegrees] separately rather than
/// a pre-computed relative angle: a watch with its own magnetometer can
/// substitute a live compass heading — which stays correct while standing
/// still, unlike the phone's GPS course-over-ground — without the phone
/// needing to change what it sends.
class WatchGuidance {
  /// Absolute compass bearing to steer toward, 0-360 clockwise from north.
  final double targetBearingDegrees;

  /// The runner's own heading, or null when they are too slow for GPS
  /// course-over-ground to mean anything.
  final double? headingDegrees;

  /// True when the runner has strayed past the phone's off-route threshold.
  final bool isOffRoute;

  /// Distance to the next significant change of direction, or null when the
  /// route runs straight for the whole scan range.
  final double? distanceToTurnMeters;

  /// Signed angle of that turn — negative left, positive right.
  final double? turnAngleDegrees;

  /// Distance still to run along the planned route.
  final double distanceRemainingMeters;

  const WatchGuidance({
    required this.targetBearingDegrees,
    required this.headingDegrees,
    required this.isOffRoute,
    required this.distanceToTurnMeters,
    required this.turnAngleDegrees,
    required this.distanceRemainingMeters,
  });

  /// The arrow's on-screen rotation in degrees, or null when heading is
  /// unknown and a relative arrow would be meaningless. Pass [heading] to
  /// override with a local compass reading.
  double? arrowRotationDegrees({double? heading}) {
    final source = heading ?? headingDegrees;
    if (source == null) return null;
    return (targetBearingDegrees - source + 360) % 360;
  }

  Map<String, Object?> toJson() => {
        'bearing': targetBearingDegrees,
        'heading': headingDegrees,
        'offRoute': isOffRoute,
        'turnDistance': distanceToTurnMeters,
        'turnAngle': turnAngleDegrees,
        'remaining': distanceRemainingMeters,
      };

  static WatchGuidance? fromJson(Map<String, Object?>? json) {
    if (json == null) return null;
    return WatchGuidance(
      targetBearingDegrees: _double(json['bearing']) ?? 0,
      headingDegrees: _double(json['heading']),
      isOffRoute: json['offRoute'] == true,
      distanceToTurnMeters: _double(json['turnDistance']),
      turnAngleDegrees: _double(json['turnAngle']),
      distanceRemainingMeters: _double(json['remaining']) ?? 0,
    );
  }
}

/// One snapshot of a live run, as the watch renders it.
///
/// Deliberately a flat value object of already-derived numbers rather than raw
/// breadcrumbs: the watch never recomputes distance, pace or loop geometry —
/// the phone is the single source of truth for all of it, so the two can never
/// disagree about how far you've run.
///
/// [heartRateBpm] is the one field that flows the *other* way, watch to phone:
/// no phone can measure it. It rides along here so a single shape describes the
/// run in both directions.
class RunStats {
  final RunPhase phase;

  /// Seconds left on the pre-run countdown; only meaningful in
  /// [RunPhase.countdown].
  final int countdownValue;

  final Duration elapsed;
  final double distanceMeters;

  /// Current pace, or null before enough history has accumulated.
  final double? paceMinPerKm;

  /// From the watch's own sensor. Null when unavailable, unsupported, or not
  /// yet permitted.
  final int? heartRateBpm;

  final int loopsCompleted;

  /// Area claimed so far this run, in square metres.
  final double claimedAreaM2;

  final WatchGuidance? guidance;

  const RunStats({
    required this.phase,
    this.countdownValue = 0,
    this.elapsed = Duration.zero,
    this.distanceMeters = 0,
    this.paceMinPerKm,
    this.heartRateBpm,
    this.loopsCompleted = 0,
    this.claimedAreaM2 = 0,
    this.guidance,
  });

  /// Nothing happening — what the watch shows before a run and after a reset.
  static const RunStats idle = RunStats(phase: RunPhase.idle);

  RunStats copyWith({
    RunPhase? phase,
    int? countdownValue,
    Duration? elapsed,
    double? distanceMeters,
    double? paceMinPerKm,
    int? heartRateBpm,
    int? loopsCompleted,
    double? claimedAreaM2,
    WatchGuidance? guidance,
  }) {
    return RunStats(
      phase: phase ?? this.phase,
      countdownValue: countdownValue ?? this.countdownValue,
      elapsed: elapsed ?? this.elapsed,
      distanceMeters: distanceMeters ?? this.distanceMeters,
      paceMinPerKm: paceMinPerKm ?? this.paceMinPerKm,
      heartRateBpm: heartRateBpm ?? this.heartRateBpm,
      loopsCompleted: loopsCompleted ?? this.loopsCompleted,
      claimedAreaM2: claimedAreaM2 ?? this.claimedAreaM2,
      guidance: guidance ?? this.guidance,
    );
  }

  Map<String, Object?> toJson() => {
        'v': protocolVersion,
        'phase': phase.name,
        'countdown': countdownValue,
        'elapsedMs': elapsed.inMilliseconds,
        'distance': distanceMeters,
        'pace': paceMinPerKm,
        'hr': heartRateBpm,
        'loops': loopsCompleted,
        'area': claimedAreaM2,
        'guidance': guidance?.toJson(),
      };

  factory RunStats.fromJson(Map<String, Object?> json) {
    return RunStats(
      phase: RunPhase._parse(json['phase']),
      countdownValue: _int(json['countdown']) ?? 0,
      elapsed: Duration(milliseconds: _int(json['elapsedMs']) ?? 0),
      distanceMeters: _double(json['distance']) ?? 0,
      paceMinPerKm: _double(json['pace']),
      heartRateBpm: _int(json['hr']),
      loopsCompleted: _int(json['loops']) ?? 0,
      claimedAreaM2: _double(json['area']) ?? 0,
      guidance: WatchGuidance.fromJson(
        (json['guidance'] as Map?)?.cast<String, Object?>(),
      ),
    );
  }

  String encode() => jsonEncode(toJson());

  /// Returns null rather than throwing on malformed input — a corrupt message
  /// should leave the last good reading on screen, not take the watch down
  /// mid-run.
  static RunStats? decode(String source) {
    try {
      final decoded = jsonDecode(source);
      if (decoded is! Map) return null;
      return RunStats.fromJson(decoded.cast<String, Object?>());
    } catch (_) {
      return null;
    }
  }
}

/// Heart rate, measured on the watch and sent to the phone.
///
/// Carries the running **average and maximum alongside the live value**, rather
/// than letting the phone derive them from what it receives. The watch sees
/// every sensor sample; the phone sees roughly one message a second and none at
/// all while the link is down, so a phone-side average would quietly be an
/// average of whatever happened to arrive. The watch accumulates, the phone
/// stores what it is told.
///
/// Every field is nullable and all three are absent when there is no sensor, no
/// permission, or no reading yet. Null and 0 are different: 0 bpm is not a
/// measurement.
class HeartRateReading {
  final int? currentBpm;
  final int? averageBpm;
  final int? maxBpm;

  const HeartRateReading({this.currentBpm, this.averageBpm, this.maxBpm});

  bool get hasReading => currentBpm != null;

  Map<String, Object?> toJson() => {
        'bpm': currentBpm,
        'avg': averageBpm,
        'max': maxBpm,
      };

  factory HeartRateReading.fromJson(Map<String, Object?> json) {
    return HeartRateReading(
      currentBpm: _int(json['bpm']),
      averageBpm: _int(json['avg']),
      maxBpm: _int(json['max']),
    );
  }

  String encode() => jsonEncode(toJson());

  /// Null rather than throwing on malformed input, matching [RunStats.decode] —
  /// a corrupt reading should be ignored, not crash a run in progress.
  static HeartRateReading? decode(String source) {
    try {
      final decoded = jsonDecode(source);
      if (decoded is! Map) return null;
      return HeartRateReading.fromJson(decoded.cast<String, Object?>());
    } catch (_) {
      return null;
    }
  }
}

/// Commands the watch sends back to the phone. Deliberately tiny and
/// stateless — the phone owns the session, the watch only ever asks.
enum WatchCommand {
  start,
  pause,
  resume,
  finish;

  static WatchCommand? parse(String raw) {
    for (final command in WatchCommand.values) {
      if (command.name == raw) return command;
    }
    return null;
  }
}

double? _double(Object? value) => switch (value) {
      final num n => n.toDouble(),
      _ => null,
    };

int? _int(Object? value) => switch (value) {
      final num n => n.round(),
      _ => null,
    };
