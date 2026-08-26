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
- A loop that overlaps the runner's *own* existing territory is merged into it, expanding
  that area rather than creating a second one beside it.
- During a run Dash gives turn-by-turn directions (if a planned route is active) and shows
  elapsed time, distance, pace, and the area claimed so far.
- A stats/profile area shows weekly runs, average speed, total time, longest route, etc.

## Implementation status

Keep this list current — update it whenever a feature moves between these buckets.

**Built:**
- Email/password + Google Sign-In auth ([lib/services/auth_service.dart](lib/services/auth_service.dart)), session persisted via `FirebaseAuth.authStateChanges` so the user isn't asked to log in every launch ([lib/main.dart](lib/main.dart)).
- Onboarding, registration, profile setup flow ([lib/screens/onboarding_screen.dart](lib/screens/onboarding_screen.dart), [lib/screens/user_setup_screen.dart](lib/screens/user_setup_screen.dart)).
- Map exploration page ([lib/screens/explore_page.dart](lib/screens/explore_page.dart)) — its map gestures
  (two-finger rotate/zoom feel) come from `EnhancedMapGestures`, shared by every interactive
  map screen; see the bullet below.
- Route planning: pin-dropping (tap the map) or freehand drawing (press-and-drag a
  finger across the map) on the map, road-snapped via OpenRouteService, with
  distance/time/calorie estimation and undo/redo history
  ([lib/screens/route_create_page.dart](lib/screens/route_create_page.dart), [lib/services/routing_service.dart](lib/services/routing_service.dart), [lib/utils/geometry_utils.dart](lib/utils/geometry_utils.dart)). A route
  isn't limited to a single closed loop — placing more pins (or, previously, hitting a
  block) after one closes now continues the route, and each additional loop the path
  goes on to close is kept, not overwritten (`_loopPolygons`/`_loopAreasM2`, both lists,
  paired with `_loopRangeStart`/`_loopRangeEnd` recording the `_segments` index range
  each polygon spans). Self-intersection/snap-to-waypoint checks are run against the
  *entire* route every time, not just segments added since the last loop closed — an
  earlier version scoped the search to only the newest segments specifically to stop a
  new segment matching its own just-finalised loop, but that also meant a bigger loop
  drawn around an already-closed smaller one, or a new line crossing back into an
  earlier loop's own boundary, could never be detected at all, only by snapping all the
  way back to that shape's original starting pin. The shared-junction false-positive
  concern turned out to only ever apply to the single literal previous segment (routing
  always continues from the current tip, so no other, older segment can share an exact
  coordinate with a new one) — trimming vertices near *that* segment's end is enough,
  and every other, older segment is genuinely separate geometry where a match is a real
  crossing. When a new segment produces more than one valid crossing, the one enclosing
  the *largest* polygon wins (`_checkSelfIntersection`), not whichever was found first —
  and a newly-finalised loop supersedes (removes) any already-recorded loop whose own
  segment range overlaps its own, since the new one — built by walking as far back along
  the route as still validly closes — is always at least as large as anything sharing
  its ground. Deleting any pin still conservatively clears every loop closed so far,
  rather than trying to work out which ones a given deletion actually invalidated (no
  re-detection pass runs afterward, even though the rebuilt bridge segment could in
  principle re-trigger some of them). **Snap-to-waypoint closes go through the same
  search, not just the direct target**: tapping back onto an *earlier* waypoint
  (`_routeAndCloseAtWaypoint`) used to always build its polygon by walking from that
  waypoint straight to the tip (`_polygonFromWaypointIndex`), even though the new
  closing segment it just added is exactly the kind of segment `_checkSelfIntersection`
  already knows how to search — so if that closing line also cuts back through even
  *earlier* ground than the snap target itself (e.g. closing to a middle pin with a line
  that happens to pass through the route's actual start pin, leaving a dangling
  unclaimed tail before that middle pin), the bigger polygon was silently missed.
  `_routeAndCloseAtWaypoint` now also runs `_findBestSelfIntersection` (the search
  logic factored out of `_checkSelfIntersection` for exactly this reuse) and keeps
  whichever of the two candidates encloses more area. That search itself gained a third
  strategy alongside vertex proximity and geometric edge crossing:
  `GeometryUtils.pointToSegmentDistanceMeters` catches a real waypoint sitting exactly
  *on* another edge's interior — distinct from a true transversal crossing, which
  `segmentIntersection` deliberately excludes right at a segment's own endpoint (to
  avoid false positives at shared junctions), which is exactly where "a vertex lies on
  this line" registers. Without it, a closing line passing precisely through an earlier
  pin (collinear, not crossing at an angle) still wouldn't be found even with the
  waypoint-snap search wired in. Freehand drawing is one-shot per route — only usable
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
  conversion is a single undo step, not one per sampled point. Every waypoint — including a
  drawn shape's interior road-snap samples, not just its start/finish — renders a pin marker,
  so any of them can be grabbed for drag-to-edit (see below); an earlier version hid interior
  drawn-segment points to avoid cluttering the map with one pin per sample, but that also made
  them impossible to individually adjust, so the hiding was removed in favour of always-visible,
  always-editable pins. **Known limitation**: this is retry/reach-ahead tuning on top of
  point-to-point routing, not true map-matching — if two consecutive samples end up on
  opposite sides of a large obstacle with no reasonably short walkable connection, ORS may
  produce a long real detour (correct, but visually surprising) rather than a shortcut, and a
  region with no network connectivity (or one that's genuinely rate-limited for a sustained
  stretch) to fall back on will still end up with straight-line hops. All area displays
  app-wide (loop-closure banners, claimed-area details, run results)
  show one consistent unit, with decimal precision scaling by magnitude
  (`UnitFormatter.area` — was `GeometryUtils.formatAreaKm2` before units became
  user-selectable) rather than switching between m²/ha/km² by size.
