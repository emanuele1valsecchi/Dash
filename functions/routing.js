// Server-side proxy for the routing backends used by the app.
//
// Two callables live here:
//
//  - `orsRoute` — the original thin proxy for OpenRouteService (ORS)
//    foot-walking requests: point-to-point (GET), alternatives (POST), and
//    native round trips (POST with `options.round_trip` — see
//    fetchRoundTrip, used by route search's closed-circuit generation).
//    Why it exists: RoutingService used to embed
//    the ORS API key directly in the compiled Dart app (a trivially-
//    extractable, shared-quota secret). This callable moves the key behind
//    Cloud Functions, where it's
//    held in Secret Manager and never shipped to a device. Deliberately a
//    thin proxy, not a reimplementation: it forwards ORS's own HTTP status +
//    JSON body back to the client verbatim (as {status, body}), so the
//    existing client-side parsing, 429/RoutingRateLimitedException handling,
//    and debugPrint diagnostics in routing_service.dart keep working
//    unchanged. An HttpsError is only thrown when the proxy itself can't
//    reach ORS at all (network failure/timeout).
//
//  - `matchDrawnPath` — converts a whole freehand-drawn stroke into one
//    road-snapped walking route in a SINGLE upstream operation, replacing
//    the old client-side chain of 15–90 sequential point-to-point `orsRoute`
//    calls per stroke (which is what exhausted the shared ORS quota: the
//    free plan's minutely limit answers 429, but the *daily* limit answers
//    403 — a status the old per-hop pipeline treated as an ordinary failure
//    and amplified with retries/skip-ahead). Unlike `orsRoute` this endpoint
//    does NOT forward upstream responses verbatim: it normalizes them, so
//    the client has one parser and one error taxonomy regardless of which
//    backend served the request, and the backend can be switched here with a
//    function deploy — no app release.
//
//    Request-count bound per drawn stroke (documented, enforced by code):
//      backend 'valhalla' → at most 3 upstream calls (2 map-matching
//                           attempts at widening tolerance + 1 corner-
//                           routing fallback for coarse, low-zoom strokes);
//      backend 'ors'      → exactly 1 upstream call (corner routing).
//    Nothing in this file ever fabricates geometry: if no walkable match
//    exists, the caller gets an explicit `no_route`, never a straight line.
//
// Every upstream call is logged as one structured JSON line
// (tag: "routing-upstream") including the HTTP status and — for ORS — the
// x-ratelimit-remaining / x-ratelimit-reset headers, so quota incidents can
// be diagnosed from Cloud Logging with real numbers instead of guessing.

const {onCall, HttpsError} = require('firebase-functions/v2/https');
const {defineSecret} = require('firebase-functions/params');

const ORS_API_KEY = defineSecret('ORS_API_KEY');
// `fetchRoute`/`fetchAlternatives` (the `orsRoute` callable's two modes,
// used by both route creation and route search) both wait up to this long
// for ORS before giving up. IMPORTANT: the CLIENT-side callable timeouts in
// lib/services/routing_service.dart (`fetchRoute`/`fetchAlternatives`'s own
// `HttpsCallableOptions(timeout: ...)`) must stay comfortably ABOVE this
// value. If the client gives up first, it throws before this function ever
// gets a chance to return a real (if slow) result — the client then treats
// that timeout identically to "ORS found no route", which is
// indistinguishable from a genuine failure and was the root cause of
// closed-circuit route search failing outright on longer legs (worked at
// ~3 km, returned nothing at 10 km) while looking like an algorithm bug.
const ORS_TIMEOUT_MS = 12000;

// Public-API cap on `options.round_trip.length` — the "Distance
// (alternative & round trip)" limit on openrouteservice.org/restrictions
// is 100 km. Requests above it would only burn quota on a guaranteed 4xx.
const ORS_MAX_ROUND_TRIP_METERS = 100000;

// ── matchDrawnPath tunables ──────────────────────────────────────────────────

/**
 * Which backend `matchDrawnPath` uses when the client doesn't ask for one
 * explicitly. Flip to 'ors' to stay entirely on OpenRouteService (multi-
 * waypoint directions with continue_straight — no true map matching, so a
 * stray sample can still drag the route briefly onto a side lane, but zero
 * new external dependencies). 'valhalla' performs real map matching
 * (trace_route, pedestrian costing) on the FOSSGIS community instance.
 */
const DEFAULT_MATCH_BACKEND = 'valhalla';

/**
 * FOSSGIS e.V. public Valhalla instance (full-planet graph, OSM data).
 * Fair-use policy applies: no SLA, rate-limited (announced at launch as
 * 1 req/s per user, 100 req/s total). Their README asks apps published to
 * end users to (a) send an identifying X-Client-Id header and (b) announce
 * themselves on the Valhalla GitHub Discussions — do both before shipping,
 * and set the real app identifier below.
 */
const VALHALLA_BASE_URL = 'https://valhalla1.openstreetmap.de';
const VALHALLA_CLIENT_ID = 'dash-app'; // TODO: set the real app id before release
const VALHALLA_TIMEOUT_MS = 12000;

