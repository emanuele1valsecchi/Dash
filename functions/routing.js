// Server-side proxy for the OpenRouteService (ORS) foot-walking API.
//
// Why this exists: RoutingService used to embed the ORS API key directly in
// the compiled Dart app (a trivially-extractable, shared-quota secret — see
// CLAUDE.md's "Known security debt"). This callable moves the key behind
// Cloud Functions, where it's held in Secret Manager and never shipped to a
// device. The client (lib/services/routing_service.dart) now calls this
// instead of api.openrouteservice.org directly.
//
// Deliberately a thin proxy, not a reimplementation: it forwards ORS's own
// HTTP status + JSON body back to the client verbatim (as {status, body}),
// so the existing client-side parsing, 429/RoutingRateLimitedException
// handling, and debugPrint diagnostics in routing_service.dart keep working
// unchanged — only the transport (direct HTTP -> callable) changed. An
// HttpsError is only thrown when the proxy itself can't reach ORS at all
// (network failure/timeout), which routing_service.dart's existing
// catch-all already treats the same as any other unreachable-API failure.

const {onCall, HttpsError} = require('firebase-functions/v2/https');
const {defineSecret} = require('firebase-functions/params');

const ORS_API_KEY = defineSecret('ORS_API_KEY');
const ORS_TIMEOUT_MS = 12000;

/**
 * @param {number} lat
 * @param {number} lng
 * @return {boolean}
 */
function isValidLatLng(lat, lng) {
  return typeof lat === 'number' && typeof lng === 'number' &&
    Number.isFinite(lat) && Number.isFinite(lng) &&
    lat >= -90 && lat <= 90 && lng >= -180 && lng <= 180;
}

exports.orsRoute = onCall(
  {region: 'europe-west1', secrets: [ORS_API_KEY]},
  async (request) => {
    // Routing quota is a shared, rate-limited resource (see CLAUDE.md) —
    // gating on sign-in (already required to use the rest of the app) keeps
    // an anonymous/scripted caller from draining it for free.
    if (!request.auth) {
      throw new HttpsError('unauthenticated', 'Sign-in required.');
    }

    const data = request.data || {};
    const {origin, destination, mode} = data;
    if (
      !origin || !destination ||
      !isValidLatLng(origin.lat, origin.lng) ||
      !isValidLatLng(destination.lat, destination.lng)
    ) {
      throw new HttpsError('invalid-argument', 'origin/destination lat/lng required.');
    }

    const apiKey = ORS_API_KEY.value();

    try {
      if (mode === 'alternatives') {
        const targetCount = Number.isInteger(data.targetCount) ? data.targetCount : 3;
        return await fetchAlternatives(apiKey, origin, destination, targetCount);
      }
      return await fetchRoute(apiKey, origin, destination);
    } catch (e) {
      console.error('orsRoute: failed to reach ORS', e);
      throw new HttpsError('unavailable', 'Could not reach routing service.');
    }
  }
);

/** Mirrors the GET foot-walking endpoint routing_service.dart used to call directly. */
async function fetchRoute(apiKey, origin, destination) {
  const uri = 'https://api.openrouteservice.org/v2/directions/foot-walking' +
    `?api_key=${apiKey}` +
    `&start=${origin.lng},${origin.lat}` +
    `&end=${destination.lng},${destination.lat}`;

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), ORS_TIMEOUT_MS);
  try {
    const response = await fetch(uri, {signal: controller.signal});
    const body = await response.json().catch(() => null);
    return {status: response.status, body};
  } finally {
    clearTimeout(timeout);
  }
}

/** Mirrors the POST foot-walking/geojson endpoint (alternative routes). */
async function fetchAlternatives(apiKey, origin, destination, targetCount) {
  const uri = 'https://api.openrouteservice.org/v2/directions/foot-walking/geojson';
  const body = JSON.stringify({
    coordinates: [
      [origin.lng, origin.lat],
      [destination.lng, destination.lat],
    ],
    alternative_routes: {
      share_factor: 0.6,
      target_count: targetCount,
      weight_factor: 1.4,
    },
  });

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), ORS_TIMEOUT_MS);
  try {
    const response = await fetch(uri, {
      method: 'POST',
      headers: {
        'Authorization': apiKey,
        'Content-Type': 'application/json; charset=UTF-8',
        'Accept': 'application/json, application/geo+json',
      },
      body,
      signal: controller.signal,
    });
    const responseBody = await response.json().catch(() => null);
    return {status: response.status, body: responseBody};
  } finally {
    clearTimeout(timeout);
  }
}
