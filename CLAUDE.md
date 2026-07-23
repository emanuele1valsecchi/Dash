# Dash

## What this is

Dash is a mobile running app (Flutter, iOS/Android) with a territory-control gamification
layer on top of normal route tracking. It is **not** just "draw a route and go" — the
core loop is claiming physical map areas by running closed loops around them.

### Core gamification mechanics (target design — see "Implementation status" below)

- A user can plan a route before running (manual pins or parametrized by time/distance/
  calories) or start a **live session** where Dash records the GPS path in real time.
- If a live path closes into a loop, the enclosed area is **claimed** and assigned to
  that user, earning XP.
- Another user can **steal** a claimed area by running a closed loop that covers it.
- A user can also become **champion** of an already-claimed area by re-running the same
  loop faster than the current champion, without needing to physically "overwrite" it.
- During a run Dash gives turn-by-turn directions (if a planned route is active),
  announces elapsed time, average speed, and pace vs. the current area champion.
- A stats/profile area shows weekly runs, average speed, total time, longest route, etc.

## Implementation status

Keep this list current — update it whenever a feature moves between these buckets.

**Built:**
- Email/password + Google Sign-In auth ([lib/services/auth_service.dart](lib/services/auth_service.dart)), session persisted via `FirebaseAuth.authStateChanges` so the user isn't asked to log in every launch ([lib/main.dart](lib/main.dart)).
- Onboarding, registration, profile setup flow ([lib/screens/onboarding_screen.dart](lib/screens/onboarding_screen.dart), [lib/screens/user_setup_screen.dart](lib/screens/user_setup_screen.dart)).
- Map exploration page ([lib/screens/explore_page.dart](lib/screens/explore_page.dart)).
- Route planning: pin-dropping (tap the map) or freehand drawing (press-and-drag a
  finger across the map) on the map, road-snapped via OpenRouteService, with
  distance/time/calorie estimation and undo/redo history
  ([lib/screens/route_create_page.dart](lib/screens/route_create_page.dart), [lib/services/routing_service.dart](lib/services/routing_service.dart), [lib/utils/geometry_utils.dart](lib/utils/geometry_utils.dart)). A route
  isn't limited to a single closed loop — placing more pins (or, previously, hitting a
  block) after one closes now continues the route, and each additional loop the path
  goes on to close is kept, not overwritten (`_loopPolygons`/`_loopAreasM2`, both lists);
  self-intersection/snap-to-waypoint checks are scoped to only the segments added since
  the last loop closed (`_activeLoopStartSegment`), so a new segment can't get matched
  against an already-finalised loop's own geometry. Deleting any pin still conservatively
  clears every loop closed so far, rather than trying to work out which ones a given
  deletion actually invalidated. Freehand drawing is one-shot per route — only usable
  while it's completely empty, never to append a second stroke onto an already-drawn (or
  already-pinned) route — and works by disabling the map's own pan interaction for the
  duration (a transparent `GestureDetector` overlay captures the stroke instead, since a
  single-finger drag would otherwise just pan the map) and, once released, downsampling
  the raw finger path (one point per pixel of movement) to a manageable number of
  waypoints (`_sampleDrawnPath`). Converting those samples into a route (`_convertDrawingToRoute`)
  does *not* reuse the plain tap-to-place pipeline's routing call — a bare
  `RoutingService.fetchRoute` failure there falls back to an unsnapped straight line, which
  is exactly what let a drawn route visibly cut across buildings/fields when one of the many
  chained ORS calls a drawing produces (up to `_maxDrawSamples`) hit a timeout/rate-limit.
  Instead each hop retries once (`_fetchRoadRouteWithRetry`) and, if still unreachable,
  reaches progressively further ahead past the problem sample — up to `_drawRouteMaxSkipAhead`
  (2) — so the route can go around whatever the sample landed on/in while staying a real,
  road-snapped ORS route the whole way; a raw straight line is only ever used as the very
  last resort for one unavoidable hop. This retry/skip-ahead itself costs extra requests per
  struggling hop, which turned out to matter: `RoutingService.fetchRoute`'s hardcoded ORS key
  (already flagged as shared/insecure, see "Known security debt" below) is also
  rate-limited, and the retry logic originally amplified that badly — a single bad hop could
  fire up to `(1 + _drawRouteMaxRetries) * (1 + _drawRouteMaxSkipAhead)` requests trying to
  recover it, which compounds fast once *any* hop hiccups and was the likely cause of drawn
  routes degrading noticeably (far fewer real waypoints, much sparser/less accurate) on
  repeated back-to-back draws in testing, after an initial clean one. `RoutingService.fetchRoute`
  now takes a `throwOnRateLimit` flag (only `_convertDrawingToRoute` opts in) that throws
  `RoutingRateLimitedException` on an HTTP 429 specifically, distinct from any other failure —
  the draw conversion catches it and stops probing immediately for that hop (accepting a
  straight line right away instead of retrying/reaching further into an active rate-limit
  window) while still trying the *next* hop fresh, rather than burning more of the shared quota
  chasing a wall that isn't going away in the next second. `_maxDrawSamples`/
  `_minDrawSampleSpacingMeters` were also lowered (30→15 samples, 25m→40m spacing) purely to
  cut the base request count per drawn route — fewer requests per drawing reduces exposure to
  any throttling regardless of cause. All failures (including 429s) are now logged via
  `debugPrint` in `RoutingService.fetchRoute` so a recurrence can be diagnosed from real
  status codes instead of guessing. A drawn shape closes loops (including several, if it
  crosses itself more than once) the same way a tapped-out one does, and the whole
  conversion is a single undo step, not one per sampled point. Only the start and finish
  waypoint of a drawn segment render a pin marker — every interior sample point is still a
  real waypoint (routing/undo/loop-detection all still see it) but is deliberately not drawn,
  since the individual sample points aren't independently meaningful or user-placed the way a
  tapped pin is (`_isHiddenWaypoint`, driven by `_drawnPointsCount`, which is reset to 0 by
  anything — clearing, deleting a pin — that invalidates "the first N waypoints are exactly
  what drawing produced"). **Known limitation**: this is retry/reach-ahead tuning on top of
  point-to-point routing, not true map-matching — if two consecutive samples end up on
  opposite sides of a large obstacle with no reasonably short walkable connection, ORS may
  produce a long real detour (correct, but visually surprising) rather than a shortcut, and a
  region with no network connectivity (or one that's genuinely rate-limited for a sustained
  stretch) to fall back on will still end up with straight-line hops. All area displays
  app-wide (loop-closure banners, claimed-area details, run results)
  show km² consistently, with decimal precision scaling by magnitude
  (`GeometryUtils.formatAreaKm2`) rather than switching between m²/ha/km² by size.
- Place search on the route-creation map's top bar: while the field is focused, the
  whole page becomes a full-screen white takeover (map/sheet/buttons all covered) with
  the results list filling the remaining space, rather than a small dropdown — all
  search state (controller, focus, debounce, fetch/rank logic) lives directly on
  `_RouteCreatePageState` rather than a separate widget, since the results list is a
  `Stack` sibling of the search field, not a descendant of it. Two sources are merged:
  Nominatim (primary, fast — results show the instant they arrive) and an Overpass POI
  fallback for informally-named places Nominatim's address search misses (e.g. "Edificio
  25 Polimi"), only queried when Nominatim returns fewer than 3 results, and treated as a
  **non-blocking** background enhancement — the public Overpass instance measured
  anywhere from ~7s-504 to 37s for the same shape of query, so nothing waits on it.
  Results are re-ranked client-side by a strict lexicographic sort — text-match quality,
  then a coarse tier of Nominatim's own `importance`, then proximity, each only a
  tiebreaker for the one before it — not a weighted sum, which failed on real cases (a
  village named "Londo" outranking London on text match; London, Ontario outranking
  London, England on a summed score). Selecting a result flies the camera there
  (`_flyTo`, see below) and also drops a pin at that spot via the same `_onMapTap` pin
  logic a real map tap would use.
- Two camera animations shared by the route-creation map: `_flyTo` (search-result
  selection and the "my location" button) does a proportional "zoom out, pan, zoom back
  in" flourish for search selection (`CameraFit.coordinates` sizes the dip to how far
  apart the two points actually are, floored at a minimum zoom so a transatlantic search
  doesn't dip to a near-whole-Earth view), or a direct pan/zoom with no dip for "my
  location" (returning to a known nearby point doesn't need the flourish, and skipping it
  also cuts the burst of intermediate-zoom-level tile requests that were tripping Jawg's
  rate limit). `_animateRotationTo` (the compass/"reset north" button) smoothly rotates
  along whichever direction is shorter instead of snapping instantly, touching only
  rotation, never zoom/pan.
