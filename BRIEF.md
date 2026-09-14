# Mikser — BRIEF

Per-app volume mixer for Mieszko's MacBook Pro (Apple M2 Pro, macOS 26.6.2). Personal use only.
Decided in the grill of 2026-09-14 (eleven questions, all answered). This brief is the completion
promise; the original task wording is not.

## Goal

A menu bar app that lets Mieszko set each audio app's level from 0 to 100 percent (plus mute),
applied seamlessly in real time, remembered across relaunches and reboots, running invisibly at
login, and costing nothing while idle.

## End state (best possible outcome)

- `Mikser.app` is installed in `/Applications`, signed with a local self-signed identity
  ("Mikser Dev"), registered as a login item, and shows one icon in the menu bar and nothing else
  (no Dock icon, no window, no Settings screen).
- Clicking the icon opens a compact popover (about 300 px wide, system light/dark) within 100 ms:
  one row per audio app (app icon, name, slider, percentage, mute button), apps playing right now
  first. Footer: "Launch at login" toggle, "Reset audio" button, Quit. Clicking anywhere else
  closes it. Row order is frozen while the popover is open so rows never jump under the cursor.
  Empty state: "No apps are playing audio."
- Moving a slider changes that app's level within 50 ms with no click or pop. At 100 and unmuted
  the app is not touched at all: no tap exists, it plays bit-perfect with zero overhead.
- Levels and mute states persist per app identity (bundle id) across app relaunch, Mikser relaunch
  and reboot.
- Follows the system default output device, whatever it is; rebuilds silently on output change,
  sample-rate change, process-set change and after wake from sleep. Quitting Mikser restores every
  app to normal audio immediately.
- Idle: 0 % CPU and at or below 40 MB resident. One scaled app: under 1 % CPU for the Mikser
  process. All of it measured on this Mac, never claimed.

## Architecture (how it works)

- **Toolchain:** Swift 6.3 from Command Line Tools, SwiftPM, no Xcode. `swift-tools-version:6.0`,
  platform macOS 15, Swift language mode 5 (keeps concurrency friction low around C callbacks).
  Targets: `MikserCore` (library, no UI, testable), `Mikser` (executable: AppKit + SwiftUI),
  `MikserSelfTest` (an executable test runner, `swift run mikser-selftest`, exit code non-zero on any
  failed check; Command Line Tools ship no working XCTest or Swift Testing runtime, verified
  2026-09-14, so `swift test` is not used).
- **Detection (no timers, no polling, anywhere):** Core Audio process objects from
  `kAudioHardwarePropertyProcessObjectList` on the system object, with a property listener block
  registered on a non-nil dispatch queue (mandatory on macOS 26; nil silently fails). Per process:
  `kAudioProcessPropertyPID`, `kAudioProcessPropertyBundleID`, `kAudioProcessPropertyIsRunningOutput`
  (listener per process; drives the "playing" state). Rows are these processes grouped per app.
- **Grouping (pid → app):** 1) `responsibility_get_pid_responsible_for_pid` via `dlsym` (this is
  what macOS itself uses; it maps Safari's WebKit XPC processes to Safari); 2) fallback: walk parent
  pids (sysctl kinfo_proc) until an `NSRunningApplication` with a bundle id is found, max 6 hops;
  3) fallback: the process's own bundle id with helper suffixes stripped; 4) fallback: process
  name. Group key = bundle id (or `name:<procname>`). Display name and icon from
  `NSRunningApplication`; generic icon otherwise. Mikser itself is never listed.
- **Scaling (per app group, only while level < 100 or muted):** one
  `CATapDescription(stereoMixdownOfProcesses: <all process objects of the group>)` with
  `muteBehavior = .mutedWhenTapped`, `isPrivate = true`, name `Mikser:<groupKey>`; one private
  aggregate device (`kAudioAggregateDeviceIsPrivateKey`) whose MAIN sub-device is the current
  default output (`kAudioAggregateDeviceMainSubDeviceKey`, sub-device list = that device) and whose
  tap list holds the tap with drift compensation on; one IOProc via
  `AudioDeviceCreateIOProcIDWithBlock` that copies the tap's input buffers to the device's output
  buffers multiplied by the gain, then `AudioDeviceStart`. Wait for the aggregate to be ready
  before starting (poll its stream configuration up to 1 s). Handle interleaved, non-interleaved
  and mono buffers from what the buffer list actually contains.
- **Gain:** atomic Float target per group; inside the IOProc a one-pole smoother
  (`g += (target - g) * a`, `a = 1 - exp(-1 / (0.030 * sampleRate))`) applied per sample, so any
  change ramps over about 30 ms and never clicks. Mute = target 0. The IOProc block does no
  allocation, no locks, no Objective-C, no logging. It updates two atomics per callback: peak-in and
  peak-out (for the stats channel; a max per buffer is nearly free).
- **Untouched at 100:** when a group returns to level 100 and unmuted, its tap and aggregate are
  destroyed after 2 s of hysteresis (so sliding through 100 does not thrash) and the app plays
  directly again. A short gap (well under 100 ms) when the path switches is accepted.