/**
 * Hard cap on trace points sent to Valhalla. The FOSSGIS instance runs
 * "service limits a bit stricter than the defaults" without publishing the
 * numbers — 1500 has margin against the engine default and keeps request
 * bodies small. If the instance ever rejects on shape size, lower this.
 */
const VALHALLA_MAX_SHAPE_POINTS = 1500;

/**
 * Matching quality knobs, tuned for "simple loop" over "faithful trace".
 * A finger stroke is NOT a GPS trace: it wobbles by 10–30 m at drawing
 * zoom, exactly the scale of driveways, parking aisles and dead-end stubs.
 * Declaring a high `gps_accuracy` tells the HMM matcher to treat every
 * point as a rough hint, so the road-plausibility (transition) costs win
 * over hugging each wobble — which is what stops "enter the side street
 * for 30 m and come straight back" matches. `turn_penalty_factor` is
 * Valhalla's own documented cure for back-and-forth on pedestrian traces;
 * raising it much beyond 500 starts fighting the loop's *real* corners.
 */
const VALHALLA_ATTEMPTS = [
  {search_radius: 40, gps_accuracy: 30},
  {search_radius: 75, gps_accuracy: 50},
];
const VALHALLA_TURN_PENALTY_FACTOR = 500;

/**
 * Pedestrian costing penalties applied during matching (and equally valid
 * for plain routing). Defaults are alley_factor 2.0 / driveway_factor 5.0
 * / service_factor 1.0 — raised here so parking aisles, driveways, alleys
 * and other service roads become expensive enough that the matcher only
 * enters them when the stroke unmistakably does (a drawn loop should trace
 * streets and paths, not cut through a supermarket parking lot).
 */
const PEDESTRIAN_COSTING_OPTIONS = {
  service_penalty: 15,
  service_factor: 8,
  driveway_factor: 15,
  alley_factor: 5,
};

/**
 * Centered moving-average window (points, odd) applied to the decimated
 * stroke before matching. At ~5 m point spacing a window of 5 averages
 * over ~±10 m — enough to erase finger jitter near junctions (the seed of
 * spurious side-street pokes) while real corners, tens of metres wide,
 * survive with a small rounding the matcher easily absorbs.
 */
const MATCH_SMOOTHING_WINDOW = 5;

/**
 * Post-match spur removal: an out-and-back poke (dead-end street, parking
 * aisle loop-in, "walk 30 m up a road and turn around") retraces the same
 * edge geometry, so it shows up as a palindrome in the matched polyline —
 * detectable and removable deterministically, whatever the matcher did.
 * Pokes contribute zero claimable area, only distance and ugliness, so
 * cutting them is aligned with the product. Spurs longer than the cap
 * (one-way) are kept, in case the user genuinely drew an out-and-back leg.
 */
const BACKTRACK_TOLERANCE_METERS = 10;
const BACKTRACK_MAX_SPUR_METERS = 400;

/**
 * Corner-routing fallback: when map matching can't read the sketch at any
 * tolerance (typical of strokes drawn at low zoom, where the finger sits
 * 50–150 m off the roads while the public server caps the matcher's
 * search_radius at 100 m), the stroke is reduced to its CORNERS
 * (escalating-tolerance Douglas-Peucker) and routed through them instead.
 * Plain routing snaps each corner to the nearest walkable edge with a
 * generous cutoff — no 100 m ceiling — so it works at any drawing zoom,
 * and by construction it yields the simplest path between the corners.
 * Interior corners use type 'via' (U-turn allowed) rather than 'through':
 * a bad snap with 'via' costs at worst a small in-and-out spike, which
 * `removeBacktrackSpurs` then deletes, while 'through' would force a
 * non-removable detour around the block.
 */
const CORNER_EPSILONS_METERS = [18, 28, 45, 70, 110, 170];
const CORNER_MAX_POINTS = 12;

/**
 * Documented public-API cap on waypoints per ORS directions request —
 * kept as the hard ceiling, though the 'ors' backend now targets
 * CORNER_MAX_POINTS corners (see matchWithOrs) and stays far below it.
 */
const ORS_MAX_ROUTE_WAYPOINTS = 50;

/** Points closer together than this add noise, not shape — drop them. */
const MATCH_MIN_SPACING_METERS = 5;

/** Upper bound on points accepted from the client (payload sanity). */
const MATCH_MAX_INPUT_POINTS = 4000;

// ── Shared helpers ───────────────────────────────────────────────────────────

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

/**
 * One structured line per upstream HTTP call — greppable in Cloud Logging
 * (jsonPayload/textPayload contains `"tag":"routing-upstream"`).
 * @param {string} upstream
 * @param {Object} fields
 */
function logUpstream(upstream, fields) {
  console.log(JSON.stringify({tag: 'routing-upstream', upstream, ...fields}));
}

/**
 * fetch() with an AbortController timeout — same pattern the original
 * handlers used, factored out.
 * @param {string} uri
 * @param {Object} options
 * @param {number} timeoutMs
 * @return {Promise<Response>}
 */
