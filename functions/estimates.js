/**
 * Server-side mirror of `lib/utils/run_estimates.dart`.
 *
 * Energy has never been measured by this app — every writer, from the live run
 * controller to the watch importer, has always computed exactly
 * `distanceKm * 70`. It is therefore **derived, not stored**: a persisted copy
 * could only drift, and as a stored field it was a body metric sitting on a
 * document every signed-in user can read.
 *
 * Keep CALORIES_PER_KM in step with `kCaloriesPerKm` on the client. They are
 * the same number for the same reason, and a run's energy must not depend on
 * whether the phone or a Cloud Function computed it.
 */

const CALORIES_PER_KM = 70.0;

/** kcal for a run (or planned route) of `meters`. */
function caloriesForDistance(meters) {
  return ((Number(meters) || 0) / 1000) * CALORIES_PER_KM;
}

module.exports = { CALORIES_PER_KM, caloriesForDistance };
