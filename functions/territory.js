// Resolves which scoreboard territory a run's start point falls into.
//
// Two tiers, checked in order:
//   1. City — point-in-polygon against the small curated list in
//      cityTerritories.js. Pure, no network call.
//   2. Broad fallback (currently "Region", e.g. "Lombardia") — only reached
//      if no city matched, so nobody is ever left off every scoreboard.
//      Region and Country turn out to be the same lookup: a single Nominatim
//      reverse-geocode already returns both `address.state` and
//      `address.country`, so switching tiers is the one BROAD_TERRITORY_LEVEL
//      line below, not a different data source.
//
// Resolution always uses a run's actual GPS start coordinates, never the
// client-supplied `startLocality` string — territory now feeds a point
// system, so (like pointsEarned/area ownership) it must be server-derived.

const turf = require('@turf/turf');
const geo = require('./geo');
const CITY_TERRITORIES = require('./cityTerritories');

/**
 * Pure point-in-polygon city lookup — testable standalone (see
 * _verify_territory.js) the same way geo.js's computeClaim is.
 * @return {?string} the matched city's name, or null if none matched.
 */
function resolveCityTerritory(lat, lng, cities = CITY_TERRITORIES) {
  const point = turf.point([lng, lat]);
  for (const city of cities) {
    if (turf.booleanPointInPolygon(point, geo.loopToTurfPolygon(city.boundary))) {
      return city.name;
    }
  }
  return null;
}

// The one line to flip every future session's broad-tier scoreboard from
// Region to Country: both are just different keys in the same Nominatim
// `address` response below.
const BROAD_TERRITORY_LEVEL = 'state'; // 'state' (region) | 'country'

const NOMINATIM_TIMEOUT_MS = 8000;

/**
 * Best-effort reverse geocode of the broad (region/country) tier, via the
 * same Nominatim endpoint/User-Agent convention as the client's own
 * startLocality lookup in run_session_repository.dart. Never throws — a
 * session should still get its distance/area XP even if Nominatim is
 * unreachable, same spirit as that client-side call.
 * @return {!Promise<{name: ?string, type: string}>}
 */
async function fetchBroadTerritory(lat, lng) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), NOMINATIM_TIMEOUT_MS);
  try {
    const uri = `https://nominatim.openstreetmap.org/reverse` +
      `?lat=${lat}&lon=${lng}&format=json&zoom=10&addressdetails=1`;
    const response = await fetch(uri, {
      headers: {'User-Agent': 'DashApp/1.0'},
      signal: controller.signal,
    });
    if (!response.ok) return {name: null, type: BROAD_TERRITORY_LEVEL};

    const data = await response.json();
    const name = (data.address && data.address[BROAD_TERRITORY_LEVEL]) || null;
    return {name, type: BROAD_TERRITORY_LEVEL};
  } catch (e) {
    return {name: null, type: BROAD_TERRITORY_LEVEL};
  } finally {
    clearTimeout(timeout);
  }
}

/**
 * @return {!Promise<{city: ?string, broad: ?string, broadType: ?string}>}
 */
async function resolveTerritory(lat, lng) {
  const city = resolveCityTerritory(lat, lng);
  if (city) return {city, broad: null, broadType: null};

  const {name, type} = await fetchBroadTerritory(lat, lng);
  return {city: null, broad: name, broadType: type};
}

module.exports = {
  resolveCityTerritory,
  fetchBroadTerritory,
  resolveTerritory,
  BROAD_TERRITORY_LEVEL,
};
