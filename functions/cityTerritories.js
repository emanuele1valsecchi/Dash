// Curated "city" scoreboard territories — hand-drawn coverage polygons, not
// administrative boundaries (a metro area like Milano's commuter belt does
// not line up with real province/county lines — see the design discussion
// this came from). Point-in-polygon tested against a run's start coordinates
// by territory.js; nothing here talks to Firestore or the network.
//
// ── How to add a new city ──────────────────────────────────────────────
// 1. Draw the coverage shape at https://geojson.io (roughly trace the
//    metro/commuter area, not an administrative boundary).
// 2. Save/export as GeoJSON, drop the file into functions/cities/ as
//    <name>.geojson (e.g. torino.geojson) — the filename becomes the
//    city's display/match name (title-cased) unless the shape's own
//    GeoJSON `properties.name` says otherwise, so there's no need to touch
//    geojson.io's properties panel for the common case.
// 3. Redeploy functions. No code changes needed.
//
// Deliberately files on disk rather than a Firestore collection — no extra
// read per claim, keeps each city's diff isolated instead of one shared
// array growing forever as more cities are authored, and geojson.io's own
// export format needs zero hand-transcription into a different shape.
// Migrate to a Firestore collection later if non-developer editing without a
// redeploy becomes worth the extra read.

const fs = require('fs');
const path = require('path');

const CITIES_DIR = path.join(__dirname, 'cities');

/** A GeoJSON Polygon's outer ring ([lng, lat] pairs) converted to our
 * internal {latitude, longitude} point list — the same shape geo.js's
 * stored polygons use. Holes, if any, are ignored: a coverage boundary has
 * no reason to have one. */
function polygonToBoundary(geometry) {
  return geometry.coordinates[0].map(([lng, lat]) => ({latitude: lat, longitude: lng}));
}

/** "torino.geojson" -> "Torino"; "san-donato.geojson" -> "San Donato" — the
 * default display/match name when a shape doesn't set its own
 * properties.name, so authoring a city is just "draw, export, save as
 * <name>.geojson" with no need to touch geojson.io's properties panel. */
function titleCaseFromFilename(file) {
  return path
      .basename(file, '.geojson')
      .replace(/[-_]+/g, ' ')
      .trim()
      .replace(/\b\w/g, (c) => c.toUpperCase());
}

/** Reads every functions/cities/*.geojson file once at module load (cities
 * only change via a redeploy anyway, so there's nothing to gain from
 * re-reading per invocation) and flattens them into the flat {name,
 * boundary} list territory.js expects. Each file may be a single Feature or
 * a FeatureCollection (geojson.io exports either, depending on version). */
function loadCities() {
  const files = fs.readdirSync(CITIES_DIR).filter((f) => f.endsWith('.geojson'));
  const cities = [];

  for (const file of files) {
    const parsed = JSON.parse(fs.readFileSync(path.join(CITIES_DIR, file), 'utf8'));
    const features = parsed.type === 'FeatureCollection' ? parsed.features : [parsed];

    for (const feature of features) {
      if (!feature.geometry || feature.geometry.type !== 'Polygon') continue;
      const name = (feature.properties && feature.properties.name) || titleCaseFromFilename(file);
      cities.push({name, boundary: polygonToBoundary(feature.geometry)});
    }
  }

  return cities;
}

module.exports = loadCities();