async function fetchWithTimeout(uri, options, timeoutMs) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);
  try {
    return await fetch(uri, {...options, signal: controller.signal});
  } finally {
    clearTimeout(timeout);
  }
}

/**
 * @param {Response} response
 * @return {number|undefined} Retry-After in seconds, when parseable.
 */
function parseRetryAfterSeconds(response) {
  const raw = response.headers.get('retry-after');
  const n = raw ? parseInt(raw, 10) : NaN;
  return Number.isFinite(n) && n >= 0 ? n : undefined;
}

/**
 * @param {{lat: number, lng: number}} a
 * @param {{lat: number, lng: number}} b
 * @return {number} great-circle distance in metres.
 */
function haversineMeters(a, b) {
  const R = 6371000;
  const toRad = (d) => d * Math.PI / 180;
  const dLat = toRad(b.lat - a.lat);
  const dLng = toRad(b.lng - a.lng);
  const s = Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(a.lat)) * Math.cos(toRad(b.lat)) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(Math.min(1, s)));
}

/**
 * Drops points closer than [minSpacingMeters] to the previously kept one.
 * First and last points are always kept.
 * @param {Array<{lat: number, lng: number}>} points
 * @param {number} minSpacingMeters
 * @return {Array<{lat: number, lng: number}>}
 */
function decimateMinSpacing(points, minSpacingMeters) {
  if (points.length <= 2) return points.slice();
  const kept = [points[0]];
  for (let i = 1; i < points.length - 1; i++) {
    if (haversineMeters(kept[kept.length - 1], points[i]) >= minSpacingMeters) {
      kept.push(points[i]);
    }
  }
  kept.push(points[points.length - 1]);
  return kept;
}

/**
 * Uniform-stride reduction to at most [maxCount] points (endpoints kept).
 * @param {Array<{lat: number, lng: number}>} points
 * @param {number} maxCount
 * @return {Array<{lat: number, lng: number}>}
 */
function capPointCount(points, maxCount) {
  if (points.length <= maxCount) return points;
  const out = [];
  for (let i = 0; i < maxCount; i++) {
    out.push(points[Math.round(i * (points.length - 1) / (maxCount - 1))]);
  }
  return out;
}

/**
 * Perpendicular distance (metres) from point p to segment a-b, on a local
 * equirectangular projection — accurate at city scale, which is all a
 * finger-drawn stroke ever spans.
 * @param {{lat: number, lng: number}} p
 * @param {{lat: number, lng: number}} a
 * @param {{lat: number, lng: number}} b
 * @return {number}
 */
function pointToSegmentMeters(p, a, b) {
  const mPerDegLat = 111320;
  const mPerDegLng = 111320 * Math.cos(a.lat * Math.PI / 180);
  const bx = (b.lng - a.lng) * mPerDegLng;
  const by = (b.lat - a.lat) * mPerDegLat;
  const px = (p.lng - a.lng) * mPerDegLng;
  const py = (p.lat - a.lat) * mPerDegLat;
  const len2 = bx * bx + by * by;
  if (len2 === 0) return Math.hypot(px, py);
  let t = (px * bx + py * by) / len2;
  t = Math.max(0, Math.min(1, t));
  return Math.hypot(px - t * bx, py - t * by);
}

/**
 * Ramer–Douglas–Peucker simplification with a metre tolerance (iterative,
 * so a long stroke can't blow the stack). Keeps corners — which on a
 * road-following stroke sit on the road — and discards straightaway
 * in-between points, which is why it beats the old uniform 40 m sampling
 * whose equispaced points landed on parking aisles at random.
 * @param {Array<{lat: number, lng: number}>} points
 * @param {number} epsilonMeters
 * @return {Array<{lat: number, lng: number}>}
 */
function rdpSimplify(points, epsilonMeters) {
  if (points.length <= 2) return points.slice();
  const keep = new Array(points.length).fill(false);
  keep[0] = keep[points.length - 1] = true;
  const stack = [[0, points.length - 1]];
  while (stack.length > 0) {
    const [s, e] = stack.pop();
    if (e <= s + 1) continue;
    let maxDist = -1;
    let maxIdx = -1;
    for (let i = s + 1; i < e; i++) {
      const d = pointToSegmentMeters(points[i], points[s], points[e]);
      if (d > maxDist) {
        maxDist = d;
        maxIdx = i;
      }
    }
    if (maxDist > epsilonMeters) {
      keep[maxIdx] = true;
      stack.push([s, maxIdx], [maxIdx, e]);
    }
  }
  return points.filter((_, i) => keep[i]);
}

/**
 * Centered moving-average smoothing of a {lat,lng} path; endpoints pinned.
 * See MATCH_SMOOTHING_WINDOW for why this exists.
 * @param {Array<{lat: number, lng: number}>} points
 * @param {number} windowSize odd number of points
 * @return {Array<{lat: number, lng: number}>}
 */
