/// Energy burned per kilometre run, in kcal.
///
/// This app has never measured energy — every writer, from the live run
/// controller to the watch importer to the dev-only test run creator, has
/// always computed exactly `distanceKm * 70`. Naming it once makes that fact
/// explicit and keeps the number in one place, which matters now that energy
/// is **derived rather than stored** (see [caloriesForDistance]).
const double kCaloriesPerKm = 70.0;

/// The energy estimate for a run (or a planned route) of [meters].
///
/// **Energy is deliberately not persisted.** It is a pure function of the
/// distance, which is stored, so a second copy could only ever drift or go
/// stale — and, as a stored field, it was a body metric sitting on a document
/// every signed-in user can read. Deriving it removes both problems at once:
/// there is one source of truth, and there is nothing extra on the wire.
///
/// Note this also means energy cannot be made *secret* — anyone who can see
/// the distance can multiply. Hiding the tile from other users (see
/// `RunSessionDetailPage`) is a courtesy, not a privacy boundary; heart rate,
/// which genuinely cannot be derived, is the metric that gets a real one.
double caloriesForDistance(double meters) => (meters / 1000.0) * kCaloriesPerKm;