- Map tiles are cached to disk app-wide via `CachedTileProvider`
  ([lib/services/cached_tile_provider.dart](lib/services/cached_tile_provider.dart)), shared by every screen's `TileLayer`
  (`tileProvider: CachedTileProvider.instance`) — flutter_map's default tile provider only
  caches decoded images in memory for the process's lifetime, so every fresh app launch
  (and, since each map screen builds its own `FlutterMap`, every navigation between them)
  was re-fetching tiles from Jawg that had already just been downloaded, counting against
  its request-rate limit. Built on `cached_network_image`/`flutter_cache_manager` (already
  dependencies, used elsewhere for profile/badge images) rather than a new dependency, with
  its own dedicated cache (not the shared `DefaultCacheManager`) since tiles are far more
  numerous/smaller/longer-lived than those images.
- Route search/discovery by parameters ([lib/screens/route_search_page.dart](lib/screens/route_search_page.dart)).
- Saving/listing/deleting routes in Firestore, with a client-side cache ([lib/services/route_repository.dart](lib/services/route_repository.dart)).
- Profile picture upload with strict validation (size/extension/MIME/magic-byte sniffing) to Firebase Storage ([lib/services/image_upload_service.dart](lib/services/image_upload_service.dart)).
- Badge listing (default/visible badges) and a temporary profile page showing the user's saved routes ([lib/services/badge_service.dart](lib/services/badge_service.dart), [lib/screens/temp_profile_page.dart](lib/screens/temp_profile_page.dart)).
  `firestore.rules` had no `match` block at all for `badges` or `profiles/{uid}/badge_progress`
  until a later fix — Firestore denies unmatched paths by default, so every read of either
  failed with `permission-denied` (badges surfaced this to the user on the homepage;
  badge_progress failed silently into a caught `debugPrint`, always showing 0%/locked).
  Both are covered now: `badges` is signed-in-read/no-client-write shared reference data,
  `badge_progress` is self-read-only (same trust-value reasoning as `userStats`).
