import 'package:dash_watch_protocol/dash_watch_protocol.dart';

/// Where the watch's live numbers come from.
///
/// An interface rather than wiring the phone relay straight into the widgets,
/// because three different sources are expected over this app's life and the UI
/// must not care which is active:
///
///  * a phone-relay source (companion mode) reading the Wearable Data Layer.
///  * a local-GPS source for standalone "leave the phone at home" recording.
///
/// Both produce identical `RunStats`, so every screen written against this
/// interface works unchanged in either mode.
///
/// A third implementation used to live here — a synthetic generator for
/// building the screens without a phone in the room. It was never referenced
/// outside its own doc comment, so it shipped in every build as 133 lines of
/// dead code, and it is gone.
abstract class RunStatsSource {
  /// Live snapshots. Emits on every meaningful change, not on a fixed clock.
  Stream<RunStats> get stats;

  /// The most recent snapshot, for building before the first event arrives.
  RunStats get current;

  /// Asks the session to change state. Named `send` rather than `start`/`pause`
  /// because in companion mode the watch never *performs* the action — the
  /// phone owns the session and may refuse or ignore the request.
  Future<void> send(WatchCommand command);

  /// Clears a finished run's summary and returns the watch to idle.
  ///
  /// Only meaningful for a run the watch recorded itself: a phone-owned run's
  /// summary clears when the phone says so. Defaults to doing nothing so
  /// sources that never show a lingering summary need not implement it.
  void dismissSummary() {}

  void dispose();
}