function smoothPath(points, windowSize) {
  if (points.length <= 2 || windowSize < 3) return points.slice();
  const half = Math.floor(windowSize / 2);
  const out = [points[0]];
  for (let i = 1; i < points.length - 1; i++) {
    let latSum = 0;
    let lngSum = 0;
    let count = 0;
    const from = Math.max(0, i - half);
    const to = Math.min(points.length - 1, i + half);
    for (let j = from; j <= to; j++) {
      latSum += points[j].lat;
      lngSum += points[j].lng;
      count++;
    }
    out.push({lat: latSum / count, lng: lngSum / count});
  }
  out.push(points[points.length - 1]);
  return out;
}

/**
 * @param {[number, number]} a [lat, lng]
 * @param {[number, number]} b [lat, lng]
 * @return {number} metres.
 */
function pairDistanceMeters(a, b) {
  return haversineMeters({lat: a[0], lng: a[1]}, {lat: b[0], lng: b[1]});
}

/**
 * @param {Array<[number, number]>} polyline
 * @return {number} total length in metres.
 */
function pairPathLengthMeters(polyline) {
  let total = 0;
  for (let i = 1; i < polyline.length; i++) {
    total += pairDistanceMeters(polyline[i - 1], polyline[i]);
  }
  return total;
}

/**
 * Finds the first out-and-back spur: an apex index i with a maximal
 * symmetric span s such that every outbound vertex p[i-k] is within
 * [toleranceMeters] of its returning twin p[i+k] — which is exactly what
 * retracing the same OSM edge geometry produces. Spurs whose one-way
 * length exceeds [maxSpurMeters] are ignored (possibly deliberate).
 * @param {Array<[number, number]>} pts
 * @param {number} toleranceMeters
 * @param {number} maxSpurMeters
 * @return {{start: number, end: number}|null} inclusive removal range.
 */
function findBacktrackSpur(pts, toleranceMeters, maxSpurMeters) {
  for (let i = 1; i < pts.length - 1; i++) {
    if (pairDistanceMeters(pts[i - 1], pts[i + 1]) > toleranceMeters) continue;
    let s = 1;
    while (i - (s + 1) >= 0 && i + (s + 1) <= pts.length - 1 &&
           pairDistanceMeters(pts[i - (s + 1)], pts[i + (s + 1)]) <=
             toleranceMeters) {
      s++;
    }
    let oneWayMeters = 0;
    for (let k = i - s; k < i; k++) {
      oneWayMeters += pairDistanceMeters(pts[k], pts[k + 1]);
    }
    if (oneWayMeters > maxSpurMeters) continue;
    // Keep the outbound junction vertex p[i-s]; drop everything through its
    // returning twin p[i+s]. The path then continues p[i-s] -> p[i+s+1],
    // which is (within tolerance) the original continuation edge.
    return {start: i - s + 1, end: i + s};
  }
  return null;
}

/**
 * Removes every detected out-and-back spur (see `findBacktrackSpur`),
 * iterating so that nested spurs unwind too. Falls back to the input if
 * removal would degenerate the geometry — a broken route is worse than an
 * ugly one.
 * @param {Array<[number, number]>} polyline
 * @param {number} toleranceMeters
 * @param {number} maxSpurMeters
 * @return {Array<[number, number]>}
 */
function removeBacktrackSpurs(polyline, toleranceMeters, maxSpurMeters) {
  let pts = polyline;
  for (let pass = 0; pass < 20; pass++) {
    const spur = findBacktrackSpur(pts, toleranceMeters, maxSpurMeters);
    if (!spur) break;
    pts = pts.slice(0, spur.start).concat(pts.slice(spur.end + 1));
  }
  const degenerate = pts.length < 2 || pairPathLengthMeters(pts) < 20;
  return degenerate ? polyline : pts;
}

/**
 * Concatenates and decodes every leg shape of a Valhalla trip into one
 * [lat, lng] polyline (consecutive duplicates dropped).
 * @param {Object} trip
 * @return {Array<[number, number]>}
 */
function decodeTripPolyline(trip) {
  const legs = Array.isArray(trip.legs) ? trip.legs : [];
  const polyline = [];
  for (const leg of legs) {
    if (typeof leg.shape !== 'string') continue;
    for (const c of decodePolyline(leg.shape, 6)) {
      const prev = polyline[polyline.length - 1];
      if (!prev || prev[0] !== c[0] || prev[1] !== c[1]) polyline.push(c);
    }
  }
  return polyline;
}

/**
 * Normalized success response: spur cleanup + distance measured on the
 * FINAL geometry, shared by every backend/strategy.
 * @param {string} backend
 * @param {string} strategy informational (shows up in logs/clients that care)
 * @param {Array<[number, number]>} polyline
 * @return {Object}
 */
function okResult(backend, strategy, polyline) {
  const cleaned = removeBacktrackSpurs(
    polyline, BACKTRACK_TOLERANCE_METERS, BACKTRACK_MAX_SPUR_METERS);
  return {
    status: 'ok',
    backend,
    strategy,
    polyline: cleaned,
    distanceMeters: Math.round(pairPathLengthMeters(cleaned)),
  };
}

/**
 * Decodes a Google-encoded polyline. Valhalla shapes use 1e-6 precision
 * ("polyline6"), unlike the more common 1e-5.
 * @param {string} encoded
 * @param {number} precision
 * @return {Array<[number, number]>} [lat, lng] pairs.
 */
