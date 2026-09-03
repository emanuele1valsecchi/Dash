# Testing

## Running the tests

```sh
flutter test                 # everything
flutter test test/widget/    # one layer
flutter test --coverage      # writes coverage/lcov.info

cd test/rules && npm test    # 98 Firestore rules tests (own emulator, own npm package)
```

### If every test fails to compile, read this first

A failure that looks like this is **not** a problem with the tests:

```
Error: Type 'ui.DisplayCornerRadii' not found.
Error: The getter 'displayCornerRadii' isn't defined for the type 'FlutterView'.
```

It means `flutter` on your `PATH` is a *different install* from the one this
project is resolved against. `.dart_tool/package_config.json` records absolute
paths to a specific SDK's `packages/flutter`; if the `flutter` binary you run
belongs to another install, you compile one SDK's framework sources against a
different SDK's `dart:ui`, and it fails deep inside the framework rather than
saying anything useful.

Check with `where flutter` (PowerShell) or `which -a flutter` (bash). This
project needs **Flutter >= 3.44 / Dart >= 3.12**, which `pubspec.yaml`'s
`environment:` block now pins so a too-old SDK says so plainly instead.

A related symptom, after switching SDKs, is:

```
Can't load Kernel binary: Invalid kernel binary format version
```

That is a stale build hook cache. Delete `.dart_tool/hooks_runner` and re-run.

## Layout

| Path | What lives there |
|---|---|
| `test/unit/` | Pure Dart: geometry, formatting, leaderboard rules. No widgets. |
| `test/widget/` | Single widgets rendered and driven with `WidgetTester`. |
| `test/helpers/` | Shared harness (`pump_app.dart`). |
| `test/rules/` | Firestore security-rule tests (Node, local emulator). |
| `integration_test/` | Whole-app smoke test on a device/emulator. |

The loose `*_test.dart` files at the root of `test/` predate this split and are
pure unit tests; they can move into `test/unit/` whenever someone is touching
them anyway.

## The harness

Use `pumpDashWidget` from `test/helpers/pump_app.dart` rather than calling
`tester.pumpWidget(MaterialApp(...))` directly. It wraps the widget in the
app's **real** theme (`buildAppTheme()`, extracted from `main.dart` for exactly
this purpose).

That is load-bearing, not tidiness: several widgets resolve theme *extensions*
with a non-null assertion — `context.paddingMd` is
`Theme.of(this).extension<ResponsiveSpacing>()!` — so a widget pumped under a
bare `MaterialApp()` throws before it renders anything.

Two arguments worth knowing:

- **`surfaceSize:`** sets `tester.view.physicalSize` (plus a device pixel ratio
  of 1.0), *not* `binding.setSurfaceSize`. The latter resizes the render
  surface but leaves `MediaQuery` reporting the default 800x600, so a widget
  sizing itself from `MediaQuery.sizeOf` computes against 800 and is then
  clipped — the assertion passes or fails for reasons unrelated to the widget.
  `kPhoneSurface` is a typical phone viewport.
- **`wrapInScaffold: false`** for a widget that brings its own `Scaffold`, or
  that must *be* the route (a dialog under test).

One gotcha the harness cannot hide: `Scaffold`'s body is laid out with **tight**
constraints, so a widget that asks for a fraction of the screen width gets
stretched back to full width. When that is what you are asserting on, wrap the
subject in an `Align` — which is what a real `Column`/`ListView` caller does
anyway. See the `width` group in `dash_text_form_field_test.dart`.

## The test font will lie to you about layout

`flutter test` does not use real fonts. It substitutes a test font in which
**every glyph is a full em square**, so text measures far wider than it does on
a device:

```
"Continue with Google" @15px -> 300.0px   (15.0px/char)   ~145px on a real device
"Share External"       @14px -> 196.0px   (14.0px/char)    ~95px on a real device
```

Roughly **2x too wide**, because real proportional text averages about half an
em per character.

The consequence: a `RenderFlex overflowed by N pixels` in a widget test is
**not** by itself evidence of a user-visible bug. It happened here — two
"overflow bugs" were reported off the back of it, and neither was real.

Before acting on an overflow, measure:

```dart
final tp = TextPainter(
  text: const TextSpan(text: 'Your label', style: TextStyle(fontSize: 15)),
  textDirection: TextDirection.ltr,
)..layout();
debugPrint('${tp.width / 'Your label'.length} px per char');
```

If that prints the font size back at you, you are looking at the test font and
the overflow is an artifact.

What the check is still good for is the **conservative** direction: if a layout
survives the fat test font, it is safe with a comfortable margin on a real
device — which also covers a large accessibility text scale. So keep such
assertions where they pass; just never read a failure as a bug without
measuring first. Where a page trips the artifact (see `login_page_test.dart`),
widen the test viewport and assert behaviour instead of pixels.


## CI

`.github/workflows/tests.yml` runs both suites on every push to `main` or
`dev/**` and on every PR into `main`:

- **Analyze + test** — `flutter analyze`, then
  `dart run tool/coverage.dart --min 30`. Coverage reports are uploaded as
  build artifacts, so you can download `report.html` from a run.
- **Firestore rules** — boots the emulator and runs the 109 rules tests.

The two jobs are independent on purpose: a rules regression should not be
hidden behind a Dart compile error, or the reverse.

Flutter is pinned to **3.44.0**, not `stable` — see TEST_NOTES.md section 1.1
for why a floating channel is a trap in this repo specifically.

`--min 30` is a **ratchet**. Raise it as coverage climbs; never lower it to
turn a red build green.

## What is not covered yet, and why

`flutter test --coverage` only reports files a test actually imports, so the
percentage it prints flatters the suite badly — it *rises* when you delete the
only test importing a poorly-covered file. Use `dart run tool/coverage.dart`
instead, which imports all of `lib/` first so the denominator is the whole app,
and which reads the Flutter SDK out of `package_config.json` so it works
whatever your PATH says.

Every service now takes its Firebase collaborators as optional constructor
arguments, defaulting to the real singletons, so no call site changed:

```dart
RouteRepository.withDependencies(db: FakeFirebaseFirestore(), auth: MockFirebaseAuth());
ProfileService(firestore: fake);   // plain classes take a public constructor
```

Two details of that seam are load-bearing:

- **Singletons keep a private constructor** plus a `@visibleForTesting`
  factory, so production still gets exactly one instance and a test cannot
  accidentally create a second live repository with its own cache.
- **The defaults resolve lazily** (`late final _db = _dbOverride ?? ...`).
  Several screens build their services in a field initializer
  (`final _authService = AuthService();`), so an eager
  `FirebaseFirestore.instance` threw `[core/no-app]` at *construction* and made
  those screens unconstructible in a test even though the service itself was
  injectable.

What remains uncovered is mostly `lib/screens/`. A screen that builds its own
services inline can be rendered and driven, but cannot be given fakes — so its
success paths (anything that awaits a real Firestore read) stay out of reach
until those services are passed in rather than constructed. `LoginScreen` is
the worked example: its validation, its password toggle and its failure branch
are all tested; its successful sign-in is not.

## Cloud Functions

`functions/_verify_*.js` are hand-rolled assertion scripts run with plain
`node`, not a test runner, so they produce no machine-readable result and are
invisible to any coverage or CI summary. Moving them to `node:test` would fix
that without rewriting the assertions themselves.
