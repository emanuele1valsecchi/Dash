# Integration tests

These drive the **real app** on a **real device or emulator**, against the
**real Firebase project**. Nothing is mocked.

```sh
flutter devices                                   # need at least one
flutter test integration_test/app_launch_test.dart
flutter test integration_test                     # all of them
```

They do **not** run under a plain `flutter test`, which is deliberate: that
keeps the unit and widget suite fast and offline. Nothing here is part of the
370-test default run.

## Why bother, when `test/` already covers so much

Every test under `test/` substitutes something — the Firestore, the auth
service, the fonts, the platform channels. So none of them can tell you that:

- `Firebase.initializeApp()` actually connects
- `google-services.json` / `GoogleService-Info.plist` are wired into the build
- the declared permissions are the ones the app actually needs
- the first frame renders on a phone at all
- a real GPS fix flows through `RunSessionController` into a claimed area

**A build that fails on launch passes the entire unit suite.** That is the gap
this directory exists to close.

## What is here, and what is not

Currently just `app_launch_test.dart` — a smoke test that the app boots and
reaches a screen. That is the highest-value single test in this directory,
because it fails on exactly the class of breakage the rest of the suite cannot
see.

Deliberately **not** written yet, in rough priority order:

1. **Sign in and land on the home screen.** The flow that widget tests
   structurally cannot reach — `LoginScreen` navigates to `RootScreen`, which
   is the whole app shell (see `test/widget/login_page_auth_flow_test.dart` for
   why that stops at the widget level). Needs a dedicated test account, and a
   decision about where its credentials live (**not** in the repo).
2. **Plan a route and start a run.** Touches the map, OpenRouteService and the
   location permission prompt.
3. **Record a run and see a claimed area appear.** The core loop, and the only
   way to exercise the Cloud Function end to end.

Each needs test-account and test-data handling that does not exist yet — see
`TEST_NOTES.md` for the open questions.
