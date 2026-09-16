# Mikser

Per-app volume for macOS, from the menu bar. No kernel extension, no virtual audio driver: each
scaled app gets a Core Audio process tap (muted when tapped) re-rendered through a private aggregate
device with a ramped gain. Apps left at 100 % are never touched.

Requires macOS 15 or newer on Apple Silicon and the Xcode Command Line Tools (a full Xcode install is
not needed).

## Build, sign, install

```bash
scripts/make-cert.sh     # once: creates the local "Mikser Dev" signing identity
scripts/build.sh         # swift build -c release → build/Mikser.app, signed
scripts/install.sh       # build + replace /Applications/Mikser.app + launch
swift run mikser-selftest   # 109 checks; --live-registry and --taps are live probes
scripts/measure.sh 60 2 idle   # CPU/RSS samples of the running app
```

Things macOS asks for once:

1. Creating the "Mikser Dev" signing identity may open a Keychain dialog asking for your login
   password, and the first codesign asks to allow key access.
2. The first time Mikser scales an app, macOS asks for System Audio Recording. Click Allow. The
   stable signing identity keeps that answer across rebuilds.
3. Enabling launch at login may show a notification or ask for confirmation in
   System Settings › General › Login Items.

## Using it

Click the slider icon in the menu bar. One row per audio app: slider 0–100 %, mute button, a small
waveform when the app is playing. Levels persist per app. Footer: launch at login, "Reset audio"
(tears down and rebuilds every scaled path), Quit (restores every app instantly).

## Control channel (verification)

`scripts/mikserctl ping | set <app> <0…1> | mute <app> | unmute <app> | reset | stats | dump | quit |
output list | output set <name> | login on|off|status | popover open|close | snapshot`. Replies are
JSON (also written to `~/Library/Application Support/Mikser/reply.json`).

## Layout

- `Sources/MikserCore/` — process registry, taps, aggregate devices, gain math, model, settings.
- `Sources/Mikser/` — the menu bar app (SwiftUI popover).
- `Sources/MikserCtl/` — the `mikserctl` command-line client.
- `Sources/MikserSelfTest/` — the self-test runner (Command Line Tools ship no XCTest).
- `scripts/` — certificate, build, install and measurement helpers.

## Notes and limits

- A scaled app plays through the **system default output**. An app that chose another device itself
  (a call app on a USB headset, Music on AirPlay) is moved to the default output while it is scaled.
- The audio path of a scaled app pauses while the app is silent and resumes when sound starts; the
  first 20–150 ms of a new sound can be lost (longest on Bluetooth). Music and video do not notice.
- When a path is rebuilt (output change, helper change, reset), the old one fades out while the new
  one fades in, so a muted app stays silent and a scaled one keeps its level.
- The control channel is local and unauthenticated: any process running as you can drive it. It
  grants nothing such a process could not do already, except muting a specific app.
- `mikser-selftest --taps` sees only what other processes see; Mikser's taps and aggregate devices
  are private, so it reports none while `mikserctl stats` reports them.
