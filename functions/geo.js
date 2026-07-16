// Territory-claim geometry: polygon union/intersection/difference between a
// newly-closed running loop and whatever `claimedAreas` it overlaps.
//
// Deliberately has no Firestore/firebase-admin dependency — it's a pure
// function of (new loop, nearby existing areas) -> (writes to perform), so
// it can be unit-tested standalone (see verify_geo.js) without a live or
// emulated database. index.js wraps this in the actual transaction I/O.

const turf = require('@turf/turf');
const geofire = require('geofire-common');

const MAX_CONTRIBUTIONS = 10;

// ── Firestore <-> turf conversion ─────────────────────────────────────────
//
// Our stored `polygon` field is a MultiPolygon-with-holes encoded as an
// array of `{outer, holes}` maps — Firestore disallows directly nested
// arrays, so each ring level is wrapped in a map (same reason
// `runningSessions.closedLoops` wraps points in `{points: [...]}`).
// turf/GeoJSON coordinates are `[lng, lat]` — the opposite order from our
// GeoPoint-shaped points — easy to get backwards, so it's isolated here.

function geoPointsToRing(points) {
  const ring = points.map((p) => [p.longitude, p.latitude]);
  const first = ring[0];
  const last = ring[ring.length - 1];
  if (first[0] !== last[0] || first[1] !== last[1]) ring.push(first);
  return ring;
}

function ringToPoints(ring) {
  const isClosed = ring.length > 1 &&
    ring[0][0] === ring[ring.length - 1][0] &&
    ring[0][1] === ring[ring.length - 1][1];
  const openRing = isClosed ? ring.slice(0, -1) : ring;
  return openRing.map(([lng, lat]) => ({latitude: lat, longitude: lng}));
}

function loopToTurfPolygon(points) {
  return turf.polygon([geoPointsToRing(points)]);
}

function storedPolygonToTurf(polygonField) {
  const pieces = polygonField || [];
  if (pieces.length === 0) return null;
  const coords = pieces.map((piece) => {
    const rings = [geoPointsToRing(piece.outer)];
    (piece.holes || []).forEach((h) => rings.push(geoPointsToRing(h.points)));
    return rings;
  });
  return turf.multiPolygon(coords);
}

/** Converts a turf Polygon/MultiPolygon (Feature or bare geometry) back into
 * our stored format, as plain `{latitude, longitude}` points — the caller
 * (index.js) maps those to `admin.firestore.GeoPoint` so this module stays
 * free of a firebase-admin dependency. */
function turfToStoredPolygon(turfFeature) {
  if (!turfFeature) return [];
  const geom = turfFeature.geometry || turfFeature;
  let polys;
  if (geom.type === 'Polygon') polys = [geom.coordinates];
  else if (geom.type === 'MultiPolygon') polys = geom.coordinates;
  else return [];

  return polys
      .filter((rings) => rings[0] && rings[0].length >= 4) // drop degenerate slivers
      .map((rings) => ({
        outer: ringToPoints(rings[0]),
        holes: rings.slice(1).map((r) => ({points: ringToPoints(r)})),
      }));
}

function geohashForGeom(turfGeom) {
  const [lng, lat] = turf.centroid(turfGeom).geometry.coordinates;
  return geofire.geohashForLocation([lat, lng]);
}

/** Search radius (metres) generous enough to catch anything the new loop's
 * bounding box could plausibly overlap, scaled to the loop's own size
 * rather than a fixed constant — an unusually large loop shouldn't miss
 * candidates just outside a too-small fixed radius.
 *
 * The margin also has to cover the *existing* candidate's own extent, not
 * just the new loop's — an existing area that's already grown large through
 * several of a user's own merges has a geohash centroid that can legitimately
 * sit further from a small new loop than a tight margin would search. 5km is
 * generous for a running-scale game (a single contiguous claim spanning more
 * than that would be an unusually large one) without ballooning the query to
 * city-wide on every claim. */
function queryRadiusForGeom(turfGeom) {
  const bbox = turf.bbox(turfGeom);
  const diagonalM = turf.distance([bbox[0], bbox[1]], [bbox[2], bbox[3]], {units: 'meters'});
  return Math.max(diagonalM, 200) + 5000;
}

