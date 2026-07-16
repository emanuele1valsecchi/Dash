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
- Route planning: pin-dropping or free-draw on the map, road-snapped via OpenRouteService, with distance/time/calorie estimation, undo/redo history, loop-area detection ([lib/screens/route_create_page.dart](lib/screens/route_create_page.dart), [lib/services/routing_service.dart](lib/services/routing_service.dart), [lib/utils/geometry_utils.dart](lib/utils/geometry_utils.dart)).
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
  onto the `claimedAreas` docs it creates. This is deliberately just the raw locality, not
  a "city" grouping: the intended future scoreboard groups nearby towns under a broader
  city (e.g. Seregno under Milan) using this raw value, but that grouping logic doesn't
  exist yet and isn't this codebase's concern until the scoreboard is actually built.
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
- Point-awarding (no Cloud Function sets it yet — `runningSessions.pointsEarned` and
  `profiles.totalPoints` are server-authoritative by rule but nothing currently writes
  them server-side; every session is saved with `pointsEarned: 0`).
- Champion re-timing: re-running the same loop *faster* than whoever currently holds it,
  without necessarily overwriting their territory. Spatial overlap — a new loop's ground
  taking over someone else's claimed area — **is** now handled (see "Area claiming,
  with real territory interaction" above); champion status is a separate, still-unbuilt
  mechanic layered on top of ground you may not even be contesting.
- The scoreboard itself, and the "broad city" grouping it needs (e.g. treating Seregno as
  part of Milan) built on top of the raw `startLocality` value described above.
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
  `{'points': [...]}` maps) and a best-effort `startLocality` string.
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

### Known security debt — fix opportunistically, don't introduce more like it

- `RoutingService` hardcodes the OpenRouteService API key as a source-code constant
  ([lib/services/routing_service.dart](lib/services/routing_service.dart)). This key is shipped in every app build and is
  trivially extractable. It should be moved behind a backend proxy (e.g. a Cloud
  Function) or at minimum loaded from a non-committed config/secret store with key
  restrictions on the ORS side. Don't copy this pattern for any new third-party API key.
- `MapStyle` hardcodes the Jawg access token the same way ([lib/config/map_style.dart](lib/config/map_style.dart)) —
  same debt as the ORS key above. At minimum, restrict the token by app bundle
  id/domain in the Jawg dashboard; longer term, move both this and the ORS key to a
  non-committed config/secret store.

## Working conventions

- Some in-app user-facing strings are in Italian (e.g. `ImageUploadService` error
  messages) — match the existing language of the file you're editing rather than
  silently switching to English.
- This list of built vs. planned features should be updated every time a feature lands
  or a new one is scoped, so a fresh session can rely on it instead of re-deriving
  status from a full codebase scan.
