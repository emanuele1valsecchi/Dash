# TEST NOTES

> ## ⚠ OPEN SECURITY QUESTION — needs a team decision
>
> **Any signed-in user can create a private-metrics document under anyone
> else's run — and doing so permanently locks the real owner out of their own
> heart-rate data for that run.** Found by the rules tests, verified against
> the emulator. Not fixed, not agreed. Details and two proposed fixes in
> [section 5](#the-open-finding-private-metrics-squatting).
>
> It shows in every rules run as a red `not ok ... # TODO` line and will keep
> showing until someone resolves it.


Everything worth knowing about testing Dash that is not obvious from reading
the tests, plus what we still owe. Written up as we went, so the reasons are
recorded rather than re-derived.

For *how to run things*, see [test/README.md](test/README.md). This file is the
running log: traps, decisions, bugs found, and open work.

**Status:** 391 Dart tests + **98 Firestore rules tests**, `flutter analyze`
clean, **16.4% line coverage** (1980/12057 across all 126 files in `lib/`).

---

## 1. Traps that cost us time. Read before debugging a weird failure.

### 1.1 Two Flutter SDKs on this machine

The single biggest time sink of the whole effort. There were two installs:

| Path | Version | |
|---|---|---|
| `C:\Users\user\Flutter\flutter` | 3.44.0 / Dart 3.12 | what the project needs |
| `C:\src\flutter` | 3.41.9 / Dart 3.11.5 | was first on PATH |

`.dart_tool/package_config.json` records **absolute paths** into one specific
SDK. Running the *other* `flutter` binary compiled 3.44's framework sources
against 3.41's `dart:ui`, failing deep inside the framework:

```
Error: Type 'ui.DisplayCornerRadii' not found.
```

That message points nowhere near the cause. The whole 103-test suite could not
compile, and it looked like a broken test suite rather than a broken PATH.

**Fixed**, three ways so it cannot recur silently:

- `C:\src\flutter\bin` removed from the **System** Path (it was in the System
  pane, not the User pane — System is searched first, which is why editing only
  User variables did nothing).
- `pubspec.yaml` now pins `sdk: ^3.12.0` and `flutter: '>=3.44.0'`, so a
  too-old SDK refuses the resolve with a clear message instead.
- `tool/coverage.dart` reads the SDK out of `package_config.json`, so it works
  regardless of PATH.

**Related symptom** after switching SDKs: `Can't load Kernel binary: Invalid
kernel binary format version`. That is a stale build-hook cache — delete
`.dart_tool/hooks_runner`.

> VS Code's Dart extension prepends its own SDK to the integrated terminal's
> PATH, so `flutter test` could pass there and fail in a plain PowerShell
> window. If two people disagree about whether the suite runs, check this.

### 1.2 The test font is ~2x too wide, and it caused a false bug report

`flutter test` substitutes a font where **every glyph is a full em square**:

```
"Continue with Google" @15px -> 300.0px  (15.0px/char)   ~145px on a device
"Share External"       @14px -> 196.0px  (14.0px/char)     ~95px on a device
```

Two "overflow bugs" were reported off the back of this. **Neither was real.**
Production code was changed before the artifact was spotted. Before acting on a
`RenderFlex overflowed`, measure:

```dart
final tp = TextPainter(
  text: const TextSpan(text: 'Your label', style: TextStyle(fontSize: 15)),
  textDirection: TextDirection.ltr,
)..layout();
debugPrint('${tp.width / 'Your label'.length} px per char');
```

If that prints the font size back at you, it is the test font.

The check is still sound in the **conservative** direction: surviving the fat
font proves a comfortable real-world margin, which also covers large
accessibility text scales. Keep such assertions where they pass; never read a
failure as a bug without measuring.

### 1.3 `Scaffold`'s body gets *tight* constraints

A widget that sizes itself to a fraction of screen width gets stretched back to
full width inside `Scaffold(body:)`, so the assertion passes or fails for
reasons unrelated to the widget. Wrap the subject in `Align` — which is what a
real `Column`/`ListView` caller does anyway. See the `width` group in
`test/widget/dash_text_form_field_test.dart`.

### 1.4 `binding.setSurfaceSize` does not move `MediaQuery`

It resizes the render surface but leaves `MediaQuery` reporting 800x600, so a
widget computing against `MediaQuery.sizeOf` uses 800 and is then clipped. Use
`tester.view.physicalSize` + `devicePixelRatio = 1.0` (what `pumpDashWidget`'s
`surfaceSize:` does).

### 1.5 `scrollUntilVisible` leaves rows at the clipped edge

Taps land outside the hit box and silently do nothing. Four tests failed this
way on the settings page. Use a **tall viewport** (`390x2600`) so a long page
lays out at once, or `tester.ensureVisible` before tapping.

### 1.6 Scope text finders to their container

`find.textContaining('18:35')` matched **two** widgets on the units page,
because an option subtitle reads "e.g. 18:35" and the preview shows the same
value. `map_units_page_test.dart` has a `previewValue()` helper that reads the
specific row instead.

### 1.7 You cannot reassign `debugPrint` in a widget test

`flutter_test` asserts foundation debug variables are untouched, and the
violation surfaces as *"The value of a foundation debug variable was changed by
the test"* on the **first test of every file**. An attempt to filter log noise
that way broke 10 files at once. Fix noise at the source instead.

### 1.8 Navigating into `RootScreen` cannot work in a widget test

`LoginScreen` signs in and `pushReplacement`es to `RootScreen` — the entire app
shell (bottom nav, map, profile, Firebase Storage). `pushReplacement` mounts it
**immediately**, not at the end of the transition, so no amount of careful
pumping avoids it.

Tried and rejected: short pumps, a `NavigatorObserver`, tearing the tree down in
`addTearDown`, and `setupFirebaseCoreMocks()` + `Firebase.initializeApp()`. The
core mock is **kept** (it removes the `[core/no-app]` class of error) but the
app shell still fails on Storage.

**Decision:** widget tests assert what the screen *asks its services to do* and
*shows the user*; the auth-flow files drop the destination's Firebase errors
narrowly (anything not Firebase-init-related still fails the test).
"Signing in lands you on the home screen" is an **integration test**, and is
listed as owed work below.

---

## 2. Bugs the tests actually found

| Bug | Where | Status |
|---|---|---|
| **`signInWithGoogle()` called twice per tap** — a leftover debug block ran the whole Google flow, then the real attempt ran it again. Wasted work, and an error surfaced from whichever call landed first. | `register_page.dart` | **Fixed.** Caught by "asks the auth service exactly once" (Expected 1, Actual 2). |
| Name rendered untrimmed — `'$name $surname'` left a trailing space for a user with no surname, visibly off-centring a centred name. `DashUserTile` already trimmed. | `share_profile_page.dart` | **Fixed.** |
| Two "overflow" bugs | — | **Not real.** See 1.2. |

Also noticed while reading, **not** fixed:

- **`error_page.dart`'s "Return to login" button is `onPressed: (){}`** — a dead
  button that does nothing at all.
- **`ClaimedAreaRepository` contradicts its own doc comment.** It documents
  itself as *"One-time read rather than a real-time listener"*, but its only
  method is `areasStream()` using `.snapshots()` — a live listener on the
  entire `claimedAreas` collection. Same shape as the `home_page.dart` problem
  already flagged in CLAUDE.md, and against the read-cost rule in
  "Security & performance — non-negotiable".

---

## 3. Decisions worth not re-litigating

### Fakes over mocks, except at the screen layer

Where a real in-memory double exists, use it: `FakeFirebaseFirestore` actually
stores and queries documents, so a repository test asserts on behaviour rather
than replaying a script of expected calls. Mocks earn their place one level up,
for **screens**, where the question is "did this screen ask for the right
thing" (`verify()`) and where `thenThrow` is the only sane way to reach an
error branch.

### The injection seam has two load-bearing details

```dart
// Singletons: private constructor + a @visibleForTesting factory, so
// production still gets exactly one instance and a test cannot create a
// second live repository with its own cache.
RouteRepository.withDependencies(db: FakeFirebaseFirestore(), auth: mockAuth);

// Plain classes: a public constructor.
ProfileService(firestore: fake);
```

And the defaults resolve **lazily**:

```dart
late final FirebaseFirestore _db = _dbOverride ?? FirebaseFirestore.instance;
```

Eager resolution threw `[core/no-app]` at *construction*, which made screens
that build services in a field initializer (`final _authService =
AuthService();`) unconstructible even though the service was injectable.
`FavoriteRouteRepository` had the same problem with an eager
`FirebaseFunctions.instanceFor(...)` field — now `late`, which also means the
app builds no Functions client for a user who never favourites a run.

### The theme lives in `lib/config/app_theme.dart`, not `main.dart`

Several widgets resolve theme extensions with a non-null assertion
(`context.paddingMd` is `Theme.of(this).extension<ResponsiveSpacing>()!`), so a
widget pumped under a bare `MaterialApp()` throws before rendering. Tests use
the app's **real** theme via `pumpDashWidget`; a second copy in a test helper
would work until someone added an extension in one place and not the other.

### `flutter test --coverage` flatters the suite; use the tool

It only reports files a test **imported**, so the number *rises* when you delete
the only test importing a poorly-covered file. It read 65.3% when the true
figure was 7.6%. `dart run tool/coverage.dart` writes a temporary all-imports
file so the denominator is the whole app.

**The data is not ours** — `coverage/lcov.info` is written by Flutter; the tool
only reads it. Verify independently:

```bash
grep -c '^DA:' coverage/lcov.info               # total instrumented lines
grep '^DA:' coverage/lcov.info | grep -vc ',0$'  # lines executed
```

### Coverage is a weak signal; mutation is the real check

Three deliberate regressions were planted and the suite caught all three, with
no false alarms:

| Planted | Caught by |
|---|---|
| routes default to **public** | `publishRoute visibility defaults to private` |
| heart rate written to the **world-readable** doc | `saveSession privacy boundary heart rate never lands...` |
| badge sort inverted | 2 badge ordering tests |

Do this yourself any time: flip `bool isPublic = false` to `true` in
`route_repository.dart`, run `flutter test`, watch it go red, change it back.


### No fake test account. Integration tests stay a smoke test.

Decided deliberately: standing up a dedicated Firebase account for tests means
credentials that must be kept out of the repo, rotated, and shared with the
team — real ongoing cost for a student project, and a security footgun the
moment someone commits them.

**Consequence, accepted:** `integration_test/` keeps only
`app_launch_test.dart`. The flows that need a signed-in user — sign in and land
on the home screen, plan a route, record a run and watch a claimed area appear
— are **not** written and are not planned. That leaves 1.8's gap permanently
open at the widget level too, which is the honest trade.

What replaces the assurance those would have given: **`firestore.rules` tests
against the local emulator**, which need no account at all (see 4.1), and the
mutation checks in section 3.

### Registration tests go beyond the reference project

The reference repo has no registration test; ours has 21. Kept anyway — the
password-rule ladder is the app's entire defence against a weak password, and
writing them is what caught the double `signInWithGoogle()` call. Recorded here
rather than treated as parity work.

---

## 4. What we owe

### High value

1. **`lib/screens/` is ~4% covered and is 7,528 lines — 62% of the codebase.**
   Every screen that reaches Firebase directly (27 of them) needs the same
   constructor-injection treatment `LoginScreen` and `RegisterScreen` now have
   before its success paths are reachable.
2. **`functions/_verify_*.js` are not tests in any runner's sense** — hand-rolled
   assertion scripts run with plain `node`, producing no machine-readable
   result and invisible to any coverage or CI summary. Moving them to
   `node:test` would fix that without rewriting the assertions.
3. **No CI.** Nothing runs the suite on push. `dart run tool/coverage.dart --min N`
   exits non-zero below a threshold and is ready to wire up.

### Medium

4. **`widgets/` is 14.5%.** ~20 Firebase-free widgets remain untested, including
   `EnhancedMapGestures` (440 lines) — the rotation dead zone and multi-touch
   release fix are the most intricate untested logic in the app, and the most
   likely to regress silently.
5. **`models/` is 43.9%** and only 41 lines. Cheap to finish.
6. **The loose `*_test.dart` files at the root of `test/`** predate the
   `unit/`/`widget/` split. Move them into `test/unit/` when next touched.


### Known limits, accepted for now

- **Google/Apple sign-in cannot be driven** past the service boundary; we verify
  the screen calls `signInWithGoogle()` and handles null (cancelled) and throw
  (failed), which is as far as a widget test can go.
- **`UnitPreferences` is an app-lifetime singleton.** `resetForTesting()`
  (`@visibleForTesting`) exists because otherwise one test's choice of miles
  leaks into every later test, and since test order is not guaranteed the
  failure would come and go. Call it in `setUp` **and** `tearDown` when touching
  units.
- **`qr_scanner_page.dart` needs a camera** and is untestable at this level.
- **`session_detail_page.dart` is unreferenced dead code** (per CLAUDE.md) —
  don't spend tests on it; delete it.


---

## 5. Firestore rules tests

`test/rules/` — 98 tests, Node, run against the **local Firestore emulator**.
No test account, no real project, nothing to keep secret.

```sh
cd test/rules && npm install   # once
npm test                       # boots the emulator, runs, shuts it down
npm run emulator               # leave one running, for iterating
```

They read the **real `firestore.rules`** from the repo root, not a copy, so
they fail the moment the deployed file drifts.

### Two setup traps, both already handled

- **`firebase-tools` is pinned to 14.19.0 as a local devDependency.** v15
  requires JDK 21 and the newest JDK here is 19; v13 hits an `ERR_REQUIRE_ESM`
  crash under Node 20. 14.19.0 is the version that works with both, and warns
  that Java <21 support is going away — **when it does, this pin stops working
  and a JDK 21 install becomes unavoidable.**
- **Each test file gets its own emulator project** (`rulesSuite('routes')` etc).
  `node --test` runs files in parallel against one emulator and every file
  clears the database between tests, so a shared project id means one file
  wipes another's seeded data mid-test — and the failures look exactly like
  rules bugs. This cost a confusing debugging round.

### Verified by mutation

Removing the `isPublic` pin from the `routes` update rule failed exactly three
tests — the two permanence checks and the legacy-document one — and nothing
else. Reverted; suite green.

### The open finding: private-metrics squatting

<a name="the-open-finding-private-metrics-squatting"></a>

**Status: unresolved. Needs a decision.** Surfaces as a deliberately-failing
`todo` test in `running_sessions.test.js`:

```
not ok 5 - another user may NOT create metrics under someone elses session # TODO
not ok 6 - the owner can still save metrics after someone squats the slot   # TODO
# fail 0
# todo 2
```

`todo` rather than a hard failure so CI stays usable — a permanently red suite
teaches people to ignore red. Delete the marker when the rule is tightened;
node:test reports a *passing* todo, which is the prompt to do it.

**What the rule actually says** (`runningSessions/{id}/private/{docId}`):

```
allow create: if isSignedIn()
  && request.resource.data.userId == request.auth.uid
  && validHeartRate(...);
```

It authorizes off the **document's own denormalized `userId`** — not the parent
session's owner. Nothing anywhere checks that the session belongs to the writer.

**So Bob can do this:**

```js
setDoc(doc(bobsDb, 'runningSessions/<any-session-id>/private/metrics'),
       { userId: 'bob', avgHeartRateBpm: 152 });   // succeeds
```

**Consequences — run against the emulator, not reasoned about:**

```
PROBE bob creates metrics under alice session: ALLOWED
PROBE alice then writes her own metrics:       DENIED
PROBE alice reads the slot:                    DENIED
PROBE alice deletes the squatted doc:          DENIED
```

So it is **a denial of service on the owner's own data**, not merely litter:

1. Once Bob's document occupies `.../private/metrics`, Alice's own write
   becomes an *update*, and `update` is gated on the **existing** document's
   `userId` — so she is denied. Her heart rate silently never saves.
2. She can neither read nor delete Bob's document to clear the slot. Only an
   Admin-SDK sweep can.
3. It is cheap and repeatable: session IDs are readable by any signed-in user
   (the collection is world-readable by design), so an attacker can enumerate
   every session in the app and squat all of them.

**What it is NOT:** disclosure. Bob cannot read anything of Alice's, and cannot
overwrite metrics that already exist. No heart rate leaks. The damage is
availability and integrity, not confidentiality.

#### Why it was not just fixed

CLAUDE.md rejects `get()` inside a rule because it is *"a billed read on every
evaluation"*. **That reasoning is weaker here than it first looks, and this is
the part worth arguing about:**

- It was written about the **read** rule, which fires constantly — a detail
  page loads metrics on every visit.
- The hole is in **create/update**, which fire only when a *watch* run is
  saved. Per the migration note in CLAUDE.md, production had **11 sessions and
  zero heart-rate records** — no watch run has ever been saved. The write path
  is close to unused.

So "a `get()` on create only" costs approximately nothing today.

#### Two candidate fixes, for the discussion

**A. `get()` the parent, on write paths only.**

```
allow create: if isSignedIn()
  && request.resource.data.userId == request.auth.uid
  && get(/databases/$(database)/documents/runningSessions/$(sessionId))
       .data.userId == request.auth.uid
  && validHeartRate(...);
```

Smallest change, no data migration, leaves the read rule untouched. Costs one
billed read per metrics write — currently a rounding error.

**B. Put the owner in the document path instead.** Move body metrics to a
top-level `runPrivateMetrics/{uid}_{sessionId}`, so the rule reads the owner
straight out of the ID:

```
allow read, write: if isSignedIn()
  && favId.split('_')[0] == request.auth.uid;
```

No `get()`, no billed read, and squatting becomes structurally impossible
rather than merely forbidden. **This is the same trick `favoriteRoutes/{uid}_{routeId}`
already uses in this codebase**, so it is a consistent pattern rather than a new
idea. Costs a migration and a change to `RunSessionRepository.saveSession`
(which currently writes the subcollection in the same `WriteBatch`, partly *for*
the shared document ID).

**My reading:** B is the better end state — it removes the class of bug instead
of the instance, and matches a pattern already here. A is the right thing to
ship first if a fix is wanted before the migration is scheduled.

### What is covered

| Collection | What is pinned |
|---|---|
| `routes` | private-by-default; `isPublic` permanent in both directions; geometry immutable; shared session routes uncreatable, unwritable, undeletable by any client |
| `runningSessions` | world-readable; `pointsEarned` server-only; heart rate rejected on the public doc; all 9 server-only scoring fields refused on create *and* update; no client deletes |
| `.../private/metrics` | owner-only read; absent reads as denied, not empty; heart rate range-checked |
| `profiles` | `totalPoints` unraisable; `areaColorIndex` bounded 0-9; `badge_progress` readable but never client-written |
| `claimedAreas` | every client create/update denied; owner-only delete |
| `userStats` | self-read only, no client writes at all |
| `favoriteRoutes` | client cannot create; only `name` updatable |
| `notifications` | recipient-only read; client cannot create; only `isRead` updatable |

---

## 6. Quick reference

```sh
flutter test                              # 391 tests, ~17s
flutter test test/widget/                 # one layer
flutter test --plain-name "private"       # by name
dart run tool/coverage.dart --html        # honest coverage + coverage/report.html
dart run tool/coverage.dart --min 40      # exit 1 below a threshold (for CI)
dart run build_runner build               # regenerate test/mocks.mocks.dart
flutter test integration_test             # needs a device attached
cd test/rules && npm test                 # 98 rules tests, local emulator
```

Add a mock by editing the `@GenerateMocks` list in `test/mocks.dart`, then
re-running `build_runner`. Import the **generated** `mocks.mocks.dart`, never
`mocks.dart`.
