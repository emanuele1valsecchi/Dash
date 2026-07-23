// Curated "city" scoreboard territories — hand-drawn coverage polygons, not
// administrative boundaries (a metro area like Milano's commuter belt does
// not line up with real province/county lines — see the design discussion
// this came from). Point-in-polygon tested against a run's start coordinates
// by territory.js; nothing here talks to Firestore or the network.
//
// Deliberately a small hardcoded list rather than a Firestore collection for
// now — no extra read per claim, and there's nothing to curate yet beyond
// this placeholder. Migrate to a Firestore collection later if non-developer
// editing without a redeploy becomes worth the extra read.
//
// `boundary` is a single ring of {latitude, longitude} points (no holes,
// same point shape as geo.js's stored polygons) roughly tracing the
// metro/commuter area this city's scoreboard should cover — it does not need
// to close explicitly, callers treat it as a closed ring.

/**
 * ROUGH PLACEHOLDER, not surveyed data — a generous octagon around Milano
 * wide enough to demonstrate the city/broad-territory pipeline end to end
 * (e.g. it happens to cover Seregno, ~20km north of central Milano). Replace
 * with an actually-authored boundary (e.g. traced on geojson.io) before
 * relying on this for real scoreboard placement.
 */
const MILANO_PLACEHOLDER_BOUNDARY = [
  {latitude: 45.70, longitude: 9.19},
  {latitude: 45.62, longitude: 9.35},
  {latitude: 45.48, longitude: 9.40},
  {latitude: 45.35, longitude: 9.30},
  {latitude: 45.30, longitude: 9.15},
  {latitude: 45.38, longitude: 9.00},
  {latitude: 45.50, longitude: 8.95},
  {latitude: 45.62, longitude: 9.05},
];

module.exports = [
  {name: 'Milano', boundary: MILANO_PLACEHOLDER_BOUNDARY},
];
