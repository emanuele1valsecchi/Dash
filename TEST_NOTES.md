# TEST NOTES

> ## ✅ RESOLVED — private-metrics squatting
>
> Any signed-in user could create a private-metrics document under anyone
> else's run, which **permanently locked the real owner out of their own
> heart-rate data**. Found by the rules tests, verified against the emulator,
> **fixed** by addressing the document by the owner's uid.
> Write-up in [section 5](#the-finding-private-metrics-squatting-fixed).

**Status:** 671 Dart tests + **109 Firestore rules tests**, `flutter analyze`
clean, all green.

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


**A corollary worth knowing:** when a widget sizes itself from `MediaQuery`
rather than its parent, wrapping it in a bigger `SizedBox` does nothing — the
overflow stays *identical*. That is the tell. Widen `surfaceSize` instead. It
cost a round on `leaderboard_preview_card_test.dart`, where the overflow read
27px at both 560 and 800 pixels of parent width.

### 1.3 `Scaffold`'s body gets *tight* constraints

A widget that sizes itself to a fraction of screen width gets stretched back to
full width inside `Scaffold(body:)`, so the assertion passes or fails for
reasons unrelated to the widget. Wrap the subject in `Align` — which is what a
real `Column`/`ListView` caller does anyway. See the `width` group in
`test/widget_test/dash_text_form_field_test.dart`.

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

### 1.9 A SnackBar needs a Scaffold to survive a pop

A page that shows a confirmation and then pops (`EditProfilePage` on save) will
appear to show nothing if the route *underneath* has no `Scaffold`. A SnackBar
is hosted by the `ScaffoldMessenger` but re-parents to the nearest registered
`Scaffold`; with a bare widget beneath, there is nothing to re-parent to and
the message vanishes with the page.

That is a test-harness artifact, not an app bug — every real caller is a
Scaffold-based page — but it costs a confusing round if the harness pumps the
page under a plain `Builder`. Give the parent route a `Scaffold`.

### 1.10 `thenThrow` throws synchronously

Mockito's `thenThrow` raises at the *call site*, not in the returned Future. A
class that stores a service result in a field initializer —
`late final _future = service.fetchThing()` — therefore explodes while
constructing its `State`, long before the `FutureBuilder` that would have
handled it. The test then fails with a bare exception instead of exercising the
error branch.

Model a rejected Future the way a real service produces one:

```dart
when(service.fetchThing()).thenAnswer((_) async => throw Exception('denied'));
```

### 1.11 GPS fixtures have to be plausibly slow

`StandaloneRunImporter` and `RunSessionController` both reject a leg implying
more than **8 m/s** — the same spike filter, so a watch run and a phone run of
one route report the same distance. A fixture spaced `0.0001` degrees apart at
one-second intervals is ~11 m/s (40 km/h), so every leg is discarded and the
run measures **zero**, which looks like a broken distance calculation rather
than a badly-chosen fixture. About `0.00003` degrees per second (~12 km/h) is a
realistic jog.

### 1.12 The same spike filter silently voids off-route tests

A corollary of 1.11 that is much harder to spot, because the test *passes*.
`onPosition` returns early on a spike — **before** `_updateGuidance` — so a
fixture that teleports the runner 200 m sideways to "leave the route" is
discarded outright and guidance is never recomputed. The assertion
`isOffRoute, isFalse` then holds for entirely the wrong reason, and its mirror
(`isOffRoute, isTrue` after several such fixes) fails with no clue why.

The off-route fixtures therefore **drift**: `0.00025` degrees (~28 m) per fix
at 5 s intervals is 5.6 m/s, under the cap, so each one is actually accepted.
Six of them are needed to confirm off-route, not five — the first step lands
inside the 35 m threshold and does not count.

The same applies on the way back in: walking from 167 m out to the line in one
fix is also a spike. The rejoin test steps back at the same pace.

**Rule of thumb: if a controller test asserts something about state that
`onPosition` computes, check the fixture's implied speed first.** A silently
ignored fix makes the whole pipeline downstream of it untested.

---

### 1.13 An exception can be blamed on the wrong test

When the Update Email crash was first reproduced, four tests failed: the two
dialog ones (correctly) and both `export data` ones (which have nothing to do
with it). Run on their own, the export tests passed.

The crash was thrown from a frame pumped *after* the dialog test's body had
finished, and `flutter_test` attributes a late exception to whichever test is
running when it surfaces — reported as `Multiple exceptions (3) were detected
during the running of the current test`.

**That wording is the tell.** "Multiple exceptions were detected" in a test
that only does one thing means the failure probably belongs to the test
before it. Run the suspect test alone before debugging it; if it passes,
go and look at its predecessor.

---

### 1.14 `tester.drag` cannot reorder a `ReorderableListView`

Two separate obstacles, and the first one hides the second.

On mobile the list starts a reorder from a **long press**, so `tester.drag`
does nothing at all — and nothing fails either: the list simply does not move,
so an assertion like "the order changed" quietly passes or fails for the wrong
reason. The gesture has to be held first:

```dart
final gesture = await tester.startGesture(tester.getCenter(find.text('X')));
await tester.pump(kLongPressTimeout + kPressTimeout);   // flutter/gestures.dart
```

Then: **one big `moveBy` is not enough for a downward move.** Dragging up
worked in a single jump, dragging down silently never fired the callback at
all. Ten small moves with a `pump` between each does fire it. Measure the
distance from the two rows' real centres rather than guessing a pixel count,
or a card height change turns the test into a no-op that still passes.

**Always assert the resulting order explicitly.** The first version of this
test asserted only `isNot(originalOrder)`, which would have passed while the
drag did nothing — and it was the exact-order assertion that exposed the real
`onReorderItem` bug in section 2.

---

### 1.15 Two `MockUser`s with the same fields are the same object

`firebase_auth_mocks`' `MockUser` mixes in `EquatableMixin`, so
`MockUser(uid: 'me', email: 'x')` built twice compares `==` and shares a
`hashCode`. `mock_exceptions` — the package that lets you make a mock user's
method throw — keys its registry by object in a **global** map that is never
cleared between tests.

So a stub registered in one test lands on an identically-built user in the
next, and `maybeThrowException` throws whichever was registered first. The
symptom is the giveaway: **the test passes alone and fails in the file**, with
the *previous* test's error message on screen.

Give each test's user a distinct `uid` when it stubs an exception. Grepping
`mock_user.dart` for `operator ==` finds nothing — the mixin supplies it.

---

### 1.16 A mutation that survives usually means a vacuous test

Two `syncFromCloud` tests asserted the rule that matters most in
`UnitPreferences` — *a stale cloud copy must never undo a choice made on this
device* — and both passed with the guard deleted.

The reason was ordering. The test wrote a conflicting value to the cloud
*first*, then made the local choice. But every setter mirrors itself up
unawaited, so by the time `syncFromCloud` ran, that mirror had already
overwritten the cloud with the same value the test then asserted. The two
agreed, so adopting the cloud copy and refusing to adopt it produced
identical results.

The fix was to make the cloud start disagreeing *after* the local choice had
settled. With that, deleting the guard fails both tests.

**Generalise this.** A surviving mutation is rarely "the test does not cover
that line" — it is usually "the test covers it but the assertion cannot
distinguish the two behaviours". Look at what the setup does *before* the
thing under test, not just at the assertion.

Two other traps sit next to this one: mutations applied together can mask each
other (see the calendar and `UnitPreferences` cases — always confirm a
survivor in isolation), and an unawaited background write means the state you
assert on may have been rewritten by the code under test.

---

### 1.17 Two mutations that survived, and what both had in common

Bucket A ran ~30 mutations. Three survived on the first pass, and none of
them meant "that line is uncovered":

* `UnitPreferences.syncFromCloud`'s guard (see 1.16) — the setup made the
  cloud agree with local before the assertion.
* `UserAppearanceService`'s in-flight dedupe — the test asserted the
  resulting username, which is correct whether one fetch ran or two. Fixed by
  counting notifications instead: a deduplicated second call finds nothing to
  want and never notifies.
* `ProfileActivitySections`' independent failure flags — the failing row
  resolved *first*, so a shared flag was harmlessly overwritten by the row
  that succeeded after it. Fixed by delaying the failure so it lands after
  the success, which is the only ordering that distinguishes the two designs.

**The pattern: a surviving mutation is usually a setup problem, not a
coverage gap.** Ask what ordering or what value would make the two behaviours
differ, and arrange that — do not just add another assertion.

---

---

## 2. Bugs the tests actually found

| Bug | Where | Status |
|---|---|---|
| **`signInWithGoogle()` called twice per tap** — a leftover debug block ran the whole Google flow, then the real attempt ran it again. Wasted work, and an error surfaced from whichever call landed first. | `register_page.dart` | **Fixed.** Caught by "asks the auth service exactly once" (Expected 1, Actual 2). |
| Name rendered untrimmed — `'$name $surname'` left a trailing space for a user with no surname, visibly off-centring a centred name. `DashUserTile` already trimmed. | `share_profile_page.dart` | **Fixed.** |
| **`Expanded` inside a `Padding`** — `_buildFollowersCount` returned an `Expanded`, but both call sites are already `Row > Expanded > InkWell > Padding`, so the inner one had a non-Flex parent. Flutter's "Incorrect use of ParentDataWidget" assertion fired on **every render of a profile header**. | `profile_header.dart` | **Fixed.** Found while getting `PublicProfilePage` to render at all. |
| **Unhandled async error on a badge read** — `_startBadgesStream()` is `async void` with no guard around `getProfileBadges`, so a failure escapes as an unhandled zone error nothing can catch. Realistic: this exact read was denied outright before the `badge_progress` rule was widened. | `public_profile_page.dart` | **Fixed** — badges now degrade to absent. |
| **`maxLines`/`ellipsis` that could never take effect** — the stat title sat in a `Row` with `mainAxisSize: min` and no `Flexible`, so it was never width-constrained and its truncation properties were inert. The intent was already in the code; it simply could not work. | `statistic_tachometer.dart` | **Fixed** — title wrapped in `Flexible`, matching `DashMapCard`. |
| **A second unguarded `async void` load** — `_startBadgesStream()` had no try/catch, so a failed `getAllBadges` escaped as an unhandled error *and* left `_isLoading` true, stranding the page on its spinner forever. Same shape as the `public_profile_page.dart` one. | `badge_page.dart` | **Fixed.** |
| **A `TextEditingController` used after disposal, crashing the Update Email dialog on every open.** The controller was created in the method, `await showDialog(...)`, then disposed — which is when the dialog *starts* its exit transition, with the `TextField` still mounted and bound to it. CLAUDE.md had flagged this file as "the same crash waiting to happen" after the identical bug was fixed in the rename dialog; it was not hypothetical. | `personal_information_page.dart` | **Fixed** — `_UpdateEmailDialog`, a `StatefulWidget` owning its controller, same shape as `rename_route_dialog.dart`. Reproduced before the fix. |
| **Dragging a leaderboard *down* in Customize Home did nothing.** The handler subtracted one from `newIndex` when moving down — the convention for the deprecated `onReorder` callback — but the screen uses `onReorderItem`, which already accounts for the removed item. `old=1, new=2` became `new=1`, so the item was removed and reinserted at the same index. Moving *up* was unaffected, which is why it went unnoticed. | `home_leaderboards_settings_page.dart` | **Fixed** — adjustment removed. Covered by "moving a board down works too". |
| **Two more unguarded `async void` badge loads** — `ProfilePage._startBadgesStream` and `HomePage._startBadgesStream` both awaited their badge read with no try/catch, so a failure escaped as an unhandled async error instead of costing only the badges. The third and fourth copies of the bug already fixed in `public_profile_page.dart` and `badge_page.dart`, and realistic rather than hypothetical: this read was denied outright before the `badge_progress` rule was widened. | `profile_page.dart`, `home_page.dart` | **Both fixed** — same guard as the twins. Each pinned by a "a failed badge read does not take the page down" test, confirmed failing first. |
| **A signed-out user was stuck on a permanent spinner** on Push Notification settings. `_loadPreferences` returns early when there is no uid — but that `return` sits *above* the `try`, so the `finally` that clears `_isLoading` never ran. | `notification_settings_page.dart` | **Fixed** — clears the loading flag before returning. Pinned by "a signed-out user is not left on a spinner forever", which fails with `pumpAndSettle timed out` before the fix. |
| "Badge progress off by 100x" | — | **Not real.** See below. |
| Two "overflow" bugs | — | **Not real.** See 1.2. |

Also noticed while reading, **not** fixed:

- **The Start-run overlay's action labels are not tappable — and that is
  deliberate, confirmed by the project owner.** Each of the three actions is a
  `Row` of a plain `Text` beside a *separate* icon-only `DashActionButton`, so
  only the round icon is a target. Tapping the words does **nothing at all**:
  it neither selects the action nor dismisses the overlay.

  Three behaviours were possible — do nothing, dismiss (the tap falling
  through to the backdrop), or trigger the action. "Do nothing" is the chosen
  one, and it is the safest: a near-miss on a small icon must not close a menu
  the user just opened. Pinned by
  `start_run_overlay_test.dart`'s `only the icon is tappable, not the label
  beside it`, so a refactor that accidentally makes the label swallow-through
  to the backdrop will fail rather than pass silently.

- **`RouteSearchPage._removeStop` disposes a controller before `setState`.**
  Between those two lines the `TextField` is still mounted and bound to a
  disposed controller. It appears safe in practice — `removeListener` is one of
  the few `ChangeNotifier` methods with no not-disposed assertion, and the
  rebuild is synchronous — so this is **not** the crash fixed in
  `personal_information_page.dart`. But the ordering is load-bearing by
  accident rather than by design, and the stop `TextField`s are unkeyed in a
  `Column`, so removal reconciles by index. Swapping the two lines would make
  it obviously correct. Left alone deliberately: that file has no tests yet, so
  the change could not be verified. Check it when it gets some.

- **`WearBridge.dispose()` is one-way, and only tests call it.** It closes
  both broadcast `StreamController`s while also setting `_started = false`,
  which implies a restart is contemplated — but a second `start()` afterwards
  runs its timer and then silently drops every command and import message,
  because the `isClosed` guards skip the closed controllers. Nothing in
  `lib/` calls it (three test files do, to stop the 1-second timer that would
  otherwise fail the run), so this is a test-only hazard rather than a live
  bug. `resetForTest()` was added for tests that need more than one case:
  it stops everything `dispose` does and rebuilds the controllers.

- **The `async void` sweep, and a warning about how it was first done wrong.**
  Six `void ...() async` methods exist in `lib/`. All four badge streams
  (`badge_page`, `home_page`, `profile_page`, `public_profile_page`) are now
  guarded — verified by *reading each one up to its awaited call*, not by
  grepping. The first attempt used an `awk` heuristic looking for `try {`
  within ~20 lines of the method start, and it reported `home_page` as
  guarded when it was not: the `try` it matched belonged to a listener body
  further down. The widget test found the truth the heuristic missed.
  **Do not trust a proximity grep to answer "is this guarded?"** — the
  question is which statement the `try` encloses, which needs the structure,
  not a line count.

  The two remaining unguarded ones are `SearchFriendPage._removeRecent` (a
  `SharedPreferences` write) and `ShareProfilePage._copyLink` (a `Clipboard`
  write) — platform-channel calls with no known failure mode here. Left alone
  deliberately: no test can currently make either throw, so a guard would be
  unverifiable. Worth revisiting if a crash report ever names one.

- **`lib/services/follow_service.dart` is not used by the app.** Nothing in
  `lib/` references `FollowService`; the `follows` writes that actually happen
  are inline in `notifications_page.dart`. It has tests, so the suite covers a
  service no screen calls. Kept rather than deleted — `follows` is listed as a
  planned feature in CLAUDE.md, so this is forward-looking infrastructure
  rather than an accident — but the duplication should be resolved when that
  feature lands, not by writing more tests for it.

- **`ClaimedAreaRepository` contradicts its own doc comment.** It documents
  itself as *"One-time read rather than a real-time listener"*, but its only
  method is `areasStream()` using `.snapshots()` — a live listener on the
  entire `claimedAreas` collection. Same shape as the `home_page.dart` problem
  already flagged in CLAUDE.md, and against the read-cost rule in
  "Security & performance — non-negotiable".


### The badge-progress "bug" that was not one

Reported here briefly as a 100x scale error, then withdrawn after the project
owner said badges had always rendered correctly — **they were right**. Kept as
a record because the reasoning that produced the false alarm is exactly the
reasoning someone will repeat.

The call chain *looks* broken: the Cloud Function stores `progress` as a
percentage (0-100), `BadgeService` passes it through raw, and `DashBadge`
documents `1.0 -> fully unlocked`. Following those three facts gives "a badge at
1% renders as complete".

What that misses is that **nothing renders `BadgeModel.progress`**. Every badge
screen — `ProfilePage`, `PublicProfilePage`, `BadgePage` — builds its own
`HomeBadgeUiModel` from a live `badge_progress` snapshot and does its own
`/100` there. `BadgeService`'s value reaches only the sort, which is
scale-invariant.

The change was reverted. `BadgeModel.progress` now carries a doc comment
saying which scale it is in and why it is not converted, and
`badge_service_test.dart` pins the pass-through with the reasoning attached —
so the next person to spot the apparent mismatch finds the answer instead of
"fixing" it.

**The lesson, and it is the same one as the test-font overflows in 1.2:** trace
to the *rendering* site before calling something a display bug. A plausible
call chain is not evidence.

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


### Three seam shapes, in increasing order of reach

As screens got harder the injection had to go deeper. Worth knowing which
shape a given screen needs before starting:

1. **Service injection** — the screen builds a service (`AuthService()`,
   `ProfileService()`); give the widget an optional parameter for it.
   `LoginScreen`, `RegisterScreen`, `UserSetupScreen`,
   `SavedRouteDetailPage`, `RunSessionDetailPage`.
2. **Repository injection, forwarded through a child** — the screen itself is
   fine but a widget *inside* it reaches a singleton. `RouteLibraryPage` takes
   the repositories only to hand them to `SavedRoutesSection`.
3. **Firestore injection, threaded to the leaf** — the screen queries
   `FirebaseFirestore.instance` directly, often several levels down.
   `FollowingsFollowersPage` passes a `FirebaseFirestore` to its list section
   *and* to the per-row tile, which does its own profile read and its own
   follow-state `snapshots()`. Miss one level and the test fails with
   `[core/no-app]` from whichever widget you forgot.

   The payoff is worth it: with `FakeFirebaseFirestore` these become *real*
   queries against real in-memory documents, including live `snapshots()`
   updates, rather than stubbed return values. `followings_followers_page_test`
   asserts that adding a follow document makes a row appear with no reload.

### Extracting a private widget to reach it, when it moves no logic

`run_tracking_page.dart` cannot be pumped — flutter_map, a live GPS stream and
`FirebaseAuth.instance`. Everything below it was therefore unreachable,
including `_RouteGuidanceCard`, which holds a five-way state machine (off route
/ arrived / arrived-but-skipped-part / pointing / no-heading) and the
turn-vs-bear split at 70 degrees. That is real logic, and exactly the kind that
a field test already caught being wrong once.

Three such classes moved to `lib/widgets/run/` and went from unreachable to
93-100% covered, with 23 tests. The bar for doing this again:

* **The widget must be pure presentation.** These take formatted strings,
  a `RouteGuidance`, and callbacks. No Firebase, no map, no controller.
* **The move must change no behaviour.** The bodies were copied verbatim; only
  the leading underscore and the import paths changed. `flutter analyze` clean
  and the whole suite green is the check.
* **Do not extract to inflate coverage.** `_StatBlock` was left where it is: it
  is a padded `Column` with no branch in it, so a test would assert that
  Flutter renders a `Text`.

What this does *not* do is make the screen testable — `run_tracking_page.dart`
is still 0.2%, and the map shell around it stays integration-test territory.
It makes the *decisions* testable, which is the part that can be wrong.

### No CI. Tests are run locally.

Decided by the project owner. A GitHub Actions workflow was written and then
removed: it would not have tested anything new — the same `flutter analyze`,
the same Dart suite, the same rules suite — only run them automatically on
push. For a project this size, with the suite already run locally, that is a
reasonable trade.

**Do not re-add it.** The reference project this suite is benchmarked against
has no CI either.

### The layout mirrors the reference project

`test/unit_test/`, `test/widget_test/`, `mocks.dart`, `mocks.mocks.dart` — the
same names, so the two are directly comparable. Two additions it does not
have: `helpers/` (the shared pump harness) and `rules/` (the Firestore
security-rule tests, which found the squatting bug in section 5).

The nine loose `*_test.dart` files that used to sit at the root of `test/` were
moved into `unit_test/`, and the default `widget_test.dart` stub — an empty
`void main() {}` left over from `flutter create` — was deleted.

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

### Medium

3. **`widgets/` is 14.5%.** ~20 Firebase-free widgets remain untested, including
   `EnhancedMapGestures` (440 lines) — the rotation dead zone and multi-touch
   release fix are the most intricate untested logic in the app, and the most
   likely to regress silently.
4. **`models/` is 43.9%** and only 41 lines. Cheap to finish.
5. **The loose `*_test.dart` files at the root of `test/`** predate the
   `unit/`/`widget/` split. Move them into `test/unit_test/` when next touched.


### Known limits, accepted for now

- **The Duke badge on the area sheet can only ever be tested absent.** It
  renders only when *both* the `badge_progress` read and the badge image URL
  resolve, and the image goes through Firebase Storage, which is unreachable
  in a widget test. Per the widget's own design an unresolved badge renders
  nothing — identical to "not a Duke" — so there is no state a test can
  distinguish. Recorded rather than worked around.
- **Google/Apple sign-in cannot be driven** past the service boundary; we verify
  the screen calls `signInWithGoogle()` and handles null (cancelled) and throw
  (failed), which is as far as a widget test can go.
- **`UnitPreferences` is an app-lifetime singleton.** `resetForTesting()`
  (`@visibleForTesting`) exists because otherwise one test's choice of miles
  leaks into every later test, and since test order is not guaranteed the
  failure would come and go. Call it in `setUp` **and** `tearDown` when touching
  units.
- **`qr_scanner_page.dart` needs a camera** and is untestable at this level.
- **Four dead screens were deleted** (863 lines): `registration_page.dart`
  (272 — an abandoned twin of the live `register_page.dart`, actively
  confusing), `temp_profile_page.dart` (296), `session_detail_page.dart` (264)
  and `error_page.dart` (31). Each was verified to have no imports and no
  non-comment references to its public classes; `flutter analyze` and the full
  suite stayed green afterwards.

  **Beware the naive check:** searching for class references alone reports
  `run_tracking_page.dart` (1,953 lines) as dead too, because it is reached
  through the `pushRunTracking` *function*, not its class. Verify imports and
  function-level entry points before deleting anything.

- **`test_run_creator_page.dart` (1,669 lines) is deliberately untested and
  excluded from the coverage denominator.** It is a developer-only tool,
  reached from a hidden entry point on the run countdown screen, that
  fabricates running sessions so the area-claiming logic can be exercised
  against specific loop shapes without physically running them. It is
  scaffolding *for* testing the app, not part of the app. **Kept in the
  codebase — do not delete it — just do not spend tests on it.**

  The exclusion lives in `_excludedFromCoverage` in `tool/coverage.dart`
  alongside `firebase_options.dart`, and the report prints the list every run
  so the number stays honest. Excluding code is how a coverage figure becomes
  a lie, so anything added there must be something a test *should not* be
  written for, not merely something awkward to test.

- **Google/Apple sign-in cannot be driven** past the service boundary; we verify
  the screen calls `signInWithGoogle()` and handles null (cancelled) and throw
  (failed), which is as far as a widget test can go.
- **`UnitPreferences` is an app-lifetime singleton.** `resetForTesting()`
  (`@visibleForTesting`) exists because otherwise one test's choice of miles
  leaks into every later test, and since test order is not guaranteed the
  failure would come and go. Call it in `setUp` **and** `tearDown` when touching
  units.
- **`qr_scanner_page.dart` needs a camera** and is untestable at this level.
- **Four screens are unreferenced dead code — 863 lines. Do not test them;
  delete them.** Checked by searching for each file's public class names
  across `lib/`, excluding comment lines:

  | File | Lines | Note |
  |---|---|---|
  | `registration_page.dart` | 272 | `RegistrationScreen` — an abandoned twin of the live `register_page.dart`'s `RegisterScreen`. Two near-identical files, one dead: actively confusing. |
  | `temp_profile_page.dart` | 296 | Named only in a *comment* in `route_search_page.dart`. |
  | `session_detail_page.dart` | 264 | Already flagged in CLAUDE.md as superseded. |
  | `error_page.dart` | 31 | Its "Return to login" button is `onPressed: (){}` — a dead button on a dead screen. |

  They also inflate the coverage denominator by 863 lines that can never
  legitimately be covered. **Beware the naive check:** searching for class
  references alone reports `run_tracking_page.dart` as dead too, because it is
  reached through the `pushRunTracking` *function*, not its class. Verify
  before deleting anything.


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

### The finding: private-metrics squatting (fixed)

<a name="the-finding-private-metrics-squatting-fixed"></a>

**Fixed.** Kept in full because the reasoning is the useful part, and because
the same shape of bug is easy to reintroduce anywhere a rule authorizes off a
field in the document body rather than off the path.

#### What was wrong

`runningSessions/{id}/private/metrics` used a **fixed document ID**, and the
rule authorized `create` off the document's own denormalized `userId`:

```
allow create: if isSignedIn()
  && request.resource.data.userId == request.auth.uid   // says nothing about
  && validHeartRate(...);                               // whose session it is
```

Every user addressed the *same slot*. So Bob could write into Alice's session
just by stamping his own uid in the body. Measured against the emulator:

```
PROBE bob creates metrics under alice session: ALLOWED
PROBE alice then writes her own metrics:       DENIED   <- locked out
PROBE alice reads the slot:                    DENIED
PROBE alice deletes the squatted doc:          DENIED
```

Not merely litter: once Bob's document occupied the slot, Alice's own write
became an `update`, gated on the **existing** document's `userId` — so she was
refused, and could neither read nor delete his document to clear it. Session
IDs are readable by any signed-in user (the collection is world-readable by
design), so it was enumerable across the whole app.

#### The fix: make the document ID the owner's uid

```
match /private/{ownerUid} {
  allow read:   if isSelf(ownerUid) || <transitional legacy clause>;
  allow create: if isSelf(ownerUid)
                && request.resource.data.userId == ownerUid
                && validHeartRate(...);
  allow update: if isSelf(ownerUid) && ...;
  allow delete: if isSelf(ownerUid) || <transitional legacy clause>;
}
```

`runningSessions/{sessionId}/private/{uid}`. A client can only ever *name* its
own slot, so the collision is **unreachable rather than merely forbidden** —
the strongest form of this kind of fix, and the reason it beat the two options
originally on the table:

| | Cost | Migration | Result |
|---|---|---|---|
| `get()` the parent session | a billed read per write | none | forbidden |
| move to `runPrivateMetrics/{uid}_{sessionId}` | none | yes, plus `saveSession` rework | unreachable |
| **document ID = uid** (chosen) | **none** | **none in practice** | **unreachable** |

Same insight as `favoriteRoutes/{uid}_{routeId}`, which already puts the owner
in the path — so this is a pattern the codebase already had, applied where it
had been missed.

Replayed after the change:

```
PROBE bob squats alice slot        : DENIED
PROBE alice writes her own metrics : ALLOWED
PROBE alice reads her own          : ALLOWED
PROBE bob reads alice metrics      : DENIED
PROBE alice deletes her own        : ALLOWED
```

#### Two things it improved on the way

- **A missing document now reads as an empty snapshot for the owner.** It used
  to return `permission-denied` — the rule needed a `userId` a missing document
  does not have — and `fetchPrivateMetrics` had to swallow that error, which
  was indistinguishable from a real denial. Another user is now refused by the
  *path*, before existence is ever consulted, so nothing leaks about whose runs
  carry watch data and the owner gets a clean answer. That swallow is gone.
- **A remaining, accepted gap:** a user can still create a document in *their
  own* slot under someone else's session. It blocks nobody, is readable by
  nobody else, and is swept with the session on account deletion. Preventing it
  needs exactly the `get()` this design avoids. Not worth it.

#### Deployment order

1. **Deploy `firestore.rules` first.** The new rules accept both shapes (the
   transitional clause keeps legacy `metrics` documents readable and
   deletable), so old app builds keep working — they simply cannot write the
   old slot any more.
2. Ship the app build.
3. Run `functions/_migrate_private_metrics.js` (updated to write uid-addressed
   documents) if any legacy documents exist. **Production held 11 sessions and
   zero heart-rate records at last check**, so this is likely a no-op — verify
   before assuming.
4. Delete the transitional clause from the rules, and
   `RunPrivateMetrics.legacyDocId`, once step 3 reports nothing left.

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

## 6. CI

`.github/workflows/tests.yml` — runs on every push to `main` or `dev/**`, and
on every pull request into `main`. Two **independent** jobs:

| Job | What it does |
|---|---|
| `Analyze + test` | `flutter pub get` → mock-staleness check → `flutter analyze` → `dart run tool/coverage.dart --min 30`, uploading `lcov.info` and `report.html` as artifacts |
| `Firestore rules` | Node 20 + JDK 21 → `npm ci` → `npm test` (boots the emulator, runs `node --test` against the real `firestore.rules`) |

### Decisions worth not undoing

- **The two jobs are deliberately independent.** The rules are a different
  language, runner and failure mode from the Flutter suite; a rules regression
  must not be hidden behind a Dart compile error, or the reverse.
- **Flutter is pinned to `3.44.0`, not `stable`.** This project has already
  lost a session to two SDKs disagreeing (see 1.1). A floating channel would
  reintroduce exactly that, remotely, where it is harder to debug.
- **`tool/coverage.dart`, not `flutter test --coverage`** — for the reason in
  section 3: the built-in figure is a percentage of the tested subset and
  *rises* when you delete a test.
- **`--min 30` is a ratchet, not a target.** Coverage is 34.3% now. Raise the
  floor as it climbs; **never lower it to make a red build green** — that is
  how the number stops meaning anything.
- **JDK 21 on CI, though the local pin is firebase-tools 14.19.0.** The pin
  exists only because this dev machine has no JDK newer than 19 (see 5). CI
  has no such constraint, so it runs the version firebase-tools actually wants.
- **No secrets are needed.** `MapStyle` reads its Jawg token via
  `String.fromEnvironment`, which defaults to empty, and no test renders real
  tiles. Nothing in the suite touches the network. If a test ever needs the
  token, add it as a repository secret rather than committing it.

### Verified before committing to it

Each step was run locally first, rather than pushed and watched:

- `dart run tool/coverage.dart --min 30` → exit 0; `--min 99` → exit 1, so the
  gate genuinely fails a build.
- `npm ci` in `test/rules` → exit 0 from the committed lockfile, and the 109
  rules tests pass afterwards.
- `dart run build_runner build` → "wrote 0 outputs", so the committed mocks are
  current.

**One caveat:** the mock-staleness check is meaningful only on Linux. Windows
has `core.autocrlf=true`, so a local run of that `git diff` is never empty.

---

## 7. Quick reference

```sh
flutter test                              # 391 tests, ~17s
flutter test test/widget_test/                 # one layer
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
