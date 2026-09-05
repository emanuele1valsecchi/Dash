const {test, describe} = require('node:test');
const assert = require('node:assert');

const territory = require('../territory');
const realCities = require('../cityTerritories');
const {square} = require('./helpers');

// Which city a run counts towards decides which leaderboard it lands on, so a
// wrong answer here quietly files someone's run under the wrong city — or
// under none, dropping them off the local board entirely.
//
// Ported from `_verify_territory.js`. `fetchBroadTerritory` is deliberately
// still out of scope: it calls the live Nominatim API, which makes it an
// integration check rather than something a unit suite should depend on.

describe('resolveCityTerritory', () => {
  const cities = [{name: 'TestCity', boundary: square(0, 0, 1)}];

  test('a point inside a city boundary resolves to that city', () => {
    assert.strictEqual(territory.resolveCityTerritory(0, 0, cities), 'TestCity');
  });

  test('a point outside every boundary resolves to null', () => {
    // null is not a failure — it is the signal to fall through to the broad
    // (state/country) tier.
    assert.strictEqual(territory.resolveCityTerritory(10, 10, cities), null);
  });

  test('just inside the edge counts, just outside does not', () => {
    assert.strictEqual(territory.resolveCityTerritory(0.99, 0, cities), 'TestCity');
    assert.strictEqual(territory.resolveCityTerritory(1.01, 0, cities), null);
  });

  test('an empty city list resolves to null rather than throwing', () => {
    // Reachable if the bundled boundary files ever fail to load.
    assert.strictEqual(territory.resolveCityTerritory(0, 0, []), null);
  });
});

describe('the bundled city boundaries', () => {
  test('are loaded and non-empty', () => {
    // `cityTerritories.js` reads GeoJSON off disk at require time; if the
    // files stop shipping, every run silently falls through to the broad tier
    // and the city leaderboards go empty.
    assert.ok(Array.isArray(realCities));
    assert.ok(realCities.length > 0, 'no city boundaries were loaded');
    for (const city of realCities) {
      assert.ok(city.name, 'every city needs a name');
      assert.ok(Array.isArray(city.boundary) && city.boundary.length >= 3,
          `${city.name} has no usable boundary ring`);
    }
  });

  test("Milano's boundary covers both Milano and Seregno", () => {
    // From the original design discussion: the placeholder boundary is
    // deliberately wide enough to take in the surrounding comuni, so runs
    // just outside the city proper still reach a leaderboard.
    assert.strictEqual(
        territory.resolveCityTerritory(45.4642, 9.1900, realCities), 'Milano');
    assert.strictEqual(
        territory.resolveCityTerritory(45.6603, 9.2035, realCities), 'Milano');
  });

  test('somewhere far outside every bundled city resolves to null', () => {
    // Reykjavík — no bundled boundary should claim it.
    assert.strictEqual(
        territory.resolveCityTerritory(64.1466, -21.9426, realCities), null);
  });
});

describe('BROAD_TERRITORY_LEVEL', () => {
  test('is one of the two values the Nominatim lookup understands', () => {
    assert.ok(['state', 'country'].includes(territory.BROAD_TERRITORY_LEVEL),
        `unexpected level '${territory.BROAD_TERRITORY_LEVEL}'`);
  });
});