function decodePolyline(encoded, precision) {
  const factor = Math.pow(10, precision);
  const coords = [];
  let index = 0;
  let lat = 0;
  let lng = 0;
  while (index < encoded.length) {
    let result = 0;
    let shift = 0;
    let byte;
    do {
      byte = encoded.charCodeAt(index++) - 63;
      result |= (byte & 0x1f) << shift;
      shift += 5;
    } while (byte >= 0x20);
    lat += (result & 1) ? ~(result >> 1) : (result >> 1);
    result = 0;
    shift = 0;
    do {
      byte = encoded.charCodeAt(index++) - 63;
      result |= (byte & 0x1f) << shift;
      shift += 5;
    } while (byte >= 0x20);
    lng += (result & 1) ? ~(result >> 1) : (result >> 1);
    coords.push([lat / factor, lng / factor]);
  }
  return coords;
}

// ── orsRoute (unchanged behavior + upstream logging) ─────────────────────────

exports.orsRoute = onCall(
  {region: 'europe-west1', secrets: [ORS_API_KEY]},
  async (request) => {
    // Routing quota is a shared, rate-limited resource —
    // gating on sign-in (already required to use the rest of the app) keeps
    // an anonymous/scripted caller from draining it for free.
    if (!request.auth) {
      throw new HttpsError('unauthenticated', 'Sign-in required.');
    }

    const data = request.data || {};
    const {origin, destination, mode} = data;
    if (!origin || !isValidLatLng(origin.lat, origin.lng)) {
      throw new HttpsError('invalid-argument', 'origin lat/lng required.');
    }
    // A round trip starts and ends at `origin` — there is no destination
    // to validate. Every other mode still requires one.
    if (mode !== 'round_trip' &&
        (!destination || !isValidLatLng(destination.lat, destination.lng))) {
      throw new HttpsError('invalid-argument', 'origin/destination lat/lng required.');
    }

    // Round-trip parameters are validated OUTSIDE the try below on
    // purpose: the catch wraps everything in HttpsError('unavailable'),
    // which would mislabel a malformed request as a network failure.
    let roundTrip = null;
    if (mode === 'round_trip') {
      const lengthMeters = Number(data.lengthMeters);
      if (!Number.isFinite(lengthMeters) || lengthMeters <= 0 ||
          lengthMeters > ORS_MAX_ROUND_TRIP_METERS) {
        throw new HttpsError(
          'invalid-argument',
          `lengthMeters: number in (0, ${ORS_MAX_ROUND_TRIP_METERS}] required.`);
      }
      roundTrip = {
        lengthMeters,
        // ORS: "larger values create more circular routes". Clamped to a
        // sane band; 5 is a good default for running loops.
        points: Number.isInteger(data.points)
          ? Math.min(Math.max(data.points, 2), 10)
          : 5,
        seed: Number.isInteger(data.seed) ? data.seed : 0,
      };
    }

    const apiKey = ORS_API_KEY.value();

    try {
      if (roundTrip) {
        return await fetchRoundTrip(
          apiKey, origin, roundTrip.lengthMeters, roundTrip.points,
          roundTrip.seed);
      }
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

  const started = Date.now();
  const response = await fetchWithTimeout(uri, {}, ORS_TIMEOUT_MS);
  const body = await response.json().catch(() => null);
  logUpstream('ors-directions-get', {
    status: response.status,
    ms: Date.now() - started,
    rateLimitRemaining: response.headers.get('x-ratelimit-remaining'),
    rateLimitReset: response.headers.get('x-ratelimit-reset'),
  });
  return {status: response.status, body};
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

  const started = Date.now();
  const response = await fetchWithTimeout(uri, {
    method: 'POST',
    headers: {
      'Authorization': apiKey,
      'Content-Type': 'application/json; charset=UTF-8',
      'Accept': 'application/json, application/geo+json',
    },
    body,
  }, ORS_TIMEOUT_MS);
  const responseBody = await response.json().catch(() => null);
  logUpstream('ors-directions-alternatives', {
    status: response.status,
    ms: Date.now() - started,
    rateLimitRemaining: response.headers.get('x-ratelimit-remaining'),
    rateLimitReset: response.headers.get('x-ratelimit-reset'),
  });
  return {status: response.status, body: responseBody};
}

/**
 * ORS's native round-trip generation: POST /geojson with a SINGLE
 * coordinate pair plus `options.round_trip` — the routing engine itself
 * grows a closed foot-walking loop of roughly `lengthMeters` out of the
 * real road network. One upstream call replaces the whole chain of
 * guessed point-to-point legs route search used to fire per candidate
 * loop, and the result can't strand across rivers/highways the way a
 * synthetic offset waypoint could. ORS documents `length` as a preferred
 * value, not a guarantee — the client re-requests with a scaled length
 * (same `seed`, so the loop keeps its overall direction) when a result
 * misses its tolerance. Same verbatim {status, body} forwarding as the
 * other two orsRoute modes: the client owns parsing and 429/403 handling.
 * @param {string} apiKey
 * @param {{lat: number, lng: number}} origin loop start & end.
 * @param {number} lengthMeters preferred loop length.
 * @param {number} points how circular the loop is (higher = rounder).
 * @param {number} seed varies the loop's overall direction.
 * @return {Promise<{status: number, body: Object}>}
 */
async function fetchRoundTrip(apiKey, origin, lengthMeters, points, seed) {
  const uri = 'https://api.openrouteservice.org/v2/directions/foot-walking/geojson';
  const body = JSON.stringify({
    coordinates: [[origin.lng, origin.lat]],
    options: {
      round_trip: {
        length: Math.round(lengthMeters),
        points,
        seed,
      },
    },
    instructions: false,
  });

  const started = Date.now();
  const response = await fetchWithTimeout(uri, {
    method: 'POST',
    headers: {
      'Authorization': apiKey,
      'Content-Type': 'application/json; charset=UTF-8',
      'Accept': 'application/json, application/geo+json',
    },
    body,
  }, ORS_TIMEOUT_MS);
  const responseBody = await response.json().catch(() => null);
  logUpstream('ors-directions-roundtrip', {
    status: response.status,
    ms: Date.now() - started,
    lengthMeters: Math.round(lengthMeters),
    points,
    seed,
    rateLimitRemaining: response.headers.get('x-ratelimit-remaining'),
    rateLimitReset: response.headers.get('x-ratelimit-reset'),
  });
  return {status: response.status, body: responseBody};
}

// ── matchDrawnPath ───────────────────────────────────────────────────────────

/**
 * Input:  {points: [{lat, lng}, ...],   // the (client-decimated) drawn stroke
 *          backend?: 'valhalla'|'ors'}  // optional override of the default
 *
 * Output (normalized — never a verbatim upstream body):
 *   {status: 'ok', backend, polyline: [[lat, lng], ...], distanceMeters}
 *   {status: 'rate_limited', backend, retryAfterSeconds?}
 *   {status: 'quota_exhausted', backend}          // ORS daily 403
 *   {status: 'no_route', backend, message?}       // no walkable match
 *   {status: 'service_error', backend, httpStatus?}
 * plus HttpsError('unavailable') when the upstream is unreachable at the
 * network level — which the client maps to its network-error case.
 */
exports.matchDrawnPath = onCall(
  {region: 'europe-west1', secrets: [ORS_API_KEY]},
  async (request) => {
    if (!request.auth) {
      throw new HttpsError('unauthenticated', 'Sign-in required.');
    }

    const data = request.data || {};
    const rawPoints = data.points;
    if (!Array.isArray(rawPoints) ||
        rawPoints.length < 2 ||
        rawPoints.length > MATCH_MAX_INPUT_POINTS) {
      throw new HttpsError(
        'invalid-argument',
        `points: array of 2..${MATCH_MAX_INPUT_POINTS} {lat,lng} required.`);
    }
    const points = [];
    for (const p of rawPoints) {
      if (!p || !isValidLatLng(p.lat, p.lng)) {
        throw new HttpsError('invalid-argument', 'points: every entry needs valid lat/lng.');
      }
      points.push({lat: p.lat, lng: p.lng});
    }

    const backend = (data.backend === 'ors' || data.backend === 'valhalla')
      ? data.backend
      : DEFAULT_MATCH_BACKEND;

    // Shared preparation: bound the density, then smooth away finger
    // jitter (see MATCH_SMOOTHING_WINDOW) — both backends want a clean,
    // still-dense stroke as their starting point.
    const prepared = smoothPath(
      decimateMinSpacing(points, MATCH_MIN_SPACING_METERS),
      MATCH_SMOOTHING_WINDOW);

    try {
      return backend === 'ors'
        ? await matchWithOrs(ORS_API_KEY.value(), prepared)
        : await matchWithValhalla(prepared);
    } catch (e) {
      console.error('matchDrawnPath: upstream unreachable', e);
      throw new HttpsError('unavailable', 'Could not reach routing service.');
    }
  }
);

/**
 * Valhalla strategy, two stages:
 *
 *  1. True map matching (trace_route, pedestrian costing): the whole
 *     stroke is one observation sequence, every point a *noisy hint*
 *     rather than a mandatory destination. Two attempts, widening the
 *     search radius / declared noise. A discontinuity ("the matcher
 *     couldn't walk part of the stroke") is a SOFT failure: it triggers
 *     the wider attempt instead of aborting, since more candidate edges
 *     often heal the gap.
 *  2. Corner routing (route through the sketch's RDP corners, see
 *     CORNER_EPSILONS_METERS): the zoom-robust reinterpretation used when
 *     matching can't read the sketch at all — coarse strokes drawn with
 *     half a district on screen land here by design.
 *
 * Upstream bound: at most 3 calls (2 trace attempts + 1 corner routing).
 * Rate limits and unexpected HTTP errors abort immediately.
 * @param {Array<{lat: number, lng: number}>} points prepared stroke.
 * @return {Promise<Object>} normalized result, see `matchDrawnPath` docs.
 */
async function matchWithValhalla(points) {
  const prepared = capPointCount(points, VALHALLA_MAX_SHAPE_POINTS);

  let lastSoftFailure = null;
  for (const attempt of VALHALLA_ATTEMPTS) {
    const started = Date.now();
    const response = await fetchWithTimeout(`${VALHALLA_BASE_URL}/trace_route`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'X-Client-Id': VALHALLA_CLIENT_ID,
      },
      body: JSON.stringify({
        shape: prepared.map((p) => ({lat: p.lat, lon: p.lng})),
        costing: 'pedestrian',
        costing_options: {pedestrian: PEDESTRIAN_COSTING_OPTIONS},
        shape_match: 'map_snap',
        trace_options: {
          search_radius: attempt.search_radius,
          gps_accuracy: attempt.gps_accuracy,
          turn_penalty_factor: VALHALLA_TURN_PENALTY_FACTOR,
        },
        units: 'kilometers',
        directions_type: 'none',
      }),
    }, VALHALLA_TIMEOUT_MS);
    const body = await response.json().catch(() => null);

    let outcome;
    let finalResult = null;
    if (response.status === 200 && body && body.trip) {
      if (Array.isArray(body.alternates) && body.alternates.length > 0) {
        // Discontinuity: Valhalla split the match because part of the
        // stroke had no walkable interpretation at this tolerance. Soft
        // failure — widen, and ultimately fall back to corner routing.
        outcome = 'discontinuity';
        lastSoftFailure = {
          status: 'no_route',
          backend: 'valhalla',
          message: 'stroke has a gap with no walkable connection',
        };
      } else {
        const polyline = decodeTripPolyline(body.trip);
        if (polyline.length < 2) {
          outcome = 'bad-payload';
          finalResult = {status: 'service_error', backend: 'valhalla'};
        } else {
          outcome = 'matched';
          finalResult = okResult('valhalla', 'trace', polyline);
        }
      }
    } else if (response.status === 429) {
      outcome = 'rate-limited';
      finalResult = {
        status: 'rate_limited',
        backend: 'valhalla',
        retryAfterSeconds: parseRetryAfterSeconds(response),
      };
    } else if (response.status === 400) {
      // {error_code, error} — e.g. "No suitable edges near location":
      // points farther from any walkable edge than the search radius.
      // Soft failure, same escalation as a discontinuity.
      outcome = 'no-match';
      lastSoftFailure = {
        status: 'no_route',
        backend: 'valhalla',
        message: body && body.error ? String(body.error) : undefined,
      };
    } else {
      outcome = `http-${response.status}`;
      finalResult = {
        status: 'service_error',
        backend: 'valhalla',
        httpStatus: response.status,
      };
    }

    logUpstream('valhalla-trace-route', {
      status: response.status,
      ms: Date.now() - started,
      shapePoints: prepared.length,
      searchRadius: attempt.search_radius,
      outcome,
    });
    if (finalResult) return finalResult;
  }

  // Matching couldn't read the sketch at any tolerance — reinterpret it.
  return routeThroughCorners(prepared, lastSoftFailure);
}