- Cloud Function that seeds a `profiles/{uid}` doc and `badge_progress` subcollection on user signup ([functions/index.js](functions/index.js)).
- Live run tracking screen ("Start to run now"): a 5-second pre-run countdown (STOP
  pauses it, resuming restarts it from 5) precedes GPS tracking; battery-efficient GPS
  breadcrumb recording (distance-filtered position stream, not a timer poll), a
  stopwatch, rolling-window pace, live self-crossing loop-closure detection with a lit
  indicator, and an expandable live map that paints the run trail and fills closed loop
  polygons ([lib/screens/run_tracking_page.dart](lib/screens/run_tracking_page.dart), loop-closure math in [lib/utils/geometry_utils.dart](lib/utils/geometry_utils.dart)). On finish the user names
  the run and reviews time/distance/avg pace/max pace/calories/elevation before choosing
  Save (persists via `RunSessionRepository` to `runningSessions`, see below) or Discard
  (re-confirms, then nothing is written). The screen only tracks in the foreground — no
  background/lock-screen GPS service is configured.
- Dev-only test run creator, reached from the run-tracking countdown screen
  ([lib/screens/test_run_creator_page.dart](lib/screens/test_run_creator_page.dart)) — builds a fake run by placing pins (routed
  the same way as route creation) plus a manually-entered duration, then publishes
  straight into `runningSessions`, so the area-claiming logic can be tested against
  specific loop shapes without physically running them. Mirrors route creation's
  pin-drop/freehand-drawing/multi-loop behaviour exactly (both screens' loop-detection
  and drawing code are near-identical on purpose — see the route-planning bullet above),
  including sending every closed loop to `RunSessionRepository.saveSession`'s
  `closedLoops` list, not just one.
- `runningSessions` persistence via [lib/services/run_session_repository.dart](lib/services/run_session_repository.dart) — the collection
  Firestore rules already anticipated (see Data model below). Deliberately a separate
  collection/repository from `routes`/`RouteRepository`: a `routes` doc is a *planned*
  path built on the map before running; a `runningSessions` doc is the record of a run
  actually completed, and is what XP/missions/homepage history are meant to read from.
  Closed-loop polygons are stored as an array of `{'points': [...]}` maps, not a raw
  array-of-arrays — Firestore rejects directly nested arrays.
- All maps use the Jawg Terrain tile style (low-detail basemap vs. standard OSM carto),
  centralized in [lib/config/map_style.dart](lib/config/map_style.dart) and consumed by every screen's `TileLayer`
  (explore, route create/search, run tracking, test run creator, temp profile), with
  `retinaMode` enabled so tiles stay sharp on high-density phone screens. The Explore
  page's satellite/layer-toggle button was removed — it didn't fit the app's style, so
  there is now only one map style, no picker.
- Water fountain markers (blue drop icon in a white circular badge), sourced live from
  OpenStreetMap's Overpass API (`amenity=drinking_water` nodes, no API key) via
  [lib/services/water_fountain_service.dart](lib/services/water_fountain_service.dart) and rendered with
  [lib/widgets/map/water_fountain_marker_layer.dart](lib/widgets/map/water_fountain_marker_layer.dart) — each `Marker` is keyed by the OSM
  node id since flutter_map culls off-screen markers every frame and reconciles the rest by
  list position when unkeyed. **Shown only on live run tracking** ([lib/screens/run_tracking_page.dart](lib/screens/run_tracking_page.dart)),
  not on explore/route create/route search. It used to be shown on all four, with two
  different loading strategies tried on the browsing screens (GPS-position-based, then later
  also map-camera/pan-based) — both were removed, not just tuned, after panning around to
  casually browse the map kept growing the cache and sending a steady stream of Overpass
  requests unrelated to anything running-related. Revisit fountains-on-the-browsing-screens
  as a deliberately-scoped feature later if wanted; don't re-add it by just wiring the
  existing service back into those screens as-is. `WaterFountainService` is an app-wide
  singleton (`WaterFountainService.instance`, same pattern as `LocationService`) — mainly so
  a runner who repeatedly starts from the same spot benefits from the cache across separate
  runs — and is seeded from/persisted to disk via `shared_preferences` (a versioned
  `water_fountain_cache_v1` blob, 30-day TTL, capped at 150 entries, cache key snapped to a
  ~2km grid — deliberately close to `fetchNearby`'s own 3km query radius, so two starting
  points a kilometre or two apart still hit the same cache entry), so a previously-used
  starting point loads instantly even on a fresh app cold start, not just within a session —
  `HomeScreen.initState` calls `WaterFountainService.instance.warmUp()` alongside
  `LocationService.instance.start()` so the disk read happens in parallel with GPS
  acquisition. Concurrent requests for the same area are coalesced (an in-flight-request map
  keyed the same way as the cache, evicted the instant each request settles either way) so a
  burst of near-simultaneous callers can't each fire their own duplicate Overpass request.
  `fetchNearby` returns `null` (not an empty list) on failure, so a failed fetch doesn't get
  mistaken for "successfully checked, nothing here" — callers should treat `null` as "leave
  whatever was already showing", not clear to empty. Run tracking calls it once, at the run's
  starting position, and never refetches (its map also has panning disabled entirely — only
  pinch/double-tap zoom), to avoid extra network/battery use mid-workout. Whether the
  fetched fountains are actually drawn is a separate, zoom-gated decision made by
  `WaterFountainMarkerLayer` from an explicit `visible` flag the screen computes in a
  `MapOptions.onPositionChanged` handler (`camera.zoom >= WaterFountainMarkerLayer.minZoomToShow`,
  currently `13.0`, a ~5km-wide viewport) and passes down — deliberately not the widget
  reading flutter_map's ambient `MapCamera.of(context)` itself, which turned out not to
  reliably trigger a rebuild in practice despite matching flutter_map's own internal usage
  pattern. Only `setState`s when the visibility flag actually flips (not on every pan/zoom
  frame). No re-fetch on a zoom-driven visibility change either way — it's a pure redraw, so
  zooming back in shows already-loaded markers instantly.
