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

**Designed in Firestore rules but NOT yet built in the Flutter app** (i.e. the security
rules anticipate these collections — `runningSessions`, `claimedAreas`, `userStats`,
`notifications`, `favoriteRoutes`, `follows` — but there is little/no client code reading
or writing them yet, except `runningSessions` writes as of the run-tracking screen).
Treat these as the next major milestones:
- Writing a `claimedAreas` doc per closed loop (currently `closedLoops` only lands inside
  the `runningSessions` doc, not as separate `claimedAreas` docs).
- Stealing / champion re-timing logic (no Cloud Function implements point-awarding yet —
  `runningSessions.pointsEarned` and `profiles.totalPoints` are server-authoritative by
  rule but nothing currently sets them server-side; every session is saved with
  `pointsEarned: 0`).
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
  Cloud Functions (Node/v1 functions API, [functions/](functions/)).
- **Maps/routing**: `flutter_map` (OSM tiles) + `latlong2` for geometry, `geolocator` for
  device location, OpenRouteService (foot-walking profile) via raw `http` calls for
  road-snapped directions and alternative routes ([lib/services/routing_service.dart](lib/services/routing_service.dart)).
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
  must not run on the client (points, badge progress, future claim/steal arbitration).
- `firestore.rules` — the source of truth for what the client is and isn't allowed to
  write; read this before adding any new Firestore read/write path.

## Data model (Firestore)

See [firestore.rules](firestore.rules) for the authoritative, enforced version of this. Summary:

- `profiles/{uid}` — doc ID = uid. `totalPoints` is server-only (client can never set/
  change it; Cloud Functions use the Admin SDK to bypass rules for this).
- `nicknames/{nickname}` — uniqueness index; doc ID is the nickname itself, value holds
  the owning `uid`.
- `routes/{routeId}` — owned by `userId`; geometry (`routePolyline`, `waypoints`,
  `distanceMeters`) is immutable after create, only name/visibility can be updated.
- `claimedAreas/{areaId}` — doc ID must equal the originating `routeId`; immutable once
  written (no update, only owner delete).
- `runningSessions/{sessionId}` — created by the client with `pointsEarned == 0`; only a
  server process may ever change `pointsEarned`.
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
  the cache-and-invalidate pattern used in `RouteRepository` to control read costs and
  battery/network usage on a run-tracking app where the user may be mid-workout.
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

## Working conventions

- Some in-app user-facing strings are in Italian (e.g. `ImageUploadService` error
  messages) — match the existing language of the file you're editing rather than
  silently switching to English.
- This list of built vs. planned features should be updated every time a feature lands
  or a new one is scoped, so a fresh session can rely on it instead of re-deriving
  status from a full codebase scan.
