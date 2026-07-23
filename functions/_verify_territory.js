// Standalone check of territory.js's city point-in-polygon resolution. Run
// with `node _verify_territory.js`. Not part of the deployed function —
// mirrors the _verify_geo.js convention. fetchBroadTerritory hits the real
// Nominatim API, so it's a manual/integration check, not covered here.

const assert = require('assert');
const territory = require('./territory');
const realCities = require('./cityTerritories');

function square(cx, cy, halfSize) {
  return [
    {latitude: cy - halfSize, longitude: cx - halfSize},
    {latitude: cy - halfSize, longitude: cx + halfSize},
    {latitude: cy + halfSize, longitude: cx + halfSize},
    {latitude: cy + halfSize, longitude: cx - halfSize},
  ];
}

// ── 1. Point inside a synthetic city polygon resolves to that city ────────
{
  const cities = [{name: 'TestCity', boundary: square(0, 0, 1)}];
  const name = territory.resolveCityTerritory(0, 0, cities);
  assert.strictEqual(name, 'TestCity');
  console.log('1. point inside city polygon: OK');
}

// ── 2. Point outside every city polygon resolves to null (falls through to
//       the broad tier, not tested here since that's a network call) ──────
{
  const cities = [{name: 'TestCity', boundary: square(0, 0, 1)}];
  const name = territory.resolveCityTerritory(10, 10, cities);
  assert.strictEqual(name, null);
  console.log('2. point outside every city polygon -> null: OK');
}

// ── 3. Nearest candidate to the boundary edge still resolves correctly ────
{
  const cities = [{name: 'TestCity', boundary: square(0, 0, 1)}];
  assert.strictEqual(territory.resolveCityTerritory(0.99, 0, cities), 'TestCity');
  assert.strictEqual(territory.resolveCityTerritory(1.01, 0, cities), null);
  console.log('3. just inside/outside the boundary edge: OK');
}

// ── 4. The real (placeholder) Milano boundary actually covers both Milano's
//       own centroid and Seregno, per the design discussion this came from ─
{
  // lat, lng order matches resolveCityTerritory's own signature.
  const milanoCentroid = [45.4642, 9.1900];
  const seregno = [45.6603, 9.2035];
  assert.strictEqual(territory.resolveCityTerritory(...milanoCentroid, realCities), 'Milano');
  assert.strictEqual(territory.resolveCityTerritory(...seregno, realCities), 'Milano');
  console.log('4. placeholder Milano boundary covers Milano + Seregno: OK');
}

// ── 5. BROAD_TERRITORY_LEVEL is a valid, single swappable value ───────────
{
  assert.ok(['state', 'country'].includes(territory.BROAD_TERRITORY_LEVEL));
  console.log(`5. BROAD_TERRITORY_LEVEL is '${territory.BROAD_TERRITORY_LEVEL}': OK`);
}

console.log('\nAll scenarios passed.');