function geohashBoundsForLoop(points) {
  const geom = loopToTurfPolygon(points);
  const [lng, lat] = turf.centroid(geom).geometry.coordinates;
  return geofire.geohashQueryBounds([lat, lng], queryRadiusForGeom(geom));
}

// ── Core claim logic ──────────────────────────────────────────────────────
//
// [candidates] is every non-deleted `claimedAreas` doc the caller already
// fetched (via a geohash-bounded query) whose bounding box is near the new
// loop — this function does the precise intersection test itself, so a
// geohash false-positive (bbox nearby, shapes don't actually touch) is
// harmless.
//
// Two passes, deliberately in this order: all of the claiming user's own
// overlapping/touching areas are unioned into the new loop FIRST, so the
// final merged shape is what gets subtracted from other users' areas in the
// second pass — not the raw new loop before those merges. Skipping this
// ordering would let a same-owner merge that happens to also newly touch a
// second owner's area go unaccounted for.
//
// Returns `null` if the loop doesn't actually intersect anything (still a
// valid, common case — the caller creates a plain new area for it).
function computeClaim({newLoopPoints, userId, sessionId, loopIndex, candidates, sessionData, now}) {
  const areaId = `${sessionId}_${loopIndex}`;
  let mergedGeom = loopToTurfPolygon(newLoopPoints);
  let mergedContributions = [];
  let earliestCreatedAt = null;
  const deletes = [];
  const otherOwnerUpdates = [];

  // Pass 1: absorb the claiming user's own overlapping/touching areas.
  for (const c of candidates) {
    if (c.userId !== userId) continue;
    const existingGeom = storedPolygonToTurf(c.polygon);
    if (!existingGeom || !turf.booleanIntersects(mergedGeom, existingGeom)) continue;

    mergedGeom = turf.union(turf.featureCollection([mergedGeom, existingGeom]));
    mergedContributions = mergedContributions.concat(c.contributions || []);
    if (c.createdAtMillis != null && (earliestCreatedAt == null || c.createdAtMillis < earliestCreatedAt)) {
      earliestCreatedAt = c.createdAtMillis;
    }
    if (c.id !== areaId) deletes.push(c.id);
  }

  // Pass 2: subtract the final merged shape from every other owner's area
  // it overlaps.
  for (const c of candidates) {
    if (c.userId === userId) continue;
    const existingGeom = storedPolygonToTurf(c.polygon);
    if (!existingGeom || !turf.booleanIntersects(mergedGeom, existingGeom)) continue;

    const remaining = turf.difference(turf.featureCollection([existingGeom, mergedGeom]));
    if (!remaining) {
      otherOwnerUpdates.push({id: c.id, deleted: true});
    } else {
      otherOwnerUpdates.push({
        id: c.id,
        polygon: turfToStoredPolygon(remaining),
        geohash: geohashForGeom(remaining),
      });
    }
  }

  const newContribution = {
    sessionId,
    durationMs: (sessionData && sessionData.durationMs) || 0,
    avgPaceMinPerKm: (sessionData && sessionData.avgPaceMinPerKm) || null,
    conquestDateMillis: now,
  };
  mergedContributions = mergedContributions
      .concat([newContribution])
      .sort((a, b) => b.conquestDateMillis - a.conquestDateMillis)
      .slice(0, MAX_CONTRIBUTIONS);

  return {
    areaId,
    newArea: {
      userId,
      polygon: turfToStoredPolygon(mergedGeom),
      contributions: mergedContributions,
      startLocality: (sessionData && sessionData.startLocality) || null,
      geohash: geohashForGeom(mergedGeom),
      earliestCreatedAtMillis: earliestCreatedAt,
    },
    deletes,
    otherOwnerUpdates,
  };
}

module.exports = {
  loopToTurfPolygon,
  storedPolygonToTurf,
  turfToStoredPolygon,
  geohashForGeom,
  geohashBoundsForLoop,
  computeClaim,
  MAX_CONTRIBUTIONS,
};
