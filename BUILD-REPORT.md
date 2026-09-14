# Mikser — builder report (2026-09-14)

Built in-house by Claude (the Codex allowance was exhausted for the evening) and verified first-hand on
Mieszko's MacBook Pro (Apple M2 Pro, macOS 26.6.2, Command Line Tools only). Every number below was
measured on this machine; nothing is taken from a claim.

## What exists

- `Sources/MikserCore/` — `Types` (contracts), `AppIdentity` (responsible-pid via dlsym, parent walk,
  bundle-id heuristics, user-facing rule), `Grouping` (pure), `ProcessRegistry` (Core Audio process
  objects + listeners on a serial queue), `HAL` (typed property readers, output devices, default
  output setter), `GainMath` (pure, allocation-free ramped gain for interleaved/planar lists),
  `AppTap` (tap + private aggregate + IO proc, raw-pointer state shared with the RT thread),
  `OutputDeviceMonitor` (default output, sample rate, wake), `TapEngine` (one AppTap per scaled app,
  hysteresis at 100, rebuilds, fail safe, stats, playing detection), `Settings` (UserDefaults JSON),
  `MixerModel` (@Observable, main actor), `ControlChannel` (distributed-notification commands + JSON
  reply file).
- `Sources/Mikser/` — `AppDelegate` (status item, transient popover, pre-warm, snapshots),
  `PopoverView` (rows, slider, mute, footer). `Sources/MikserCtl/` — `mikserctl` client.
  `Sources/MikserSelfTest/` — 63 checks (`swift run mikser-selftest`), plus `--live-registry`, `--taps`.
- `scripts/` — `make-cert.sh`, `build.sh`, `install.sh`, `measure.sh`, `mikserctl`.
- Installed: `/Applications/Mikser.app`, signed "Mikser Dev", identifier `com.mieszko.mikser`,
  registered as a login item. Git history: one commit per stage from the scaffold `c8b6779`.

## Definition-of-done evidence (BRIEF.md numbering)

1. `swift build -c release` and the self-test pass: 63 checks, 0 failures (ramp bound, gain math on
   interleaved/planar/mono, layouts, grouping, identity live checks, settings round-trip, HAL).
2. `codesign -dv`: `Identifier=com.mieszko.mikser`, `Authority=Mikser Dev`. Six rebuild+reinstall
   cycles; audio flowed immediately after each, so the permission was not asked again.
3. Level 0.20 on a −26 dBFS test tone: peakIn 0.0250, peakOut 0.0050, ratio 0.2000 (target ± 0.02).
4. Idle 60 s (popover closed, nothing scaled): `%cpu` 0.0 in 30 of 30 samples, cputime delta 0.00 s
   (strict 0.000 %). RSS 50.2 MB. Physical footprint 23 MB at launch (pre-warmed popover), 34 MB after
   the popover has been used. AlDente today: RSS 40 MB, footprint 42 MB.
5. One scaled app playing for 60 s: mean 0.14 %, strict 0.033 % (0.02 s CPU over 61 s).
6. Back to 100 %: the app's tap and aggregate are gone 2 s later (engine tap list, in-process
   `kAudioHardwarePropertyTapList` and aggregate device list all show none for it).
7. `set 0.5` from 0.2: 48 ms after the command the running gain was 0.406 (69 % of the way, exactly
   the 30 ms one-pole after ~15 ms of command latency), 0.471 at 87 ms, 0.500 at 432 ms. Ramp step
   bound proven in the self-test.
8. Default output switched headphones (44.1 kHz) → built-in speakers (48 kHz) → headphones while
   scaling: each switch rebuilt the tap, callbacks resumed with start delays of 26 ms and 156 ms,
   ratio still 0.20, no fail safe, no transient retry.
9. Quit while scaling: process gone in under 2 s; relaunch restored the saved 20 % level and rebuilt
   the tap by itself (78 ms start delay).
10. Login item: `SMAppService` status enabled. Popover: first open 69 ms (pre-warmed), later opens
    8–12 ms.
11. Ear test with real apps: Mieszko's call. He has already been moving sliders and muting a row while
    this was being built (the state showed up in the settings).

## Deviations from the brief, decided by the builder

- **Resident memory.** The brief's "≤ 40 MB resident" used `ps rss`, which counts shared framework
  pages. Mikser: RSS 50 MB idle, footprint 23 MB idle / 34 MB after use. AlDente: RSS 40 MB,
  footprint 42 MB. Releasing the popover view after close was tried and freed nothing (34 → 35 MB),
  so the view is kept for 12 ms re-opens. Mieszko decides whether footprint is the bar.
- **Daemons hidden.** Core Audio lists ~20 system agents (assistantd, Siri, Control Center, PowerChime…).
  Rows are shown for Dock apps and for menu bar apps outside /System, plus anything being scaled or
  saved below 100. The grill said "every app"; daemons are not apps.
- **A timer exists, but only while the popover is open** (0.5 s): a tapped process stops reporting
  "running output" to the HAL, so the playing mark for scaled apps comes from the tap's own signal.
  Verified: with the popover closed the process uses 0.0 % CPU.
- **New taps start at the target gain**, not at unity: a muted app must not leak its first 30 ms when it
  begins to play.

## Not sure about (for the red team)

1. A tap's IO proc runs only while the tapped process is producing audio; after silence the first
   26–156 ms of a new sound may be lost (start delay is longer on Bluetooth). Short notification sounds
   from a scaled app could be clipped. Inherent to the tap API; Fader/FineTune share it.
2. Process-set churn (a helper appears or exits: afplay from a scaled parent, Chrome tab audio) rebuilds
   the tap: a gap of ~100 ms. Correct but audible in principle.
3. `responsibility_get_pid_responsible_for_pid` is private API (dlsym). Fallback is the parent walk,
   which covers Chrome/Electron but not Safari's XPC helpers.
4. The aggregate readiness wait uses `usleep` (≤ 1 s, bounded) on the engine queue.
5. The RT block captures raw pointers that `AppTap.deinit` frees after teardown; this relies on
   `AudioDeviceDestroyIOProcID` blocking until the callback has exited (documented HAL behaviour).
6. Multi-output aggregate devices as the default output are untested (Apple forum reports −20·log10(N)
   attenuation on such devices for taps).
7. Sample-rate change on the same device and wake-from-sleep have listeners but were not exercised.
8. The macOS 26.5-beta "silent tap after hours" report was not observed; no watchdog by decision.
   "Reset audio" is the manual escape hatch.
9. Settings are keyed by bundle id (or `name:<process>`); an app that changes bundle id loses its level.
10. `install.sh` quits the app via Apple event, then `pkill`; if a future macOS blocks the event the
    fallback still works.
