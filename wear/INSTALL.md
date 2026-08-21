# Installing Dash on a Wear OS watch

Wear OS watches have no USB data port, so everything happens over Wi-Fi. Both
devices must be on the **same Wi-Fi network** as the computer doing the install.

## Before you start

- A **Wear OS 3 or newer** watch — Galaxy Watch 4 or later, any Pixel Watch,
  TicWatch Pro 5. **Galaxy Watch 3 and earlier run Tizen and cannot run this
  app at all**, regardless of settings.
- `adb` installed (comes with Android Studio, at
  `%LOCALAPPDATA%\Android\Sdk\platform-tools\adb.exe` on Windows).
- Both APKs:
  - `build/app/outputs/flutter-apk/app-release.apk` — the phone app
  - `wear/build/app/outputs/flutter-apk/app-release.apk` — the watch app

Build them yourself with:

```bash
flutter build apk --release --dart-define-from-file=config/secrets.local.json
cd wear && flutter build apk --release
```

The phone build needs `config/secrets.local.json` (copy `secrets.example.json`
and fill in the Jawg token) or the map tiles will not load.

## 1. Enable developer mode on the watch

1. **Settings → About watch → Software** → tap **Software version** seven times
2. Back out to **Settings → Developer options**
3. Turn on **ADB debugging**
4. Turn on **Wireless debugging**

## 2. Pair the computer to the watch

This is a **one-time** pairing per computer.

1. On the watch: **Developer options → Wireless debugging → Pair new device**
2. It shows a 6-digit code and an `IP:PORT` — **leave this screen open**, the
   code expires the moment you back out, and the port changes every time
3. On the computer:

```bash
adb pair 192.168.1.63:37000 123456     # use the IP:PORT and code from the watch
```

Expect `Successfully paired`.

## 3. Connect

Go **back one screen** to **Wireless debugging**. It shows a *different*
`IP:PORT` — this is the connect port, not the pairing port. Mixing them up is
the most common failure here.

```bash
adb connect 192.168.1.63:43637
adb devices                            # the watch should appear
```

## 4. Install

```bash
# Watch
adb -s 192.168.1.63:43637 install -r wear/build/app/outputs/flutter-apk/app-release.apk

# Phone (USB is fine for this one)
adb -s <PHONE_SERIAL> install -r build/app/outputs/flutter-apk/app-release.apk
```

`-r` reinstalls in place and **keeps app data**, so nobody has to log in again.

## 5. First launch

1. Open **Dash** on the phone and sign in
2. Open **Dash** on the watch — accept the **heart rate** permission prompt
3. Start a run on the phone; the numbers should appear on the watch within a
   second

## Things that will trip you up

**The phone and watch apps must be the same build.** They share an
`applicationId` (`com.example.dash`) and must be signed with the same key. Both
are currently signed with the local debug key, which means **APKs built on one
developer's machine may not talk to APKs built on another's** — build both from
the same machine, or install both from the same pair of files.

**The connection drops when the watch sleeps or reboots.** Re-run `adb connect`
with the port from the Wireless debugging screen. The *pairing* usually
survives, so step 2 rarely needs repeating — try connecting first.

**Take the watch off the charger while testing.** Samsung's charging screen sits
on top of everything and hides the app.

**The watch app only works while it is open.** Starting a run from the watch
when the phone app is closed does nothing, and closing the watch app stops the
display updating. Both are known gaps — a `WearableListenerService` and a
foreground service are not built yet.

**Heart rate needs skin contact.** A loose strap reads `--` no matter what the
software does. It also takes 5–10 seconds to acquire after the app opens.

## Troubleshooting

| Symptom | Cause |
|---|---|
| `failed to connect` | Wrong port — you used the pairing port instead of the connect one, or it changed after a sleep |
| `device unauthorized` | Pairing was revoked; redo step 2 |
| `INSTALL_FAILED_UPDATE_INCOMPATIBLE` | Built with a different signing key. `adb uninstall com.example.dash` on the watch first — this wipes its data |
| Watch shows numbers but no BPM | Permission refused, or poor skin contact. Check with:<br>`adb -s <watch> shell dumpsys package com.example.dash \| grep READ_HEART_RATE` |
| Watch stuck on START while a run is going | The watch app was closed when the run began — reopen it and it asks the phone for the current state |
