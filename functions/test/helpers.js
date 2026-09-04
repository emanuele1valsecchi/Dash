// Shared fixtures for the geo/territory suites.
//
// Squares are built in raw degrees, so a "halfSize 1" square is ~111 km on a
// side and its area runs to billions of m². That is deliberate: these tests
// are about the *relationships* between shapes (union, difference, who keeps
// what), and degree-sized squares keep the coordinates readable. Nothing here
// asserts a realistic running distance.

const turf = require('@turf/turf');
const geo = require('../geo');

/** An axis-aligned square centred on (cx, cy), in degrees. */
function square(cx, cy, halfSize) {
  return [
    {latitude: cy - halfSize, longitude: cx - halfSize},
    {latitude: cy - halfSize, longitude: cx + halfSize},
    {latitude: cy + halfSize, longitude: cx + halfSize},
    {latitude: cy + halfSize, longitude: cx - halfSize},
  ];
}

/** Shapes a `computeClaim` result back into a candidate for the next call. */
function candidateFromArea(id, userId, area, contributions, createdAtMillis) {
  return {
    id,
    userId,
    polygon: area.polygon,
    contributions: contributions || area.contributions,
    createdAtMillis: createdAtMillis != null ? createdAtMillis : area.earliestCreatedAtMillis,
  };
}

/** Ground enclosed by a raw loop, in m². */
function loopAreaM2(points) {
  return turf.area(geo.loopToTurfPolygon(points));
}

/** Ground held by a stored polygon field, in m². */
function storedAreaM2(polygon) {
  return turf.area(geo.storedPolygonToTurf(polygon));
}

/** A claim with the boilerplate filled in. */
function claim(overrides) {
  return geo.computeClaim({
    userId: 'A',
    sessionId: 's1',
    loopIndex: 0,
    candidates: [],
    sessionData: {durationMs: 600000, avgPaceMinPerKm: 6},
    now: 1000,
    ...overrides,
  });
}

module.exports = {
  square,
  candidateFromArea,
  loopAreaM2,
  storedAreaM2,
  claim,
  turf,
  geo,
};