- **Rebuild triggers (full teardown + rebuild of BOTH tap and aggregate, per the macOS 26.5-beta
  report that recreating only one is unreliable):** default output device change
  (`kAudioHardwarePropertyDefaultOutputDevice`), nominal sample-rate change of that device, the
  group's process set change (helper appeared/exited), `NSWorkspace.didWakeNotification`, and the
  footer's "Reset audio" (rebuilds everything). Per-app levels carry across every rebuild.
- **Fail safe:** any error in a group's audio path (create/start/IOProc failure) drops that group's
  tap so the app plays normally at full volume, logs once via `os_log`, and marks the row with a
  small warning glyph until the next successful rebuild. Never leave an app silent.
- **Persistence:** `UserDefaults` suite `com.mieszko.mikser`, a Codable dictionary
  `[groupKey: {level: Double, muted: Bool}]`; `launchAtLogin` via `SMAppService.mainApp`.
- **UI:** AppKit `NSStatusItem` (SF Symbol `slider.horizontal.3`, template image) +
  `NSPopover` (`.transient`) hosting SwiftUI via `NSHostingController`; a global mouse-down monitor
  closes the popover on outside clicks. State comes from an `@Observable` `MixerModel`
  (main-actor) that owns the registry, engine and settings.
- **Control channel (for first-hand verification, hidden from the UI):**
  `DistributedNotificationCenter` name `com.mieszko.mikser.control`, userInfo
  `{cmd: set|mute|unmute|reset|stats|dump, app: <groupKey or display name>, level: <0…1>}`.
  Replies (`stats`: per-group peak-in/peak-out/level/tapActive, tap count, rebuild count, last
  error; `dump`: all rows) are written as JSON to `~/Library/Application Support/Mikser/reply.json`.
  `scripts/mikserctl` posts a command and prints the reply.
- **Bundle and signing:** `scripts/make-cert.sh` creates the self-signed code-signing identity
  "Mikser Dev" in the login keychain (once). `scripts/build.sh` runs `swift build -c release`,
  assembles `build/Mikser.app` (Info.plist: `CFBundleIdentifier com.mieszko.mikser`,
  `LSUIElement true`, `LSMinimumSystemVersion 15.0`, `NSAudioCaptureUsageDescription`,
  version), signs it with "Mikser Dev" and identifier `com.mieszko.mikser` (no sandbox, no
  hardened runtime, no notarization). `scripts/install.sh` copies it to `/Applications` and
  relaunches. `scripts/measure.sh` samples CPU and RSS for the definition of done.

## Definition of done (every item measured first-hand on this Mac)

1. `swift build -c release` and `swift run mikser-selftest` pass. Tests cover: ramp coefficient and per-sample
   step bound, gain applied to interleaved/non-interleaved/mono buffers, mute and hysteresis state
   machine, grouping fallbacks, settings round-trip, control-message parsing. Every regression test
   is mutation-tested (shown to fail against the old code).
2. `scripts/build.sh` produces a signed `Mikser.app`; `codesign -dv` shows authority "Mikser Dev"
   and identifier `com.mieszko.mikser`; a rebuild does not re-trigger the permission prompt.
3. First scaling triggers the System Audio Recording prompt exactly once; after Allow, a scaled
   test tone (`afplay` of a generated sine) at level 0.2 measures peak-out / peak-in = 0.20 ± 0.02
   via `mikserctl stats`.
4. Idle 60 s, sampled every 2 s: %CPU is 0.0 in every sample, RSS ≤ 40 MB.
5. One scaled app playing for 60 s: mean %CPU of the Mikser process < 1.0.
6. An app at 100 and unmuted has no tap object (`kAudioHardwarePropertyTapList` on the system
   object contains no `Mikser:` tap for it).
7. A `set` command becomes effective within 50 ms (stats timestamp of target change vs. IOProc
   observation), and the ramp test proves no per-sample step larger than the 30 ms one-pole allows.
8. Switching the default output (USB device ↔ built-in speakers) while an app is scaled: audio
   continues at the set level within 1 s, no crash, no leftover aggregate device.
9. Quit Mikser while scaling: the app returns to full volume immediately; no `Mikser:` tap and no
   Mikser aggregate device remains.
10. Login item registers and shows in System Settings; popover opens in under 100 ms (debug timing
    in the log).
11. Mieszko's ear test with real apps (Spotify or YouTube in Chrome, Safari): slider feels immediate,
    no clicks or pops, levels survive a relaunch. His sign-off closes v1.

## Out of scope (v1, decided)

Boost above 100 %; per-app output routing; multi-output playback; equalizer; headphone profiles;
auto-ducking; level meters or anything that needs every app tapped all the time; global keyboard
shortcuts; microphone or input control; a Settings window; menu bar volume readouts; sound
effects; notarization, App Store, distribution to anyone else; macOS older than 15; a background
silence watchdog (held back unless the silent-tap bug shows up on this Mac).

## Build method

Substantial-tier loop per the standing doctrine: Codex writes one packet at a time
(`--sandbox workspace-write` inside this git repository, one commit per packet), Claude verifies
every claim first-hand (builds, tests, live audio, measurements), a fresh Fable agent and a Codex
critic red-team the result, fixes are regression-locked, then Mieszko's ear test. Codex settings
are chosen per packet and noted in `plan.json`.
