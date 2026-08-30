/**
 * Pure decision logic for what happens to a user's routes when their account
 * is deleted.
 *
 * Split out of `index.js` for the same reason `geo.js` and `territory.js` are:
 * `index.js` keeps the Firestore I/O, this keeps the rules that decide what
 * gets kept, rewritten or destroyed — so they can be unit-tested with no live
 * or emulated database (`_verify_routeCascade.js`, not deployed; see
 * firebase.json's functions ignore list).
 *
 * Worth having as its own tested unit specifically because account deletion
 * is irreversible: a wrong branch here permanently destroys either a user's
 * privacy or other users' saved routes, and neither is recoverable.
 */

/**
 * Planned-route estimates, matching RouteCreatePage's own constants
 * (`_estimatedTimeMin` / `_estimatedCalories` in route_create_page.dart).
 * A scrubbed route should read exactly like a hand-planned route of the same
 * length rather than like a record of somebody's actual run.
 */
const { CALORIES_PER_KM } = require("./estimates");

const PLANNED_MIN_PER_KM = 9.0;
const PLANNED_KCAL_PER_KM = CALORIES_PER_KM;

/**
 * True when `route` is a shared, ownerless route — the canonical copy of one
 * run's path that every user who favourited that run references.
 *
 * Ownership is the discriminator rather than the presence of
 * `sourceSessionId`, because a route favourited under the pre-sharing scheme
 * is an *owned* copy that also carries that field.
 */
function isSharedRoute(route) {
  if (!route) return false;
  return route.userId === null || route.userId === undefined;
}

/**
 * The fields to write over a shared route to strip a deleted user's measured
 * performance off it, given the route's own stored distance.
 *
 * Keeps the geometry, the distance, and `startLocality` — those describe
 * where the route goes, and other users' favourites legitimately still need
 * them. Replaces the two values that describe how *that runner* performed,
 * and drops the pointer to their (also deleted) activity record.
 *
 * Returns plain values; the caller supplies whatever its Firestore layer uses
 * to delete a field.
 */
function anonymizedRouteStats(route) {
  const distanceKm = (Number(route && route.distanceMeters) || 0) / 1000;
  return {
    estimatedTimeMin: distanceKm * PLANNED_MIN_PER_KM,
    estimatedCalories: distanceKm * PLANNED_KCAL_PER_KM,
  };
}

/**
 * What to do with a route the deleted user owned: 'delete' or 'anonymize'.
 *
 * A non-public owned route is unreadable by anyone else (the read rule only
 * lets a non-owner through when `isPublic == true`), so preserving one keeps
 * a deleted user's personal data that nobody can ever see. Those are deleted.
 *
 * A genuinely public one is preserved as the original "published routes are
 * intentionally preserved" intent had it — but anonymized, so it survives as
 * an ownerless route rather than one still stamped with a deleted user's ID.
 */
function ownedRouteDisposition(route) {
  return route && route.isPublic === true ? "anonymize" : "delete";
}

module.exports = {
  PLANNED_MIN_PER_KM,
  PLANNED_KCAL_PER_KM,
  isSharedRoute,
  anonymizedRouteStats,
  ownedRouteDisposition,
};