/**
 * Stage 2: reduce the stroke to its corners and route through them (see
 * CORNER_EPSILONS_METERS for the full rationale). By construction this
 * yields the simplest walkable path connecting the sketch's corners,
 * trading trace fidelity for zoom robustness.
 * @param {Array<{lat: number, lng: number}>} points prepared stroke.
 * @param {Object|null} matchFailure best failure from the trace stage,
 *   reused when routing has nothing more specific to say.
 * @return {Promise<Object>} normalized result, see `matchDrawnPath` docs.
 */
async function routeThroughCorners(points, matchFailure) {
  let corners = points;
  for (const epsilonMeters of CORNER_EPSILONS_METERS) {
    if (corners.length <= CORNER_MAX_POINTS) break;
    corners = rdpSimplify(points, epsilonMeters);
  }
  if (corners.length > CORNER_MAX_POINTS) {
    corners = capPointCount(corners, CORNER_MAX_POINTS);
  }

  const locations = corners.map((p, i) => ({
    lat: p.lat,
    lon: p.lng,
    type: i === 0 || i === corners.length - 1 ? 'break' : 'via',
  }));

  const started = Date.now();
  const response = await fetchWithTimeout(`${VALHALLA_BASE_URL}/route`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-Client-Id': VALHALLA_CLIENT_ID,
    },
    body: JSON.stringify({
      locations,
      costing: 'pedestrian',
      costing_options: {pedestrian: PEDESTRIAN_COSTING_OPTIONS},
      units: 'kilometers',
      directions_type: 'none',
    }),
  }, VALHALLA_TIMEOUT_MS);
  const body = await response.json().catch(() => null);

  let outcome;
  let finalResult;
  if (response.status === 200 && body && body.trip) {
    const polyline = decodeTripPolyline(body.trip);
    if (polyline.length < 2) {
      outcome = 'bad-payload';
      finalResult = {status: 'service_error', backend: 'valhalla'};
    } else {
      outcome = 'routed';
      finalResult = okResult('valhalla', 'corners', polyline);
    }
  } else if (response.status === 429) {
    outcome = 'rate-limited';
    finalResult = {
      status: 'rate_limited',
      backend: 'valhalla',
      retryAfterSeconds: parseRetryAfterSeconds(response),
    };
  } else if (response.status === 400) {
    outcome = 'no-route';
    const message = body && body.error ? String(body.error) : undefined;
    finalResult = {
      status: 'no_route',
      backend: 'valhalla',
      message: message ||
        (matchFailure && matchFailure.message ? matchFailure.message : undefined),
    };
  } else {
    outcome = `http-${response.status}`;
    finalResult = {
      status: 'service_error',
      backend: 'valhalla',
      httpStatus: response.status,
    };
  }

  logUpstream('valhalla-route-corners', {
    status: response.status,
    ms: Date.now() - started,
    corners: corners.length,
    outcome,
  });
  return finalResult;
}