- **Pin drag-to-edit** on the route-creation map: long-pressing any waypoint pin (pin-dropped
  or drawn — see above) turns it yellow and lets it be dragged to a new spot; releasing
  re-routes only the segment(s) touching that pin (`RouteCreatePage._movePin`), reusing the
  same fetch-with-straight-line-fallback pattern `_deletePin`'s middle-pin bridge already used,
  rather than anything new. A translucent straight preview line stands in for the real segment(s)
  for the duration of the drag and the re-route that follows it (`_dragPreviewSegments`), the
  same visual device already used for "straight-line preview while ORS call is in flight" on a
  freshly-placed tip pin. A drag's `globalPosition` is converted to a `LatLng` via the map's own
  `RenderBox` (anchored by a `GlobalKey` on the `EnhancedMapGestures` wrapper, which — being a
  bare `Listener` around `FlutterMap` with no size of its own — shares the map's exact bounds)
  and `MapCamera.offsetToCrs`, since a marker's own local gesture coordinates are relative to its
  small 36×36 hit box, not the map. Unlike `_deletePin` (which shifts every later waypoint's
  index and so conservatively wipes every closed loop with no re-detection), a move keeps every
  index stable, so only loops reaching into the touched segment(s) are dropped
  (`_clearLoopsOverlappingRange`) and re-detection runs scoped to just those segment(s)
  afterward (`_checkLoopsAfterPinMove`/`_findLoopThroughSegment`) — a move can close a brand new
  loop, or re-close a bigger/smaller one, exactly like placing a new pin can. This reuses the
  same "biggest enclosed polygon wins" three-strategy search (vertex proximity, geometric edge
  crossing, vertex-on-edge) `_checkSelfIntersection`/`_findBestSelfIntersection` already run for
  a freshly-appended segment, generalized (`_findLoopThroughSegment`/`_polygonBetweenSegments`)
  to a segment that can sit anywhere in the route rather than always at the tip — kept as
  entirely separate methods, so the original tip-only search (and everything built by tapping or
  drawing) is untouched. Blocked in delete mode (where a pin tap already means something else)
  and while any other async route mutation is in flight (`_canDragPins`). Discoverability: the
  first time a pin ever lands on the map (tap, search selection, or a completed drawing —
  `_maybeShowPinDragHint`, called from `_onMapTap` and `_convertDrawingToRoute`'s success case),
  a snackbar reads "Tip: hold and drag a pin to move it." Shown at most once, ever — gated on a
  `SharedPreferences` bool (`route_create_pin_drag_hint_seen_v1`), not per-route or per-session
  state, so it survives clearing the route or leaving and re-entering route creation.
- **Shared place search** ([lib/services/place_search_service.dart](lib/services/place_search_service.dart), `PlaceSearchService`) — Nominatim
  (primary) + an Overpass POI fallback for informally-named places Nominatim's address
  search misses (e.g. "Edificio 25 Polimi"), re-ranked client-side by a strict
  lexicographic sort — text-match quality, then a coarse tier of Nominatim's own
  `importance`, then proximity, each only a tiebreaker for the one before it — not a
  weighted sum, which failed on real cases (a village named "Londo" outranking London on
  text match; London, Ontario outranking London, England on a summed score). Exposed as a
  `Stream<List<Place>>` (`PlaceSearchService.search`) rather than a single `Future`
  specifically so callers can show Nominatim's own results the instant they arrive (a
  plain search typically resolves in well under a second) as a first emission, then a
  second, merged emission if the slower Overpass fallback (only tried when Nominatim
  returned fewer than 3 results — measured anywhere from ~7s-504 to 37s for the same shape
  of query on the public instance) turns up anything new — **non-blocking**, never gating
  what's already on screen. Used by all three screens below so they share identical
  search behaviour instead of drifting apart; each caller does its own staleness check
  (has the field's text moved on to a different query since this emission?) around the
  stream, since that's inherently per-field state the service itself can't know about.
- Place search on the route-creation map's top bar: while the field is focused, the
  whole page becomes a full-screen white takeover (map/sheet/buttons all covered) with
  the results list filling the remaining space, rather than a small dropdown — all
  search state (controller, focus, debounce) lives directly on `_RouteCreatePageState`
  rather than a separate widget, since the results list is a `Stack` sibling of the
  search field, not a descendant of it; only the fetch/rank logic itself is the shared
  `PlaceSearchService` above. Selecting a result flies the camera there (`_flyTo`, see
  below) and also drops a pin at that spot via the same `_onMapTap` pin logic a real map
  tap would use.
- Place search on the Explore page's top bar (`lib/screens/explore_page.dart`) — the same
  `PlaceSearchService`/ranking and full-screen white-takeover UI as route creation's search
  above (state living directly on `_ExplorePageState` the same way, for the same reason),
  ported from an earlier, much simpler single-Nominatim-result "search a city" bar. Two
  differences from route creation's version, both specific to what Explore actually needs:
  selecting a result plain-moves the camera there (`MapController.move`, no `_flyTo` dip
  animation — not carried over, since only route creation asked for that flourish) and, in
  place of dropping a route waypoint, drops a small standalone `_SearchResultPin` marker at
  the result (`Marker.alignment: Alignment.topCenter`, so the icon's bottom tip lands
  exactly on the point rather than its center) and re-derives `_activeCityFilter` (what the
  leaderboard button reads) via `_updateCityForCurrentLocation` on the selected point —
  reusing the same reverse-geocode already used for "current GPS position → current city"
  — rather than the old behaviour of just capitalizing whatever text was typed, which broke
  down for a multi-word or partial query. The pin persists until the next selection
  replaces it; nothing currently clears it early (e.g. clearing the search field). It's
  drawn with no drop shadow: an earlier version added one via `Icon.shadows`, but that
  paints through `TextStyle`'s own shadow mechanism, which — for reasons not fully pinned
  down, but consistently reproducible — doesn't get repositioned every frame as flutter_map
  moves the marker during a pan, leaving the shadow visibly stuck at the screen position
  the marker first appeared at (dead center, right where the post-selection
  `MapController.move` had just centered the camera) while the icon itself moved normally.
  `BoxShadow` (the mechanism `_LocationDot` below uses successfully, tied directly to a
  `Container`'s own paint) doesn't have this problem, but needs a boxy shape to decorate
  and so doesn't suit a teardrop pin glyph — simplest fix was just not drawing a shadow.
  The close button that replaces the leaderboard button while search is active (top bar has
  no other "back" affordance the rest of the time) uses the same circular white-button
  treatment as route creation's back arrow. Explore also raises `PlaceSearchService`'s own
  defaults — `limit`/`rawLimit` both to 20 (`_searchResultsLimit`), vs. the defaults of
  10/15 that route creation and route search still use — since a browse-the-map page
  benefits more from a longer results list than the route-planning screens do; the service
  method takes both as independent parameters specifically so raising one page's result
  count doesn't affect any other caller.
  **Double-tap-to-open-keyboard bug and its actual fix**: the first tap on the search field
  focused it (confirmed by the white takeover appearing, since that's gated on
  `_searchFocusNode.hasFocus`) but never raised the system keyboard — a second tap on the
  by-then-stable field was needed. The true cause turned out to be one layer *below* the
  outer `Stack`: `_buildTopControls`'s `Row` conditionally prepends a close button in place
  of the leaderboard button, which shifts `Expanded(child: _buildSearchField())`'s *index*
  in that Row's children the instant `_searchActive` flips — and `Row`, like `Stack`,
  reconciles unkeyed children by index, not identity. That index mismatch tore down and
  recreated the `TextField`'s element in the very same `setState` triggered by the focus
  change that was *also* supposed to raise the keyboard — destroying the in-flight
  keyboard-show request before it could complete. Giving `Expanded` a stable `key` (it
  takes one directly — no `KeyedSubtree` wrapper, since `Row`/`Column` only recognize
  `Expanded`/`Flexible` sizing on *direct* children) let Flutter match it by identity
  across the index shift and update in place instead of rebuilding it. Keying the outer
  `Stack`'s children (kept, since it's correct and harmless) turned out not to be the actual
  fix — the real bug was always one level deeper, on the `Row` directly wrapping the field.
  Worth remembering if a similar "focus works but the keyboard doesn't" report shows up
  elsewhere: check the *narrowest* conditionally-reordered ancestor of the field, not just
  the outermost one. Route creation's search has a similarly-shaped conditional top bar
  and hasn't been audited for the same issue — check there too if it's ever reported.
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
- **Two-finger rotate with a persistent dead zone, plus a little zoom inertia** —
  `EnhancedMapGestures` ([lib/widgets/map/enhanced_map_gestures.dart](lib/widgets/map/enhanced_map_gestures.dart)), wrapping every
  interactive map screen's `FlutterMap` (explore, route create/search, run tracking, test
  run creator — not the small static map-preview card on run tracking's finish summary,
  which uses `InteractiveFlag.none` and has no gestures to enhance in the first place). Each
  wrapped screen also disables flutter_map's own rotate handling in its own
  `MapOptions.interactionOptions` (`flags: InteractiveFlag.all & ~InteractiveFlag.rotate`,
  adjusted for whatever else that screen already restricts — e.g. route create/test run
  creator drop pan during freehand-draw mode, run tracking never allows pan at all), and
  (all screens using `InteractiveFlag.all`, including `session_detail_screen.dart` which
  isn't wrapped by this widget) excludes `InteractiveFlag.flingAnimation` — see the third
  refinement below. Three refinements flutter_map doesn't offer/get right on its own:
  - **Rotation.** This was investigated at length on the explore page before landing here,
    and the history matters if anyone's tempted to reach for flutter_map's own
    `enableMultiFingerGestureRace` again: turning it on gates *starting* to move behind
    whichever of `rotationThreshold`/`pinchZoomThreshold` is crossed first, which stops an
    ordinary pinch from also rotating — but flutter_map's race picks one winner *per whole
    gesture*, not continuously (`pinchZoomWinGestures`/`rotationWinGestures` default to
    excluding each other). Merging those win-gesture fields let both zoom and rotate apply
    together, but then rotation's threshold only ever gated the *very first instant* —
    once anything won (and with a zoom threshold tiny enough to stay smooth, zoom always
    won almost immediately), rotation applied at full, un-gated sensitivity for the rest of
    the touch, indistinguishable from the original bug. **No combination of flutter_map's
    own `InteractionOptions` fields can express "always-smooth zoom + a persistent,
    whole-gesture rotation dead zone that doesn't lock zoom out"** — a hard limitation of
    its one-shot winner-take-all model, not a tuning problem. The actual fix: track
    rotation independently via a plain `Listener` (observes raw pointer events without
    competing in the gesture arena, so it can't conflict with flutter_map's own zoom/pan
    handling). It tracks the first two fingers by pointer id; with exactly two down,
    `_rearmOrClearRotationTracking` records a base angle and the map's current rotation,
    and clears/restarts on any other finger count (a third finger clears tracking entirely
    rather than risk silently re-basing onto a different pair). Each move recomputes the
    angle delta since that base and applies a **continuous, whole-gesture** dead zone
    (`rotationThresholdDeg`, currently 8° everywhere) — below it nothing rotates; once
    crossed, the threshold amount is subtracted from the delta (crossing direction's sign
    fixed at the moment of crossing, not re-evaluated per frame) so rotation picks up
    smoothly from zero rather than jumping ahead by the dead-zone amount — independent of
    whatever zoom/pan is doing at the same time, so pinching and twisting together works as
    one continuous motion.
  - **Zoom inertia.** flutter_map has fling/momentum for panning but none for pinch-zoom —
    lifting fingers mid-pinch used to just stop dead. Samples the zoom level (via
    `MapController.camera.zoom`, polled on every multi-finger pointer move — not a
    `mapEventStream` subscription, since the raw pointer callback already fires at the same
    cadence and needs the finger positions anyway for rotation) during any 2+-finger touch,
    keeping only the last ~150ms of samples; on release, estimates a velocity from those and,
    if fast enough (`_minInertiaVelocity`), animates a short (`_inertiaDuration`, 220ms),
    hard-capped (`_maxInertiaZoomLevels`, 0.5 zoom levels) continuation around the same focal
    point via `MapCamera.focusedZoomCenter` — deliberately subtle, not a full physical fling.
    Any new touch (even a single finger) cancels a still-running inertia animation.
  - **Multi-touch release jump (a real Flutter/flutter_map bug, not something introduced by
    this app).** A fast pinch released with the two fingers lifting even a few ms apart
    (no real touch ever lifts both at the *exact* same instant) made the map jump sideways
    in a seemingly-random direction in addition to the zoom, which was otherwise correct —
    on both pinch-in and pinch-out. Root-caused against the actual Flutter SDK
    (`packages/flutter/lib/src/gestures/scale.dart`, `ScaleGestureRecognizer`): its focal
    point is the live average of *currently touching* pointers, recomputed synchronously
    the instant a pointer is removed — jumping from "midpoint of two fingers" to "position
    of the one remaining finger" in a single step — and it fires `onUpdate` with that
    jumped value immediately, in the same event that removed the pointer. flutter_map's own
    pan math (`MapInteractiveViewerState._calculatePinchZoomAndMove`) consumes that absolute
    focal point directly, turning the discontinuity into a real camera pan; the same
    discontinuity can also corrupt the gesture's end-of-touch velocity reading, risking an
    independent, similarly "random" native fling. Confirmed via flutter_map's own issue
    tracker that gesture-velocity corruption around multi-touch release is a known category
    of bug there (e.g. fleaflet/flutter_map#2225, a related but distinct regression from a
    later version this app doesn't use). Not fixable by simple composition — a `Listener`
    observes pointer events without competing in the gesture arena, so it can't cancel or
    filter events flutter_map's own recognizer has already claimed. The fix:
    `EnhancedMapGestures` continuously remembers the camera's center/zoom while a genuine
    2+-finger touch is ongoing (`_lastStableCenter`/`_lastStableZoom`), then the instant the
    touch drops below 2 fingers, `_settleMultiTouchRelease` restores the camera to that last
    known-good state and *then* starts zoom inertia (point 2 above), both inside one
    `scheduleMicrotask` in that fixed order — late enough to run after whatever flutter_map's
    recognizer just did to the camera synchronously, but still before that frame is ever
    built/painted, so the jump is never actually visible. The correction and the inertia
    kickoff used to be two independent actions and would race — the correction's one-time
    `.move()` and the inertia animation's own recurring `.move()` calls both mutate the same
    camera, and whichever landed last for a given frame won, which was silently canceling
    the inertia animation's visible start entirely; combining them into one strictly-ordered
    microtask removes that race by construction. Separately, native fling (single-finger drag
    momentum, a real, wanted feature — `InteractiveFlag.flingAnimation`) stays enabled rather
    than blanket-disabled, since flutter_map can't distinguish "fling from a clean drag" from
    "fling from the corrupted multi-touch velocity" via a flag alone; an earlier version of
    this fix disabled it outright and lost ordinary momentum panning as collateral damage.
    Instead `_multiFingerDropTime` records when a touch last dropped below 2 fingers, and if
    the *final* release (all fingers up — the actual moment flutter_map's recognizer decides
    whether to fling, per `didStopTrackingLastPointer`) follows within
    `_flingCorruptionWindow` (300ms), `_cancelAnyNativeFling` fires one more
    `_lastStableCenter`/`_lastStableZoom` move — being a real move via the public
    `MapController` API (tagged `MapEventSource.mapController`), this makes flutter_map's own
    `MapControllerImpl._emitMapEvent` → `interruptAnimatedMovement` stop the fling as a side
    effect, without touching the `InteractiveFlag` at all. A plain single-finger drag never
    sets `_multiFingerDropTime`, so its fling is never touched. `session_detail_screen.dart`
    isn't wrapped by `EnhancedMapGestures` (no rotation dead zone there, and no cancellation
    mechanism available), so it keeps `InteractiveFlag.flingAnimation` disabled outright —
    losing its own pan momentum is the accepted trade there in exchange for not needing to
    wire up the full mechanism on a screen with a bounded, small-scale camera to begin with.
- Route search/discovery by parameters ([lib/screens/route_search_page.dart](lib/screens/route_search_page.dart)). Its
  start/destination/stop address fields (`_AddressInputField`) use the same shared
  `PlaceSearchService` as the route-creation search bar (see above) for suggestions —
  biased/ranked toward the field's `near` (the user's current GPS position) — rather than
  the plain single-call Nominatim lookup they originally had, so an informally-named
  destination resolves here the same way it would on the creation map. The bottom sheet
  (`DraggableScrollableSheet`) drags from anywhere on its handle+header, not only from
  within the scrollable form content below — that chrome sits outside the `ListView`
  driving the sheet's own built-in scroll-linked drag, so without a manual
  `onVerticalDrag*` handler wired to `_sheetController` there it would be inert (see
  `_onHeaderDragUpdate`/`_onHeaderDragEnd`), which is the more natural place a user
  reaches for to resize a bottom sheet. `route_create_page.dart` and
  `test_run_creator_page.dart` build a `DraggableScrollableSheet` the same underlying way
  (handle+header outside the `ListView`) and likely have the same gap — not yet fixed
  there, revisit if it comes up.
  **The form is a two-step wizard** (`_formStep`, 0/1) rather than one long scroll, since
  parameters are meaningless until the shape is decided: step 1 ("Route shape") holds the
  circuit toggle, start/destination/stops; step 2 ("Parameters") holds the
  distance/time/calorie target and, for a closed circuit, laps. A "Next: parameters"
  button advances (no blocking validation — address/pin resolution is async, so the real
  checks stay on the final Search button, same as before this page had steps); step 2 has
  a "Back" button plus the search button. "Edit search" from results mode always returns
  to step 1. Leaving edit mode used to silently clear every intermediate stop
  (`_enterEditMode` disposed/cleared `_stopCtrls`/`_stopLatLngs` on every entry) — fixed;
  it now only resets the results/step state, so stops survive an edit round-trip.
  **Start/destination/stop pins can be placed by tapping the map** instead of typing an
  address, Google Maps-style (`_beginPinPicking`/`_handleMapTapForPinPicking`, wired into
  `_AddressInputField` via an `onPickOnMap` suffix-icon button alongside the existing "use
  current location"/"remove stop" ones). Picking collapses the sheet and shows a
  cancellable banner ("Tap the map to set…"); the tapped point fills the field immediately
  as a placeholder ("Pinned location (lat, lng)") and then again with a real address once
  a best-effort Nominatim reverse-geocode (`_reverseGeocode`) resolves — the resolved
  `LatLng` itself, not this display text, is what search actually uses. This needed one
  fix to `_AddressInputField`'s own text-change listener (`_onTextChanged`): it used to
  invalidate the field's picked `LatLng` on *any* text change apart from its own internal
  suggestion-selection flag, which would have wiped out a pin the instant this
  programmatic set landed. It now also skips invalidation whenever the field isn't
  focused — a real user edit only ever happens while focused, so this cleanly
  distinguishes "the user is typing" from "something external just set this text" without
  a new suppress flag wired in from outside for every such case. Placed pins render as
  persistent map markers (`_planningMarkers` — green pin for start, checkered-flag icon
  for destination, numbered blue badges for stops) so the shape being searched is visible
  before hitting search, not just after.
  **Closed-circuit search now actually uses intermediate stops** — a real bug, not just a
  gap: the auto-loop generator ignored `_resolveStops()` entirely, so a stop placed on a
  closed-circuit search was shown in the form but silently dropped from the result.
  `_generateClosedCircuitRoutes` now branches on whether stops were given: with stops, it
  routes start → stops → back to start directly (`_generateLoopThroughStops`, checked
  against tolerance like a direct A→B route); only with *no* stops does it fall back to
  the bearing/radius auto-guesser (`_generateAutoLoopRoutes`).
  **Laps** are now tied to the closed-circuit toggle only (not to a separately-detected
  "start equals destination" on the plain A→B flow, which was confusing to trigger and
  has been removed) — an optional field in step 2 (`_buildLapsSection`/`_lapsCtrl`,
  defaults to 1 when left blank), shown only when the circuit toggle is on. The
  distance/time/calorie target represents the *total* across every lap: `_search` divides
  it by the lap count to get the per-lap size the loop-finder actually searches for
  (`_generateClosedCircuitRoutes`'s `perLapTargetM`), and `_toFoundRoute`'s `laps`
  parameter multiplies the measured single-loop distance/time/calories back up for
  display — a match against the per-lap target is therefore automatically a match against
  the original total. `_RouteDetailsSheet` labels the result "×N laps" and shows the
  per-lap distance alongside the total.
  **Routing reliability rework** — a found route could previously mask an outright
  routing failure: `RoutingService.fetchRoute`/`fetchAlternatives` silently fall back to
  `RoutingService.straightLine()` on any failure (network error, no route, or a genuine
  HTTP 429 from the shared ORS quota), and the old per-hop `_route()` helper had no way to
  tell a caller that had happened — so a rate-limited hop became an ordinary-looking
  straight edge, stitched into a "found route" cutting across buildings. Root cause:
  tightening `_matchTolerance` (see below) had roughly doubled ORS calls per
  closed-circuit search via an aggressive "refine every out-of-tolerance candidate" pass,
  making the shared quota's rate limit far more likely to trip on repeated searches — the
  reported "worked once, then started producing triangle-shaped routes" pattern. Fixed
  with two new primitives: `_routeHop` (a single ORS leg, returning `{seg, ok,
  rateLimited}` — `ok: false` means this leg fell back to a straight line) and
  `_routeChain` (walks a waypoint list sequentially, stitching hops, stopping early the
  moment a hop reports rate-limiting rather than continuing to burn the shared quota).
  Every route-generation method (`_generateLoopThroughStops`, `_generateAutoLoopRoutes`,
  `_generateDirectRoutes`) now discards any candidate whose chain wasn't fully `ok` —
  never presents a straight-line fallback as a real result — and both call ORS's
  `throwOnRateLimit: true` mode (already used elsewhere; `RoutingService.fetchAlternatives`
  gained the same opt-in flag, plus a new `allowStraightLineFallback` that lets a failure
  return `[]` instead of a masquerading straight line — both default to the original
  behaviour, so no other caller of these shared methods is affected).
  `_generateAutoLoopRoutes`'s own candidate count was also cut — 4 bearings (90° apart)
  instead of 8 (45° apart), and only the single closest miss gets one corrective re-route
  (radius rescaled by the measured ratio) instead of refining *every* miss — bounding
  worst-case ORS calls per search to 4×3 + 3 = 15, down from an unbounded-up-to 8×3×2 = 48.
  A search whose only results were rate-limited away sets `_lastSearchRateLimited`, so
  `_search` can show "The routing service is busy right now" instead of a generic "no
  routes found" when that's what actually happened.
  Matching a generated/found route against a distance/time/calorie target still uses a
  tight `_matchTolerance` (±5%), kept deliberately separate from the much looser
  `_conflictTolerance` (±30%) used to cross-check the user's own time/distance/calorie
  entries against each other in `_deriveTarget` (those three are independently derived
  from magic per-km constants, so they're never expected to agree exactly; the *result*
  shown to the user is a different, much stricter contract).
  **The distance-tolerance filter only ever applies to the auto-generated loop search
  (`_generateAutoLoopRoutes`) — the one case where the app is actively searching a
  parameter space to hit a target.** Every other path's shape is already fixed by the
  user's own waypoints (stops, in either circuit or direct mode; or a plain A→B with no
  stops) and is never rejected for missing the target: two real bugs traced back to
  treating the target as a hard filter there. Reported first: a direct A→B search (no
  stops, no circuit) between two points genuinely less than the target apart returned
  zero results, because none of ORS's alternatives — which are close variants of the same
  trip, not routes that can be grown to hit an arbitrary length — landed inside ±5%.
  `_generateDirectRoutes` now ranks alternatives by closeness to target instead of
  filtering any out, so a real route is always shown (closest match first) rather than
  hidden. The stops-defined paths (`_generateLoopThroughStops` for a closed circuit,
  and `_generateDirectRoutes`'s own stops branch) dropped the tolerance check entirely —
  a manually-placed stop was producing "0 routes found" purely because the real road
  distance through it didn't land in a ±5% band around an unrelated target, which read as
  obviously wrong to a user who placed the stop deliberately.
  **A second, distinct bug**: a closed-circuit search (small per-lap target from splitting
  a total across several laps, e.g. 4 km over 3 laps → ~1.3 km per lap) could return a
  "route" that just went up and down the same road and back — real ORS geometry, correct
  distance, but no actual enclosed area, because the two offset waypoints
  (`_generateAutoLoopRoutes`'s `wp1`/`wp2`) happened to road-snap onto the same street.
  `_enclosesRealArea` catches this: it runs `GeometryUtils.polygonAreaM2` (already used by
  route creation/live tracking for real loop-closure math) against the candidate's own
  closed polyline and rejects anything covering under ~2% of the area a circle with the
  same perimeter would enclose — generous enough that even a lopsided 10:1 rectangle loop
  clears it several times over, but a true out-and-back (which cancels to ~zero area in
  the shoelace-style calculation `polygonAreaM2` uses) does not. Applied to every loop
  candidate — the auto-guesser's first pass, its one refinement re-route, and the
  stops-defined loop — never just the distance check alone. The auto-guesser's own
  candidate count was nudged back up from 4 to 6 bearings (every 60°, up from every 90°)
  now that degenerate candidates are being caught rather than shown, to raise the odds of
  finding at least one real enclosing shape without reintroducing the original unbounded
  call-volume problem. `_lastSearchOnlyDegenerateLoops` distinguishes this case in
  `_search`'s messaging ("could not find a real loop enclosing an area…") from a plain
  rate-limit or a plain no-match.
  **Closed circuit's target requirement is now conditional on stops**: stops fully
  determine a loop's shape (and so its size) on their own, so `_search` only requires a
  distance/time/calorie target when stops are empty (i.e. only the auto-guesser, which
  actually needs a size to search for, is gated on it) — `_hasStopsEntered` is the
  synchronous proxy used for this and for steering the parameters-step hint text, since
  the real `_resolveStops()` is async and the hint has to render before that resolves.
  **Three follow-up fixes after live testing surfaced more gaps**:
  - **A single stop can't form a real loop the way 2+ stops naturally do.** `start → stop
    → start` is definitionally an out-and-back unless the return leg is deliberately
    routed differently from the outbound one — ORS's plain shortest path each way almost
    always retraces the same street regardless of how dense the surrounding road network
    is, which is exactly the degenerate shape `_enclosesRealArea` rejects, so a one-stop
    loop was reliably returning zero results. `_generateSingleStopLoop` now routes the
    outbound leg normally, asks ORS for alternative *return* routes (`fetchAlternatives`),
    and pairs the outbound with whichever return alternative encloses the most real area —
    only reporting "no real loop" if none of them do (a dead-end street or single bridge
    with no parallel way back, which does happen and is a genuine dead end, not a bug).
  - **A closed-circuit search failed at longer targets (worked at ~3 km, failed at 10 km)
    that had worked at shorter range.** Two contributing causes, both addressed: a single
    ORS hop taking noticeably longer to compute for a multi-km leg was more likely to trip
    a plain (non-429) failure under load — `_routeHop` now retries once on an ordinary
    failure before giving up, at no extra cost on the (typical) success path. Separately,
    `_generateAutoLoopRoutes`'s corrective refinement went from one attempt to up to two —
    the gap between the straight-line radius estimate and the real road-network detour
    ratio grows, and gets less predictable, the further out it reaches, so a single linear
    correction that reliably closed a short-range miss wasn't always enough at longer
    range (worst case now 6×3 + 2×3 = 30 ORS calls, still well under the original
    version's unbounded-up-to 48).
  - **A direct A→B search with a target longer than the trip's natural distance was
    silently ignoring the target entirely** — e.g. "4 km between two points 1.3 km apart"
    just returned the natural ~1.3 km alternatives, because ranking-by-closeness (the
    previous fix for zero-results) has no way to *lengthen* a trip, only reorder what ORS
    already offered. `_generateDirectRoutes` now tries `_generatePaddedDirectRoutes` first
    whenever none of ORS's own alternatives land near the target: it builds a detour via
    one synthetic waypoint, bulging perpendicular to the direct start→end line by just
    enough (solved via Pythagoras on the straight-line isosceles triangle) to reach the
    target, tries both sides of the line in parallel, and refines whichever comes closer
    (up to twice, same rescale-by-measured-ratio approach as the loop generator) if
    neither hits tolerance outright. Only falls through to the old rank-by-closeness
    behavior if padding genuinely isn't applicable (target shorter than the natural trip —
    a detour only ever adds distance, it can't be the fix there) or doesn't pan out (road
    network doesn't support a detour of that shape either side).
  **Client/server ORS timeout mismatch, found while writing a diagnostic handoff report for the
  10 km failure above (not yet re-verified live)**: [lib/services/routing_service.dart](lib/services/routing_service.dart)'s
  `fetchRoute`/`fetchAlternatives` Firebase Callable timeouts were 10s/12s, while
  [functions/routing.js](functions/routing.js)'s own `ORS_TIMEOUT_MS` (its fetch-to-ORS timeout, shared by both
  `orsRoute` modes) is 12s — meaning the client could give up and throw *before or right as* the
  Cloud Function itself would, and that timeout was indistinguishable from an ordinary "no route
  found" failure to `RoutingService.fetchRoute`'s catch-all. Longer legs (radius scales with
  target distance) are more likely to approach that window, which would explain "works at 3 km,
  fails at 10 km" without any bug in the search/candidate logic itself — and would explain why
  `_routeHop`'s retry-once didn't help, since retrying a systematically-too-slow leg just times
  out again the same way. Both client timeouts are now a shared `_callTimeout = Duration(seconds:
  18)` constant, leaving margin over the server's 12s; `ORS_TIMEOUT_MS`'s declaration now carries
  a comment cross-referencing the client value so the two can't silently drift apart again. Shared
  code with route creation (`fetchRoute` is also called from `route_create_page.dart` and
  `test_run_creator_page.dart`) — raising a timeout can only let a slow-but-eventually-successful
  call complete, never change behavior for one that was already fast, so this was assessed as safe
  there too, but that's by construction, not a live-verified claim.
  **Route-generation rework: native ORS round trips + shared leg padding.** Loop
  generation moved off the offset-two-waypoints geometric guesser onto ORS's *native
  round-trip primitive*: [functions/routing.js](functions/routing.js)'s `orsRoute` gained a third mode
  (`mode: 'round_trip'` → POST with a single coordinate + `options.round_trip
  {length, points, seed}`, same verbatim `{status, body}` forwarding as the other two
  modes, logged as `ors-directions-roundtrip`), surfaced client-side as
  `RoutingService.fetchRoundTrip`. `_generateAutoLoopRoutes` now fires `_loopSeedCount`
  (4) round trips in parallel — different seeds = different loop directions, ONE ORS call
  per candidate instead of three — and corrects the two closest misses by re-requesting
  with the length rescaled by the measured ratio (same seed, so the loop grows/shrinks in
  place rather than jumping direction): worst case 6 calls where the guesser spent up to
  30, with every candidate grown out of the actual road network instead of hoped onto it
  — candidates can't strand across rivers/highways, and land far closer to the requested
  length (ORS documents `length` as preferred-not-guaranteed, hence the corrective pass).
  The old guesser survives only as `_generateLegacyLoopSegments` (slimmed to 3 bearings),
  run purely as a safety net when *every* round-trip call fails without a 429 — i.e. an
  `orsRoute` deployment predating the new mode — so **deploy functions before shipping
  the app build**, though nothing breaks outright if the order slips. Loop targets are
  honoured *with* stops now too: both loop-with-stops paths route the user-pinned part
  and the closing/return leg separately, and when the target asks for more distance than
  the natural loop provides, the closing leg is re-routed through `_paddedLegCandidates`
  — the padded-detour machinery extracted from `_generatePaddedDirectRoutes` and shared
  with it — sized so the whole loop lands on the target; the natural loop is still shown
  as the honest best answer when padding can't reach it (user-shaped routes are never
  dropped — same standing rule as before). The padding itself got two accuracy fixes:
  the first offset guess divides the target by `_roadWindingFactor` (1.25) before the
  Pythagoras solve (aiming the *straight-line* path at the target guaranteed the measured
  road result overshot by roughly that factor — always outside ±5%, always burning a
  refinement round), and refinement uses an affine model when the natural leg distance is
  known (only the detour part gets rescaled), converging in one round far more often;
  both perpendicular sides now refine *their own* misses in parallel instead of only the
  single best side ever being refined. Near-duplicate results (different seeds, or a
  padded side and a natural alternative converging on the same streets) are collapsed by
  `_dedupeSimilarRoutes` (lengths within 3% + centroids within max(60 m, 2% of length))
  before display; single-stop loops with no target now return up to 3 area-ranked real
  loops instead of exactly one. Direct A→B with stops pads its *final* leg the same way
  when the target exceeds the natural trip. Not yet re-verified live (same standing
  caveat as the timeout fix above) — the `routing-upstream` Cloud Function log now
  includes `ors-directions-roundtrip` lines for exactly this purpose.
  **Save route / Run now**, completing `_RouteDetailsSheet` (previously a "Save coming
  soon!" placeholder): both buttons pop the sheet with a `_RouteSheetAction` (`save`/
  `runNow`) rather than acting directly inside it, so the actual (async, page-level)
  handling runs in `_RouteSearchPageState` — mirrors route creation's own
  `_SaveAction`/`_showSaveOptionsDialog` split for the same reason. **Save** calls
  `RouteRepository.publishRoute` (the same `routes` collection/repository route creation
  writes to — no new collection). A found route has no user-tapped waypoints of its own
  (it's generated, not drawn), so `waypoints` is just the polyline again, the same
  convention `FavoriteRouteRepository` already uses for a favourited run's whole path;
  `isLoop`/`loopAreaM2` come from the page's own `_isClosedCircuit` flag and
  `GeometryUtils.polygonAreaM2(route.polyline)`. The route is auto-named from its own
  stats (`"4.2 km loop"`/`"3.5 km route"`) rather than prompting for a name — renaming is
  left to whatever eventually replaces `TempProfilePage`'s route list (see that bullet
  above: it already reads `RouteRepository.fetchUserRoutes()`, so a route saved from
  search shows up there today, view/delete only — no "Run" action wired up on that list
  yet, still a gap). **Run now** pops the *entire* `RouteSearchPage` with
  the chosen route's polyline as the result (`Navigator.of(context).pop(route.polyline)`),
  exactly like route creation's "Save route and Run" pops `RouteCreatePage` with its
  merged polyline — same navigation shape on purpose, so finishing/discarding the run
  returns straight to the home screen rather than back into stale search results.
  `HomeScreen._searchRoute` was updated to match `_createRoute`'s own shape: it now
  awaits a `List<LatLng>?` from `RouteSearchPage` and, if non-null, pushes
  `RunTrackingPage(plannedRoute: ...)` via the same `_pushRunTracking` helper
  `_createRoute` already used — one shared post-search entry point for both planning
  flows, not two diverging ones. Save and Run now are independent: Run now does not
  save first, so a route can be run without ever being added to the user's saved list.
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
  polygons ([lib/screens/run_tracking_page.dart](lib/screens/run_tracking_page.dart), loop-closure math in [lib/utils/geometry_utils.dart](lib/utils/geometry_utils.dart)). Closure detection
  (`GeometryUtils.findLoopClosureIndex`) searches the *whole* breadcrumb trail on every
  fix, not just points recorded since the last closure, and returns the farthest-back
  qualifying point rather than the nearest one — so it always reports the biggest loop
  currently closable, the same fix applied to route creation's segment-based detection
  above (see that bullet for the full rationale). `_checkLoopClosure` then supersedes
  (removes) any already-closed loop whose own breadcrumb-index range overlaps the new
  one's, keyed on `_loopRangeStart`/`_loopRangeEnd`, so re-detecting a bigger loop around
  the same ground replaces the smaller one instead of piling both on top of each other.
  On finish the user names
  the run and reviews time/distance/avg pace/max pace/calories/elevation before choosing
  Save (persists via `RunSessionRepository` to `runningSessions`, see below) or Discard
  (re-confirms, then nothing is written). The screen only tracks in the foreground — no
  background/lock-screen GPS service is configured. The system/gesture back button is
  intercepted via `PopScope` once a run is actually in progress (`_hasStarted`, set in
  `_beginRun` after the pre-run countdown) and made to behave exactly like tapping
  "Finish" (`_confirmFinish`) — not like the X button's `_confirmDiscard`, which abandons
  the run with no summary. Before a run starts (loading/permission-denied/countdown) back
  still pops normally, matching `_confirmDiscard`'s own early-return for that case. The
  run-summary dialog shown after Finish has its own separate `PopScope(canPop: false)`,
  fully blocking back-dismissal there too — the user must explicitly choose Save or
  Discard.
- **Direction arrow while following a planned route** (`GeometryUtils.routeGuidance` +
  `RouteGuidance` in [lib/utils/geometry_utils.dart](lib/utils/geometry_utils.dart), rendered by `_RouteGuidanceCard` in
  [lib/screens/run_tracking_page.dart](lib/screens/run_tracking_page.dart)) — a compass-style bearing guide, deliberately
  **not** turn-by-turn: it needs no street names, works on any polyline including
  hand-drawn and multi-hop stitched ones, and degrades to "head that way" rather than
  failing. Real turn-by-turn would need ORS's `steps` (returned by the API but discarded
  in `RoutingService`'s parse) *and* a way to concatenate instruction lists across the
  many separate ORS calls a searched/drawn route is stitched from — not attempted.
  The arrow rotates to the target bearing *relative to* the runner's heading, using the
  smoothed `_displayedHeading` the map dot uses rather than raw `_lastHeading`; when
  heading is unavailable (stationary, or below `_minSpeedForHeadingMs` where GPS
  course-over-ground is meaningless) the card drops to a neutral "getting your bearing"
  state instead of pointing confidently nowhere. Guidance is computed against the raw
  `widget.plannedRoute`, never `_smoothedPlannedRoute`, for the same reason distance and
  proximity checks are. **The non-obvious part is `previousSegmentIndex`**: nearest-point
  matching alone breaks on exactly the routes Dash cares most about, since a closed loop
  runs back past its own start — a runner finishing a lap matches segment 0 again and is
  told to run the whole loop over. The caller feeds the last matched segment index back
  in, restricting the search to a window; the hint is abandoned for a full re-scan
  whenever nothing in that window is within the off-route threshold, so genuinely leaving
  the route and rejoining elsewhere still re-acquires. Off-route (> 25 m from the line,
  generous enough for GPS error plus the far pavement of a wide road) points the arrow
  *back at* the nearest point on the route rather than further along it, and fires
  `HapticFeedback.heavyImpact` once on the transition — felt, not read, since the whole
  point is not having to look at the screen. `pointToSegmentDistanceMeters` was refactored
  to delegate to a shared `_projectOntoSegment` (identical math, now also returning the
  projection parameter `t`) so loop detection and the arrow can't drift apart.
  **Next-turn distance** (`_findNextTurn`, surfaced as `RouteGuidance.distanceToTurnMeters`
  / `turnAngleDegrees`, headlined by the card as "Turn left in 80 m" with distance-remaining
  demoted to the subtitle) is derived from the polyline's own geometry for the same reason
  the arrow is. It scans **evenly-spaced 5 m samples, never vertices** — vertex spacing
  carries no meaning, since a road-snapped polyline rounds a corner with a dozen vertices
  each turning a few degrees while a hand-tapped route turns 90° at one vertex — comparing
  bearings measured over a fixed 20 m baseline so both read alike and GPS-scale wobble is
  rejected for free. Two non-obvious details, each with a regression test: the reported
  *distance* is the threshold crossing (35°, where the turn starts to matter) but the
  reported *angle* is the turn's peak, because the bearing window trips as it only begins
  to span the corner — a true 90° corner reads ~45° at that instant and would be labelled
  "Bear left" instead of "Turn left" (the two split at 70°). And the peak scan stops on a
  **plateau**, not on a decrease: a loop turning the same way at every corner climbs
  90°→180°→270° monotonically, so breaking only on a decrease swallows every later corner
  into the first one. Covered by `test/route_guidance_test.dart` (12 tests). The arrow,
  off-route buzz and loop-finish behaviour were **confirmed on a real device** (Android,
  outdoor GPS run); the turn indicator was added afterward and has **not** been.
- **`RunSessionController`** ([lib/services/run_session_controller.dart](lib/services/run_session_controller.dart)) — owns everything about a
  live run: the clock, the GPS stream, the breadcrumb trail, distance/pace/altitude,
  closed-loop detection and planned-route guidance. `RunTrackingPage` is now purely the UI
  on top of it and owns none of that state; what stays on the screen is the map camera,
  the dot-smoothing chase (`_displayedPosition`/`_displayedHeading`/`_trailPoints`/
  `_onDotTick`), water fountains, claimed areas, the 10 Hz `_uiTicker` repaint pulse, and
  all dialogs/formatting. Extracted specifically to unblock the smartwatch work and
  background tracking — both need run state addressable without a `RunTrackingPage` alive.
  A **singleton** (`RunSessionController.instance`, matching `LocationService.instance` /
  `WaterFountainService.instance`), so a run *can* outlive its screen. **Nothing exercises
  that yet**: `RunTrackingPage.dispose` still calls `reset()`, so leaving the screen ends
  the run exactly as it always did, and the back button still behaves as Finish. Removing
  that one `reset()` call is what will enable minimize-and-keep-running, once a foreground
  service exists to keep GPS alive. Never call `dispose()` on it — it's app-lifetime.
  **The singleton's one genuine hazard is a missed `reset()`**: a second run would inherit
  the first's breadcrumbs and go on to claim ground nobody ran. `reset()` is therefore
  called from `initState` (defensively, before anything touches it), from `dispose`, and
  from the permission-retry path; two tests in `test/run_session_controller_test.dart`
  exist purely to pin that down. The extraction was deliberately **behaviour-preserving** —
  the tracking core moved close to verbatim, which was safe because `_onPosition`,
  `_updatePace` and `_checkLoopClosure` already contained no `setState`/`context`/`mounted`
  (the `_uiTicker` drove rebuilds independently); only `setState` calls in the countdown and
  pause controls became `notifyListeners()`. Two deviations from a pure move: `_isFinishing`
  stayed on the page (it guards a `Navigator.pop`, not run state), and `_initLocation`'s
  permission-plus-first-fix became `controller.prepare()` while the proximity-warning dialog
  stayed on the page (it needs `context`). The page learns about new fixes by comparing
  `breadcrumb.length` against its own `_lastBreadcrumbLength` in the listener, since the
  controller notifies for many reasons and only a genuine new fix should advance the map
  trail. `onPosition` is `@visibleForTesting` so synthetic fixes can drive the whole
  pipeline with no device. Still **not** done, each deliberately separate: foreground
  service/background GPS, the watch bridge, crash-recovery persistence, back-to-minimize,
  and collapsing the five lifecycle booleans into a phase enum.
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
  there is now only one map style, no picker. Every zoomable map also shares one
  `MapOptions.minZoom` floor (`MapStyle.minZoom`, currently 4 — roughly "a continent barely
  fills the screen") so pinching out can't shrink the world down to several repeated
  copies in one viewport; the non-interactive preview-card maps (run results, calendar,
  temp profile) get it too even though they can't be zoomed, for consistency.
  `session_detail_screen.dart` keeps its own tighter `minZoom: 11.0` instead, since that
  map is always fitted to one specific route rather than freely browsable. Every genuinely
  pannable map (explore, route create/search, run tracking's expanded map, test run
  creator — not the three non-interactive preview cards, which can't be panned at all)
  also sets `cameraConstraint: CameraConstraint.contain(bounds: MapStyle.safeCameraBounds)`,
  clamped to the valid Web Mercator latitude range (±85.05°) so panning can't reach the
  genuinely empty tile space beyond it (e.g. well north of Greenland). This correctly
  accounts for map rotation with no extra work needed — flutter_map's `MapCamera.size`
  (what `CameraConstraint.contain` measures the viewport against) is already the *rotated*
  bounding-box size, not the raw widget size, and every camera mutation (pan, zoom,
  `MapController.rotate()`/`moveAndRotate()` — including the programmatic calls
  `EnhancedMapGestures` and run tracking's heading-follow make) is routed through the
  configured `cameraConstraint` regardless of how it was triggered.
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
- **Calendar / own-session history** ([lib/screens/calendar_screen.dart](lib/screens/calendar_screen.dart),
  [lib/screens/session_detail_screen.dart](lib/screens/session_detail_screen.dart)) — a pre-existing flow not previously listed here.
  The calendar screen queries `runningSessions` directly, filtered to the signed-in user's
  own `userId` (this collection is fully readable by any signed-in user — see the
  run-session detail page bullet above — but "my activity history" is inherently
  self-scoped regardless), grouped by day; tapping an activity opens `SessionDetailScreen` with
  that full session doc (as a raw `Map<String, dynamic>`, not a typed model) and its
  polyline already in hand — a locked map preview plus a `GridView` of stat cards
  (distance/duration/pace/calories/points/loops). Distinct from, and not to be confused
  with, `RunSessionDetailPage` (see the run-session detail page bullet above): that one is
  reached from *other* users' contributions on the Explore map, only ever has the limited
  fields denormalized onto an `AreaContribution` (no live doc access is possible there), and
  adds a username header and the favourite-as-route button neither of which apply to "a
  session you already know is your own". The two intentionally stayed separate rather than
  being merged into one screen handling both shapes of input.
- **What actually gets stored**: `claimedAreas.polygon` is a MultiPolygon-with-holes — an
  area can be more than one disconnected piece after a steal splits it, and/or have a hole
  where someone carved out its middle. Firestore disallows directly-nested arrays, so it's
  encoded as an array of `{outer, holes}` maps rather than raw rings (mirrors why
  `closedLoops` wraps points in `{points: [...]}`). `claimedAreas.contributions` is a
  capped (10, newest first) list of `{sessionId, durationMs, avgPaceMinPerKm, conquestDate}`
  — every run that contributed *current* ground to that area, not just the original one,
  because merges concatenate contribution lists and splits duplicate them onto both
  resulting pieces (there's no way to attribute a specific sub-region of a geometric split
  back to one contributing run, and duplicating is actually correct here, not a shortcut).
  Deliberately stays this lightweight — a run-detail page wanting the *whole* running
  session (full path, real distance/area, not just the one loop that happened to claim this
  area) reads the `runningSessions` doc directly by `sessionId` instead (see the run-session
  detail page bullet below; an earlier version tried denormalizing loop-specific geometry
  onto each contribution instead, which was reverted — see that bullet for why). A steal
  that fully absorbs an area deletes its contributions along with it — deliberately: the run
  itself is still safe in `runningSessions`, only the *current-territory* record disappears,
  consistent with `claimedAreas` being current state, not a history log (see below).
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
    rather than looked up live, so this list of up to 10 rows doesn't cost 10 separate
    Firestore reads just to render (any signed-in user *can* read any `runningSessions` doc
    now — see the run-session detail page bullet below for why — this denormalization is
    purely a read-cost optimization at this point, not a workaround for restricted access).
    Tap detection uses flutter_map's `PolygonLayer.hitNotifier`/`Polygon.hitValue`, checked
    inside `MapOptions.onTap`.
  - **Tapping a contribution row** opens [lib/screens/run_session_detail_page.dart](lib/screens/run_session_detail_page.dart)
    (`RunSessionDetailPage`) — pushed from inside the still-open `AreaDetailsSheet`, so its
    own back button (top-left, same circular-white-Material style as `RouteCreatePage`'s)
    naturally reveals the sheet again on pop rather than needing any special "return to
    caller" wiring. Shows the **whole running session**, not just the loop that happened to
    claim the area it was reached from — a run can close a small loop partway through a much
    longer route, so showing only that loop would misrepresent the session (e.g. a 10 km run
    reading as a tiny few-hundred-metre shape) and left the start/finish pins effectively
    stacked on top of each other, since a claimed *loop* by definition returns close to its
    own start. Takes just a `sessionId` + `userId` (not the `AreaContribution` itself
    anymore) and fetches the full `runningSessions` doc live via the new
    `RunSessionRepository.fetchSessionById`, plus a `ProfileService.fetchUsername` lookup for
    the header. **This needed loosening `firestore.rules`**: `runningSessions.read` used to
    be self-owner-only; it's now `if isSignedIn()`, same as `claimedAreas`/`profiles` — a
    deliberate exposure (see the rule's own comment), not an oversight. Read access lets any
    signed-in user see another user's full GPS path and copy it into a new route of their
    own; it does not let them edit, delete, or claim credit for someone else's run, so it
    doesn't touch this collection's actual trust boundary (writes — see
    `serverOnlyRunFields`). An earlier version avoided this by denormalizing loop-specific
    geometry (`distanceMeters`/`areaM2`/`loopPoints`) onto each `AreaContribution` instead
    (a Cloud Function change) — reverted once it became clear that mixed whole-session stats
    (duration/pace, denormalized since day one) with loop-only geometry, which is exactly
    what produced both bugs above; fetching the real session directly is both simpler and
    correct. Shows the runner's username, a preview of the run's whole path (only when
    `path.length >= 2`), and distance/time/avg speed/area-conquered stat pills
    (`UnitFormatter.area` for the area, which now reads `RunSession.totalAreaM2` —
    the session's total claimed area across every loop it closed, not one loop's area). The
    map preview (`_RunPathPreviewMap`) starts locked/small (`InteractiveFlag.none`, 200px)
    and, via a round toggle button in its corner (same `Material`/`InkWell` circular-white
    shape as `RouteCreatePage._RoundMapButton`), expands in place — not a full-page takeover
    like `RunTrackingPage`'s own map expansion — to a genuinely pannable/zoomable size
    (`InteractiveFlag.all & ~InteractiveFlag.rotate`, height clamped to 55% of screen
    height). `MapOptions.initialCameraFit` only ever applies on first build, so
    `AnimatedContainer.onEnd` re-fits the camera (`MapController.fitCamera`) once the resize
    animation actually finishes, rather than just revealing more surrounding map at the old
    zoom. Renders as a plain polyline with **no fill** — unlike a claimed loop, a whole run's
    path isn't guaranteed to be a simple closed shape (it might never return near its start
    at all), and `Polygon` always draws closed, auto-connecting its last point back to its
    first, which could render a nonsensical self-intersecting fill for an ordinary
    point-to-point run. Shows a start pin and a finish pin (the literal checkered-flag
    Material icon, `Icons.sports_score`) at the path's first/last point — genuinely distinct
    locations for a typical run, unlike the old loop-only view — plus a handful of small
    rotated arrow icons along the line — `GeometryUtils.arrowPositions`/`bearingDegrees`, pure
    helpers alongside its other geometry functions, space arrows evenly by *cumulative
    distance* along the polyline (not vertex index, since a breadcrumb trail is never evenly
    sampled) and compute the local direction-of-travel bearing at each, so a viewer can tell
    which way the run actually went. A right-aligned **favourite button**
    ([lib/services/favorite_route_repository.dart](lib/services/favorite_route_repository.dart), `FavoriteRouteRepository`) publishes the
    *whole session's* path as a new `routes` doc — owned by the *viewer*, not the original
    runner, tagged with `sourceSessionId`, `isLoop: session.loopsCompleted > 0`, and the
    session's real observed `estimatedTimeMin`/`estimatedCalories` rather than distance-based
    estimates (we actually know them here) — via the existing `RouteRepository.publishRoute`
    (now returns the new doc's id, and takes an optional `sourceSessionId`), then links it
    with a `favoriteRoutes` doc; un-favouriting deletes both, in that order (link first, then
    the route — an interrupted delete should leave an orphaned-but-harmless route rather
    than a `favoriteRoutes` doc pointing at nothing). "Already favourited?" is resolved on
    page load by matching `sourceSessionId` against `RouteRepository.fetchUserRoutes()`'s
    already-cached list rather than a new query/index (same "filter an already-small
    client-side result" preference as that repository's own `fetchUserRoutes`). Disabled,
    with an explanatory caption, on the (now rare) case of a session with no recorded path.
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
- **User-selectable units, applied app-wide** — Settings -> Units
  ([lib/screens/units_settings_page.dart](lib/screens/units_settings_page.dart)) offers seven two-way choices: distance
  (km/mi), area (km2/mi2), pace-or-speed, elevation (m/ft), energy (kcal/kJ), clock
  (24h/12h) and week start (Mon/Sun), plus a Metric/Imperial preset that flips the first,
  second and fourth together (clock and week start are deliberately excluded — neither
  belongs to either system). Three pieces:
  - **[lib/services/unit_preferences.dart](lib/services/unit_preferences.dart)** (`UnitPreferences.instance`, an app-lifetime
    singleton `ChangeNotifier`, same shape as `LocationService.instance`) owns the choices.
    **`SharedPreferences` is the source of truth, not Firestore**: every measurement the app
    renders goes through this, so a read has to be synchronous and has to keep working
    offline mid-run — a Firestore read per launch would also violate this project's
    avoid-unnecessary-reads rule. `warmUp()` is awaited in `main()` before `runApp` so the
    first frame is already correct rather than flashing metric. Firestore
    (`profiles/{uid}.unitPreferences`, a map, merged the same way `pushPreferences` is —
    **no `firestore.rules` change needed**, the existing `profiles` update rule already
    permits it) is a background one-way mirror purely so the choice follows the user to a
    new device. `syncFromCloud()` (called once from `HomeScreen.initState`) only *adopts*
    the cloud copy on a device where the user has never picked anything themselves
    (`isConfigured`); otherwise it pushes local up, so a stale cloud copy can never undo a
    deliberate local choice. Enum values persist by `name`, never `index`, so reordering an
    enum can't reinterpret saved choices. First launch guesses from the platform locale
    (US/LR/MM/GB -> miles, AU/NZ -> kJ, etc.) and does *not* mark itself configured.
  - **[lib/utils/unit_formatter.dart](lib/utils/unit_formatter.dart)** (`UnitFormatter`) is a pure value object holding
    just the seven enums — no context, no singleton reach-through — so the whole conversion
    layer is testable without a device (`test/unit_formatter_test.dart`, 20 tests), the same
    way `GeometryUtils` is. **The app stays metric end to end**: every stored value,
    Firestore field and geometry calculation is still metres/m2/min-per-km/kcal, and
    conversion happens only at display time — which is why nothing server-side (XP, areas,
    territory) knows this setting exists. It also carries the *inverse* conversions
    (`majorToMeters`, `displayToKcal`) used on the way *in*, at the one boundary where the
    user types a measurement: `RouteSearchPage._deriveTarget`, which converts a typed
    distance/calorie target back to metric so the entire search/candidate/tolerance logic
    below it stays unit-agnostic.
  - **[lib/widgets/units_scope.dart](lib/widgets/units_scope.dart)** (`UnitsScope`, an `InheritedNotifier`, mounted above
    `MaterialApp` in `main.dart`; `Units.of(context)` reactive, `Units.current` for
    callbacks/non-build code). **It has to be an inherited widget, not a `ListenableBuilder`
    around `MaterialApp`** — rebuilding `MaterialApp` does *not* rebuild routes already
    pushed on top of it (`_ModalScopeState` caches each route's page widget), so a user
    flipping km->mi in settings would return to a stale home screen. Inherited-widget
    dependency notification marks dependent *elements* dirty directly, straight through the
    route boundary.
  Two knock-on changes worth knowing: `GeometryUtils.formatAreaKm2` was **removed** (every
  caller now uses `UnitFormatter.area`, which keeps its exact always-major-unit,
  precision-scales-by-magnitude behaviour — never switching to ha/acres by size, for the
  same comparability reason); and `HomeScreen`'s monthly stat cards now store **raw metric
  numbers** (`_MonthlyStatsRaw`) and are formatted during `build` rather than at fetch time,
  since pre-formatting them froze whatever units were active when the Firestore query ran
  and refreshing them would have meant re-querying. `route_info_panel.dart`'s own private
  m2/ha/km2 area ladder is gone too, which incidentally fixes it disagreeing with every
  other area display in the app. One cosmetic change: `session_detail_screen.dart`'s pace
  now renders `5:30` like the rest of the app rather than its own `5'30"`.

**Designed in Firestore rules but NOT yet built in the Flutter app** (i.e. the security
rules anticipate these collections — `runningSessions`, `claimedAreas`, `userStats`,
`notifications`, `follows` — but there is little/no client code reading or writing them
yet, except `runningSessions` writes as of the run-tracking screen and `claimedAreas`
writes as of the claim Cloud Function above). `favoriteRoutes` is no longer in this bucket
— see the run-session detail page bullet below. Treat the rest as the next major
milestones:
- **Explicitly out of scope — do not build, and do not re-propose:** "champion" re-timing
  (holding or taking an area by running its loop *faster* than whoever currently holds it).
  This was never implemented and was cut by the project owner in August 2026. Territory
  changes hands purely by **spatial overlap** — see "Area claiming, with real territory
  interaction" above — never by speed, and speed appears nowhere in the XP formula either.
  Onboarding copy describing an "outrun the champion / steal the crown" mechanic predated
  the real design and was rewritten at the same time; if you find any other surviving
  reference to a champion, it is stale and should be removed rather than implemented.
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
  `distanceMeters`) is immutable after create, only name/visibility can be updated. An
  optional `sourceSessionId` marks a route created by favouriting a run from its detail
  page (see [lib/services/favorite_route_repository.dart](lib/services/favorite_route_repository.dart)) rather than drawn/planned by
  hand — used to detect "have I already favourited this session" client-side.
- `favoriteRoutes/{uid}_{routeId}` — `{userId, routeId}`; owner may create/delete, no
  update. Currently written only by the favourite-a-run-as-a-route flow (see below), always
  paired 1:1 with a `routes` doc carrying the same `routeId` and a `sourceSessionId`.
- `claimedAreas/{areaId}` — doc ID is `{sessionId}_{loopIndex}` of whichever run most
  recently created or absorbed it (an area's ID can outlive the specific run it's named
  after, once merges/steals touch it). `create`/`update` are both `if false` for the
  client; only the `onRunningSessionCreateClaimedAreas` Cloud Function (Admin SDK) writes
  this collection — and unlike most collections in this app, it does *update* existing
  docs in place (shrinking/reshaping them on a steal), not just create new ones. Fields:
  `userId`, `polygon` (MultiPolygon-with-holes, see "What actually gets stored" above),
  `contributions` (capped list of `{sessionId, durationMs, avgPaceMinPerKm, distanceMeters,
  areaM2, loopPoints, conquestDate}` — every run that built current ground into this area),
  `startLocality` (nullable),
  `geohash` (spatial index for the claim function's own candidate queries — see above),
  `createdAt`/`updatedAt` (client sync now keys off `updatedAt`, not `createdAt`, since
  areas mutate), `deleted` (tombstone flag; a client-visible "gone" signal in place of an
  actual delete, which a client with a stale cache would have no way to detect). No
  `colorHex` — display color is viewer-relative (mine vs. not), computed client-side, not
  a property of the area. Owner may still `delete`.
- `runningSessions/{sessionId}` — readable by any signed-in user, not just its owner (a
  deliberate exposure so a run-detail page can show another user's whole session and copy
  it into a new route — see that bullet above; this doesn't loosen anything about who may
  *write* it). Created by the client with `pointsEarned == 0`; only a
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
- `follows/{followId}`, `notifications/{id}` — mostly self-explanatory ownership rules;
  notifications can only be created server-side, the recipient may only toggle
  `isRead`/`readAt`.

When adding a new collection or field, add matching rules in `firestore.rules` in the
same change — don't rely on "we'll lock it down later".

## Security & performance — non-negotiable

These are explicit, standing requirements from the project owner. Do not trade them off
for convenience, and flag it clearly if a requested change would weaken either.

- Never let the client set values that represent trust/points/ranking (`totalPoints`,
  `pointsEarned`, area ownership). Those must be computed and written
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