- **Area claiming, with real territory interaction**: the
  `onRunningSessionCreateClaimedAreas` Cloud Function ([functions/index.js](functions/index.js)) triggers on
  every new `runningSessions` doc and, for each closed loop (skipping degenerate ones with
  < 3 points), resolves it against nearby existing `claimedAreas` before writing anything:
  - A loop fully or partially inside the claiming user's *own* existing territory is
    **unioned** into it (`turf.union`) — a fully-contained loop produces the identical
    shape (nothing new drawn), a partially-overlapping one produces a single seamless
    merged polygon, not two abutting shapes with a border between them.
  - A loop overlapping *someone else's* area **subtracts** the overlap from their area
    (`turf.difference`) — the contested ground becomes the new loop's; the other user
    keeps whatever's left (which can end up with a hole, or split into disconnected
    pieces, if the cut doesn't touch an edge). If nothing's left, their area doc is
    tombstoned (see below).
  - The heavy geometry (all the union/difference math, the Firestore-format <-> turf
    conversion, and the spatial candidate query) lives in [functions/geo.js](functions/geo.js) as a pure
    function of "new loop + nearby areas" with no Firestore dependency, specifically so it
    can be unit-tested standalone (`functions/_verify_geo.js`, not deployed — see
    `firebase.json`'s functions `ignore` list) without touching a live or emulated
    database. `index.js` is just the transactional I/O shell around it.
  - **Finding "nearby existing areas" without scanning the whole collection**: each area
    doc carries a `geohash` (via `geofire-common`, computed from its centroid). A new loop
    queries only the geohash cells its own bounding box could plausibly reach
    (`geofire.geohashQueryBounds`, radius scaled to the loop's own size) — a handful of
    small, single-field-indexed range queries instead of a full collection scan. Existing
    docs from before this field existed won't be found by it (Firestore's `orderBy` skips
    docs missing the ordered field entirely) — not a concern for real data since this
    landed before any real users had claimed territory, but worth knowing if test data
    from before this change lingers.
  - **Concurrency**: the read (geohash queries) + compute + write for one loop all happen
    inside a single `db.runTransaction`, not a plain batch — a batch has no optimistic-
    concurrency check, so two users finishing overlapping runs at nearly the same instant
    could otherwise both read the same pre-conflict area and silently lose one of the
    updates. A transaction retries automatically if a read document changed before commit.
    Multiple loops in the same session are still processed sequentially (one transaction
    each, awaited in order), so a second loop sees the first's already-committed result.
  - This is server-only by design (see "Security & performance" below) — `firestore.rules`
    denies client `create`/`update` on `claimedAreas` entirely, same as `userStats`.
  - **Known open issue, unconfirmed fix**: a user reported their own merged areas still
    rendering with a visible internal border line despite no actual overlap, while other
    users' post-steal areas rendered as a clean single blob. The most likely cause is the
    same-owner candidate query (`geohashBoundsForLoop`) missing a large existing area whose
    geohash centroid sits far from a small new loop's — `queryRadiusForGeom`'s margin was
    widened from 1000m to 5000m and a diagnostic `console.log` (candidate counts, same- vs.
    other-owner, resulting piece count) was added to `claimLoop` in `functions/index.js` to
    make the next occurrence diagnosable via `firebase functions:log`. Not yet confirmed
    fixed — revisit if it recurs, and check the log line first.
- **XP/points and scoreboard territory**, computed in the same `onRunningSessionCreateClaimedAreas`
  transaction pass rather than a separate trigger, since both need the same per-loop
  union/difference geometry: `XP = distanceKm*100 + totalAreaM2/1000 + stolenAreaM2/333`
  (`totalAreaM2` is deliberately the raw closed loop's *own* area, not the post-merge shape
  `mergedGeom` ends up as — otherwise re-running a loop that re-absorbs a large existing
  same-owner area would inflate XP, and a multi-loop session would double-count ground a later
  loop re-absorbs from an earlier one in the same session; `stolenAreaM2` reuses the existing
  other-owner subtraction pass, `area(existingGeom) - area(remaining)`, rather than a separate
  geometry call). Sessions with zero closed loops still earn distance-only XP. Written onto
  `runningSessions` as `pointsEarned` (rounded total) plus the raw, unrounded
  `xpFromDistance`/`xpFromArea`/`xpFromStolenArea` (so a client can show *why* — see the
  run-results popup below — without duplicating the Cd/Ca/Cr constants), `totalAreaM2`/
  `stolenAreaM2`, `territoryCity`/`territoryBroad`/`territoryBroadType`, and a `pointsProcessed:
  true` sentinel (deliberately not "`pointsEarned != 0`" — a negligible session can legitimately
  round to 0 XP, which would otherwise look identical to "not processed yet" to a client waiting
  on this write). `profiles.totalPoints` is incremented (`FieldValue.increment`) in the same
  batch. `firestore.rules` protects all of these on `runningSessions` the same way: absent on
  client `create` (`noServerOnlyFields`), and on `update` guarded via
  `!request.resource.data.diff(resource.data).affectedKeys().hasAny([...])` — the same idiom the
  `notifications` rule already used, chosen over a `resource.data.<field> == request.resource.data.<field>`
  chain because these fields don't exist at all until the Cloud Function runs, and dot-accessing
  a genuinely-missing map key is a rules evaluation error. Territory
  resolution ([functions/territory.js](functions/territory.js)) is two-tier and always keyed off the session's real GPS
  start point (`runningSessions.path[0]`), never the client-supplied `startLocality` string — it's
  now score-affecting, so it falls under the same server-only trust rule as area ownership:
  1. **City** — point-in-polygon against a small curated, hand-drawn coverage-polygon list in
     [functions/cityTerritories.js](functions/cityTerritories.js) (administrative boundaries don't match colloquial metro
     groupings — Seregno isn't in Milano's own province — so this can't be derived from
     geocoding alone). The actual polygon data lives as one GeoJSON file per city in
     [functions/cities/](functions/cities/) (`cityTerritories.js` just reads every `*.geojson` file in that
     directory at module load and flattens them into the `{name, boundary}` list
     `resolveCityTerritory` expects) — a deliberate choice over one shared hardcoded array,
     since city boundaries are authored by hand-tracing on geojson.io and its own export
     format needs zero reformatting this way, and each city's diff stays isolated instead of
     one array growing forever. A shape's `name` comes from its GeoJSON `properties.name`
     (set in geojson.io's editor before exporting), not the filename. Currently seeded with
     one illustrative Milano placeholder polygon (`functions/cities/milano.geojson`), not
     surveyed data — real boundaries are a content-authoring follow-up, city by city.
  2. **Broad fallback** (only reached if no city matched, so every run lands *somewhere*) — a
     server-side Nominatim reverse-geocode of the start point. Region and Country turn out to
     be the same lookup (`address.state` vs `address.country` from one response), so which one
     is "the broad tier" is a single constant, `territory.js`'s `BROAD_TERRITORY_LEVEL`
     (currently `'state'`, i.e. Region) — switching to Country later is a one-line change, not
     a new data source.
  Both new modules are pure/testable the same way `geo.js` is (`functions/_verify_territory.js`,
  same not-deployed convention as `_verify_geo.js`). No scoreboard/leaderboard collection or UI
  reads any of this yet — this is only the data layer one will eventually read from.
- **Run-results popup** ([lib/widgets/run_results_dialog.dart](lib/widgets/run_results_dialog.dart), `showRunResultsDialog`), shown after a
  run is saved from both the real GPS flow (`RunTrackingPage`'s summary dialog) and the dev-only
  [lib/screens/test_run_creator_page.dart](lib/screens/test_run_creator_page.dart) — a shared widget rather than duplicated, since both need
  the same thing. Shows a locked, non-interactive map fitted to the whole route
  (`MapOptions.initialCameraFit`/`CameraFit.coordinates`, `InteractiveFlag.none` — same
  pattern as the run-tracking mini preview card) plus distance/time/calories/elevation/avg
  speed immediately (all known client-side already), while Area/XP/leaderboard and a debug XP
  breakdown wait on a `runningSessions/{sessionId}` snapshot listener for the Cloud Function's
  `pointsProcessed: true` write to land — bounded (cancelled on arrival or a ~20s timeout,
  whichever first) rather than a standing listener, since this is genuinely waiting on a
  one-time async server computation, not an ongoing feed.
  `RunSessionRepository.saveSession` returns the new doc's ID (was `Future<void>`) specifically
  so callers have something to point this listener at.
- **What actually gets stored**: `claimedAreas.polygon` is a MultiPolygon-with-holes — an
  area can be more than one disconnected piece after a steal splits it, and/or have a hole
  where someone carved out its middle. Firestore disallows directly-nested arrays, so it's
  encoded as an array of `{outer, holes}` maps rather than raw rings (mirrors why
  `closedLoops` wraps points in `{points: [...]}`). `claimedAreas.contributions` is a
  capped (10, newest first) list of `{sessionId, durationMs, avgPaceMinPerKm,
  conquestDate}` — every run that contributed *current* ground to that area, not just the
  original one, because merges concatenate contribution lists and splits duplicate them
  onto both resulting pieces (there's no way to attribute a specific sub-region of a
  geometric split back to one contributing run, and duplicating is actually correct here,
  not a shortcut — the intent, per the project owner, is future "save another user's run
  as a route to try yourself" functionality, where seeing the same run listed on both
  fragments it helped build is exactly right). A steal that fully absorbs an area deletes
  its contributions along with it — deliberately: the run itself is still safe in
  `runningSessions`, only the *current-territory* record disappears, consistent with
  `claimedAreas` being current state, not a history log (see below).
- **Areas are no longer create-once-immutable, which the client sync had to account for**:
  [lib/services/claimed_area_repository.dart](lib/services/claimed_area_repository.dart)'s incremental "what's new" check now
  queries `updatedAt` (bumped on every write, not just creation) instead of `createdAt`,
  and merges results into its cache **by id** rather than appending — an update needs to
  replace the stale copy of that area, not sit alongside it. Fully-absorbed areas are
  never hard-deleted (Firestore has no "what got deleted since X" query, so a hard delete
  would leave an already-caching client with no way to find out); the Cloud Function marks
  them `deleted: true` instead, and the repository filters those out of what it returns
  while still consuming their `updatedAt` slot so the next query's lower bound moves past
  them.
- Claimed areas are rendered with the shared [lib/widgets/map/claimed_areas_layer.dart](lib/widgets/map/claimed_areas_layer.dart)
  (`ClaimedAreasLayer`) — never a user's raw run/route path, only the claimed-area
  polygons themselves. Each `ClaimedArea` can expand into multiple flutter_map `Polygon`s
  (one per disconnected piece, each with its own `holePointsList`) that all share the same
  `hitValue`, so tapping any fragment of a split area opens the same area's details. Shown
  on explore, route create/search, live run tracking, and the test run creator page:
  - **Coloring is viewer-relative, computed client-side in `ClaimedAreasLayer`**, not a
    stored property of the area (there is no `colorHex` field — an earlier per-user hashed
    palette was removed since it doesn't make sense once color depends on who's looking):
    the signed-in user's own areas are green (`ClaimedAreasLayer.myColor`, the app's
    standard accent), every other user's areas are a single flat red
    (`ClaimedAreasLayer.otherColor`). Explicitly a placeholder 2-tone scheme, expected to
    change once there's a real design for distinguishing multiple other players.
  - **Every one of the five screens showing areas** (explore, route create, route search,
    run tracking, test run creator) offers the same ownership-filter toggle via the shared
    [lib/widgets/map/area_visibility_toggle.dart](lib/widgets/map/area_visibility_toggle.dart) (`AreaVisibilityToggle`) — a small
    floating panel with a grid icon (show/hide *other* users' territory) and a cable icon
    (show/hide the *current* user's own territory), both on by default. Explore keeps its
    own inline copy of this panel (bundled with its compass button, predates the shared
    widget) rather than being switched over, to avoid touching already-working UI; the
    other four screens each hold `_showOtherAreas`/`_showMyAreas` state and a
    `_visibleAreas` getter that filters the screen's `_allAreas` by
    `FirebaseAuth.instance.currentUser?.uid`, then place the shared widget as a floating
    button alongside their other map controls.
  - **Explore (the Area page)** is the only screen with tap-to-view-details, and
    re-fetches every time it's opened (pushed fresh each visit).
  - **Route create/search, run tracking, and the test run creator** are display-only — no
    tap-to-view — loaded once in `initState` with no ownership filter beyond the toggle
    above (coloring still applies). Route create specifically can't have tap-to-view: the
    map's tap handler already means "drop a route pin", and an area polygon stealing that
    tap would break placing pins over claimed territory. Run tracking also loads once (like
    the water fountain fetch next to it) and deliberately does not refresh as the run
    progresses, to save battery/network mid-workout — the areas shown reflect the world as
    it was when the run started; a user can't check an area's details mid-run. The test run
    creator (dev-only tool, see below) loads once in `initState` the same way, mainly so a
    developer manually placing test loops can see existing territory to deliberately
    overlap/steal it.
  - On Explore, tapping a polygon opens [lib/widgets/map/area_details_sheet.dart](lib/widgets/map/area_details_sheet.dart)
    (`showAreaDetailsSheet`/`handleAreaTap` — a standard draggable/dismissible, scrollable
    `showModalBottomSheet`) showing the owner's username (looked up live via
    `ProfileService.fetchUsername`), conquest date, total current area (summed
    outer-ring-minus-holes across every piece via `ClaimedArea.totalAreaM2`, which wraps
    `GeometryUtils.polygonAreaM2`), and the "built from N runs" contributions list
    described above (date/duration/avg pace per run). Duration/pace per contribution are
    denormalized from the originating `runningSessions` doc by the claim Cloud Function
    rather than looked up live, because a user can't read another user's `runningSessions`
    doc directly (see firestore.rules). Tap detection uses flutter_map's
    `PolygonLayer.hitNotifier`/`Polygon.hitValue`, checked inside `MapOptions.onTap`.
- Each `runningSessions` doc records a best-effort `startLocality` — the raw reverse-geocoded
  place name (e.g. "Seregno") of the run's starting point, via Nominatim in
  [lib/services/run_session_repository.dart](lib/services/run_session_repository.dart) — and the claim Cloud Function copies it
  onto the `claimedAreas` docs it creates. This stays a display-only raw locality string,
  client-supplied and never used for anything score-affecting; the actual "group Seregno
  under Milano" scoreboard-territory logic is a separate, server-computed system (see
  "XP/points and scoreboard territory" above) keyed off real GPS coordinates, not this string.
- App-wide GPS position via [lib/services/location_service.dart](lib/services/location_service.dart) (`LocationService`, a
  singleton started once from `HomeScreen.initState`), so map screens read an
  already-warm position instead of each independently requesting permission and waiting
  on a fresh fix — this is why most map pages no longer show a location-loading spinner.
  Explore/route create/route search all read `LocationService.current` immediately and
  subscribe to `LocationService.updates` instead of running their own Geolocator stream.
  Run tracking is the deliberate exception: it still takes its own precise
  `Geolocator.getCurrentPosition()` fix and gates the pre-run countdown on it, because
  that fix (with altitude/timestamp `LocationService` doesn't expose) becomes the run's
  authoritative first breadcrumb point, and starting the countdown before it lands would
  risk the run's continuous tracking stream recording breadcrumbs before that starting
  point exists — it only routes permission-checking through `LocationService` (so it's
  usually pre-granted) and keeps its own dedicated stream for the actual live recording.

**Designed in Firestore rules but NOT yet built in the Flutter app** (i.e. the security
rules anticipate these collections — `runningSessions`, `claimedAreas`, `userStats`,
`notifications`, `favoriteRoutes`, `follows` — but there is little/no client code reading
or writing them yet, except `runningSessions` writes as of the run-tracking screen and
`claimedAreas` writes as of the claim Cloud Function above). Treat these as the next
major milestones:
- Champion re-timing: re-running the same loop *faster* than whoever currently holds it,
  without necessarily overwriting their territory. Spatial overlap — a new loop's ground
  taking over someone else's claimed area — **is** now handled (see "Area claiming,
  with real territory interaction" above); champion status is a separate, still-unbuilt
  mechanic layered on top of ground you may not even be contesting.
- The scoreboard itself (leaderboard UI, and the aggregation/query layer behind it). The
  per-session data it will read from — `pointsEarned` and city/broad territory — **is** now
  computed and stored server-side (see "XP/points and scoreboard territory" above); only the
  actual ranking/UI on top of that data is still unbuilt.
- Background/lock-screen GPS tracking for live runs (needs a foreground service on
  Android and a background location mode on iOS — deliberately out of scope for the
  first version of the run-tracking screen; flag this if asked to make it production-ready).
- Weekly/aggregate stats (`userStats`) and the homepage run history — `RunSessionRepository.fetchUserSessions()`
  exists but nothing in `HomeScreen` calls it yet; the "weekly stats" UI section
  ([lib/widgets/home/weekly_stats_section.dart](lib/widgets/home/weekly_stats_section.dart)) is still hardcoded placeholder data.
- Notifications, favorite routes, follows.

## Tech stack

- **Flutter** (Dart SDK ^3.11.0), Material 3.
- **Firebase**: Auth (email/password + Google Sign-In), Cloud Firestore, Cloud Storage,
  Cloud Functions (Node/v1 functions API, [functions/](functions/)). Territory geometry there runs on
  `@turf/turf` (polygon union/intersection/difference) and `geofire-common` (geohash-based
  spatial candidate queries — see "Area claiming" below).
- **Maps/routing**: `flutter_map` with the Jawg Terrain tile style ([lib/config/map_style.dart](lib/config/map_style.dart))
  + `latlong2` for geometry, `geolocator` for device location, OpenRouteService
  (foot-walking profile) via raw `http` calls for road-snapped directions and alternative
  routes ([lib/services/routing_service.dart](lib/services/routing_service.dart)), OpenStreetMap Overpass API for water-fountain POIs
  ([lib/services/water_fountain_service.dart](lib/services/water_fountain_service.dart)).
- No state-management package (Provider/Riverpod/Bloc) is in use yet — screens manage
  their own `State` directly. Don't assume one is available.

## Project structure

- `lib/screens/` — one file per full-screen page.
- `lib/widgets/` — reusable widgets, grouped by feature (e.g. `widgets/home/`).
- `lib/services/` — Firebase/network gateways (auth, Firestore repositories, storage,
  routing). Business/data logic belongs here, not in widgets.
- `lib/models/` — plain data classes / UI view-models.
- `lib/utils/` — pure helper functions (e.g. geometry/area calculations).
- `functions/` — Firebase Cloud Functions (Node.js), for server-authoritative logic that
  must not run on the client (points, badge progress, `claimedAreas` creation/mutation).
  `functions/geo.js` holds the territory union/difference/spatial-index logic as pure,
  Firestore-independent functions specifically so they're unit-testable standalone
  (`functions/_verify_geo.js`, excluded from deploy — see `firebase.json`) without a live
  or emulated database; `index.js` is the thin transactional I/O wrapper around it.
- `firestore.rules` — the source of truth for what the client is and isn't allowed to
  write; read this before adding any new Firestore read/write path.

## Data model (Firestore)

See [firestore.rules](firestore.rules) for the authoritative, enforced version of this. Summary:

- `profiles/{uid}` — doc ID = uid. `totalPoints` is server-only (client can never set/
  change it; Cloud Functions use the Admin SDK to bypass rules for this).
  - `profiles/{uid}/badge_progress/{badgeId}` — self-read-only, seeded by
    `seedUserProfileAndBadges`; no client write.
- `badges/{badgeId}` — shared reference data (title/description/image/order); signed-in
  read, no client write.
- `nicknames/{nickname}` — uniqueness index; doc ID is the nickname itself, value holds
  the owning `uid`.
- `routes/{routeId}` — owned by `userId`; geometry (`routePolyline`, `waypoints`,
  `distanceMeters`) is immutable after create, only name/visibility can be updated.
- `claimedAreas/{areaId}` — doc ID is `{sessionId}_{loopIndex}` of whichever run most
  recently created or absorbed it (an area's ID can outlive the specific run it's named
  after, once merges/steals touch it). `create`/`update` are both `if false` for the
  client; only the `onRunningSessionCreateClaimedAreas` Cloud Function (Admin SDK) writes
  this collection — and unlike most collections in this app, it does *update* existing
  docs in place (shrinking/reshaping them on a steal), not just create new ones. Fields:
  `userId`, `polygon` (MultiPolygon-with-holes, see "What actually gets stored" above),
  `contributions` (capped list of `{sessionId, durationMs, avgPaceMinPerKm, conquestDate}`
  — every run that built current ground into this area), `startLocality` (nullable),
  `geohash` (spatial index for the claim function's own candidate queries — see above),
  `createdAt`/`updatedAt` (client sync now keys off `updatedAt`, not `createdAt`, since
  areas mutate), `deleted` (tombstone flag; a client-visible "gone" signal in place of an
  actual delete, which a client with a stale cache would have no way to detect). No
  `colorHex` — display color is viewer-relative (mine vs. not), computed client-side, not
  a property of the area. Owner may still `delete`.
- `runningSessions/{sessionId}` — created by the client with `pointsEarned == 0`; only a
  server process may ever change `pointsEarned`. Also carries `closedLoops` (array of
  `{'points': [...]}` maps), the full breadcrumb `path` (array of GeoPoints — `path[0]` is
  the run's real start point, what territory resolution keys off), and a best-effort
  `startLocality` string. `territoryCity`/`territoryBroad`/`territoryBroadType`,
  `totalAreaM2`/`stolenAreaM2`, `xpFromDistance`/`xpFromArea`/`xpFromStolenArea`, and
  `pointsProcessed` are all server-only the same way (client must omit them on create;
  `firestore.rules` enforces this via `noServerOnlyFields` on create and a
  `diff().affectedKeys().hasAny([...])` guard on update) — all set together by
  `onRunningSessionCreateClaimedAreas` alongside `pointsEarned` (see "XP/points and scoreboard
  territory" above).
- `userStats/{uid}` — fully read-only from the client; only Cloud Functions (Admin SDK)
  write it.
- `favoriteRoutes/{uid_routeId}`, `follows/{followId}`, `notifications/{id}` — mostly
  self-explanatory ownership rules; notifications can only be created server-side, the
  recipient may only toggle `isRead`/`readAt`.

When adding a new collection or field, add matching rules in `firestore.rules` in the
same change — don't rely on "we'll lock it down later".

## Security & performance — non-negotiable

These are explicit, standing requirements from the project owner. Do not trade them off
for convenience, and flag it clearly if a requested change would weaken either.

- Never let the client set values that represent trust/points/ranking (`totalPoints`,
  `pointsEarned`, area ownership, champion status). Those must be computed and written
  server-side (Cloud Functions with the Admin SDK); Firestore rules must enforce this
  on every affected collection, not just the ones that exist today.
- Validate all user-supplied files before upload (see the `ImageUploadService` pattern:
  size cap, extension allow-list, MIME sniffing from magic bytes, extension/content
  cross-check) — replicate this rigor for any new upload path.
- Don't add real-time Firestore listeners where a one-time read is sufficient; prefer
  the cache-and-invalidate pattern used in `RouteRepository`/`ClaimedAreaRepository` to
  control read costs and battery/network usage on a run-tracking app where the user may
  be mid-workout.
- Avoid composite Firestore indexes where client-side sorting of an already-small result
  set is cheaper (see `RouteRepository.fetchUserRoutes`) — but don't over-apply this to
  large collections.
- Location and background GPS handling (needed for live-session tracking) must request
  only the permissions actually needed and degrade gracefully when denied.
- Never commit secrets. `uploader/serviceAccountKey.json` is gitignored — keep it that
  way, and follow the same pattern for any new service-account or private key files.
- Never embed a third-party API key/token as a source-code constant in the client (this
  is what the "Resolved security debt" section below used to look like — don't
  reintroduce the pattern). Default to proxying the call through a Cloud Function that
  holds the key in Secret Manager (the `orsRoute` pattern below). Only fall back to a
  client-held key — via `--dart-define`/`--dart-define-from-file` from a gitignored local
  file, never a literal in source — for something a client must call directly per-request
  at a volume/latency that rules out a backend hop (e.g. map tile URLs), and in that case
  also get it restricted by app bundle id/domain on the provider's dashboard.

### Resolved security debt (kept for context — see the standing rule above; don't reintroduce this pattern)

- **OpenRouteService key** — was a source-code constant in `RoutingService`
  ([lib/services/routing_service.dart](lib/services/routing_service.dart)), shipped in every app build, trivially
  extractable, and drawing on a single shared 2000-req/day quota that freehand drawing
  alone could chain 15+ requests against per stroke (see the route-planning bullet
  above). Now proxied through the `orsRoute` Cloud Function ([functions/routing.js](functions/routing.js)): the
  key lives only in Secret Manager (`ORS_API_KEY`, set via
  `firebase functions:secrets:set ORS_API_KEY`) and is never shipped to a device.
  `orsRoute` rejects calls without `request.auth` (no anonymous/scripted use of the
  quota) and forwards ORS's own HTTP status + JSON body back to the client verbatim, so
  `RoutingService`'s existing 429/`RoutingRateLimitedException` handling and
  `debugPrint`-based diagnostics are unchanged — only the transport moved, from
  `http.get`/`http.post` against ORS directly to
  `FirebaseFunctions.httpsCallable('orsRoute')`. **Follow-up, not yet done**: the key
  value that was committed in git history is permanently compromised regardless of this
  change — rotate it on the ORS dashboard and update the `ORS_API_KEY` secret to match.
- **Jawg tile token** — was a source-code constant in `MapStyle`
  ([lib/config/map_style.dart](lib/config/map_style.dart)). Unlike the ORS key, this one can't move fully
  server-side: `flutter_map`'s `TileLayer` requests tile URLs directly on every pan/zoom,
  and proxying that through a Cloud Function would multiply latency/cost and defeat the
  on-disk tile cache (`CachedTileProvider`) built specifically to cut down on Jawg
  requests — the same reason Mapbox/Google Maps tokens are also shipped inside client
  apps rather than proxied. Instead, the token is simply no longer committed: `MapStyle`
  reads it via `String.fromEnvironment('JAWG_ACCESS_TOKEN')`, supplied at build/run time
  from a gitignored `config/secrets.local.json` (`--dart-define-from-file`, already wired
  into `.vscode/launch.json`'s three run configs; `config/secrets.example.json` is the
  committed template new developers copy). **Follow-up, not yet done**: restrict the
  token by app bundle id/domain in the Jawg dashboard (the actual mitigation for a
  necessarily-client-embedded tile token — not proxying, which the paragraph above rules
  out here), and rotate the token that was committed in git history, updating
  `config/secrets.local.json` (and every other developer's own copy) once rotated.

## Working conventions

- Some in-app user-facing strings are in Italian (e.g. `ImageUploadService` error
  messages) — match the existing language of the file you're editing rather than
  silently switching to English.
- This list of built vs. planned features should be updated every time a feature lands
  or a new one is scoped, so a fresh session can rely on it instead of re-deriving
  status from a full codebase scan.