/**
 * ORS backend: ONE POST directions request through the sketch's CORNERS —
 * the same philosophy as the Valhalla corner stage (see
 * CORNER_EPSILONS_METERS), because few free-routed corners beat many
 * mandatory vias: 50 hard constraints reproduced every wobble as a zigzag.
 * U-turns at vias stay permitted (`continue_straight: false`) for the same
 * reason Valhalla corners use type 'via': a bad snap then costs a small
 * in-and-out spike that `removeBacktrackSpurs` deletes, whereas forbidding
 * it would force a non-removable detour around the block. ORS's foot
 * profile has no service-road penalty knobs, so a corner landing inside a
 * parking lot can still pull the route through it — the residual price of
 * this backend.
 * @param {string} apiKey
 * @param {Array<{lat: number, lng: number}>} points
 * @return {Promise<Object>} normalized result, see `matchDrawnPath` docs.
 */
async function matchWithOrs(apiKey, points) {
  // Reduce to corners (well under ORS's hard 50-waypoint API cap; stride
  // cap as a last resort so the single-request bound holds even for
  // pathological input).
  let simplified = points;
  for (const epsilonMeters of CORNER_EPSILONS_METERS) {
    if (simplified.length <= CORNER_MAX_POINTS) break;
    simplified = rdpSimplify(points, epsilonMeters);
  }
  if (simplified.length > CORNER_MAX_POINTS) {
    simplified = capPointCount(simplified, CORNER_MAX_POINTS);
  }

  const started = Date.now();
  const response = await fetchWithTimeout(
    'https://api.openrouteservice.org/v2/directions/foot-walking/geojson', {
      method: 'POST',
      headers: {
        'Authorization': apiKey,
        'Content-Type': 'application/json; charset=UTF-8',
        'Accept': 'application/json, application/geo+json',
      },
      body: JSON.stringify({
        coordinates: simplified.map((p) => [p.lng, p.lat]),
        continue_straight: false, // see docblock: spikes are removable, block detours are not
        instructions: false,
      }),
    }, ORS_TIMEOUT_MS);
  const body = await response.json().catch(() => null);
  logUpstream('ors-directions-corners', {
    status: response.status,
    ms: Date.now() - started,
    corners: simplified.length,
    rateLimitRemaining: response.headers.get('x-ratelimit-remaining'),
    rateLimitReset: response.headers.get('x-ratelimit-reset'),
  });

  if (response.status === 200 && body &&
      Array.isArray(body.features) && body.features.length > 0) {
    const feature = body.features[0];
    const coords = feature && feature.geometry &&
      Array.isArray(feature.geometry.coordinates)
      ? feature.geometry.coordinates
      : null;
    const distance = feature && feature.properties &&
      feature.properties.summary &&
      typeof feature.properties.summary.distance === 'number'
      ? feature.properties.summary.distance
      : null;
    if (!coords || coords.length < 2 || distance === null) {
      return {status: 'service_error', backend: 'ors'};
    }
    const polyline = [];
    for (const c of coords) {
      const pair = [Number(c[1]), Number(c[0])]; // GeoJSON is [lng, lat]
      const prev = polyline[polyline.length - 1];
      if (!prev || prev[0] !== pair[0] || prev[1] !== pair[1]) polyline.push(pair);
    }
    // Same deterministic cleanup + geometry-derived distance as the
    // Valhalla strategies — ORS's mandatory via points can force the same
    // kind of in-and-out poke.
    return okResult('ors', 'directions', polyline);
  }

  if (response.status === 429) {
    // ORS free plan: 40 requests/min (sliding window) answers 429.
    return {
      status: 'rate_limited',
      backend: 'ors',
      retryAfterSeconds: parseRetryAfterSeconds(response),
    };
  }
  if (response.status === 403) {
    // ORS free plan: the DAILY quota (2000 directions/day, rolling 24 h
    // window) answers 403 — the status the old pipeline mistook for an
    // ordinary failure and retried into.
    return {status: 'quota_exhausted', backend: 'ors'};
  }
  if (response.status === 404 || response.status === 400) {
    const message = body && body.error && body.error.message
      ? String(body.error.message)
      : undefined;
    return {status: 'no_route', backend: 'ors', message};
  }
  return {status: 'service_error', backend: 'ors', httpStatus: response.status};
}