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
- **A timer exists, but only while the popover is open** (0.5 s): it refreshes the playing marks.
  For scaled apps the mark comes from the tap's own signal (audible now); for the others from the
  HAL flag. Verified: with the popover closed the process uses 0.0 % CPU.
  Correction (2026-09-15): the earlier claim that a tapped process stops reporting "running output"
  was wrong. A listener probe showed the real cause: macOS 26.6 never delivers change events for
  `kAudioProcessPropertyIsRunningOutput`, only for `kAudioProcessPropertyIsRunning`, so the registry
  only refreshed when a process appeared or vanished. The registry now listens to `IsRunning` and
  re-reads the output flag on each event.
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

## Red-team round 1 (2026-09-14, fresh Fable agent, cold read of HEAD 0ea0046)

Report: `redteam-report.md` in the session scratchpad; findings reproduced by the builder before acting.

| Finding | Status |
|---|---|
| **H1** release build broken by a test-only `@testable import` | Fixed: hooks made public, no `@testable`; `scripts/build.sh` now runs the release self-test before signing. |
| **H2** 0.995–0.999 shows "100 %" yet keeps a tap and is persisted | Fixed: levels quantized to 0.01 in `AppLevel` (init, assignment, decoding) and stored values normalized on load; 7 regression checks, mutation-tested. |
| **M1** main thread `queue.sync`s into the engine queue during a tap build (slider freeze) | Fixed: `activeKeys()` and `playingKeys()` read a lock-protected mirror; the main thread never waits on the engine queue. |
| **M2** IO auto-pauses when the app is silent; first 26–156 ms of a new sound lost | Inherent to the tap API (Fader/FineTune share it); documented in README. |
| **M3** a tap whose IO never starts leaves the app silent | Fixed: one-shot liveness check 2.5 s after creating a tap for an app that was audibly playing; a dead path is dropped (app back to full volume, warning glyph) and suspended until the user moves the slider or resets, so it cannot oscillate. Decision function tested. |
| **M4** local processes can drive the control channel; name prefixes hit daemons | Prefix matching limited to user-facing apps; empty `output set` rejected. The channel stays local and unauthenticated by design (same-user processes can already change the output device or kill the app); the extra commands beyond the brief (`output set`, `login`, `popover`, `snapshot`, `quit`) are a disclosed deviation kept for verification. |
| **M5** memory bar unmet | Documented honestly: RSS 50 MB idle / 76–89 MB after use; footprint 23 MB idle / 34 MB after use (41 MB with verification snapshots); AlDente 40 MB RSS / 42 MB footprint. |
| **M6** `stop()` mutates queue-owned state from the main thread | Fixed: registry and monitor stop on their own queue (queue-specific key avoids deadlock). |
| **M7** helper churn rebuilds the path | Documented; watch `rebuilds` with Chrome/Brave in the ear test. |
| **M8** scaling re-routes an app to the default output | Documented in README. `dump` lists each app's devices, but `kAudioProcessPropertyDevices` came back empty for a playing process on this Mac, so the case is not enforced. |
| **L1** IO block hopped through a dispatch queue | Changed to run on the HAL's IO thread (nil queue). Verified live after install: callbacks flow, start delay 22 ms (was 26–156 ms through the queue), ratio 0.2000, no fail safe. |
| **L4** warning glyph stuck after returning to 100 | Fixed, mutation-tested. |
| **L5** popover: timer could survive a failed show; icon click while open reopened it | Fixed: unfreeze when show fails; 300 ms reopen guard after a close. |
| **L6** stereo into N channels repeated right into channels 3…N | Fixed: multi-channel input feeds its own channels, the rest stay silent; mono still duplicates. Mutation-tested. |
| **L2, L3, L7–L10** | Accepted or documented (README notes `--taps` is blind to private objects; DoD 10 timing comes from the control channel, not the unified log). |
| DoD 7 "no target-change timestamp" | Added: `sinceTargetChangeMs` per tap in `stats`. Live: 33 ms after a change from 0.2 to 0.6 the gain read 0.462 (two thirds of the way, as a 30 ms one-pole predicts), 0.599 at 177 ms, 0.600 at 525 ms. |
| Scope verdict `no (narrowly)` | Accepted: the disclosed deviations are the popover-only timer, hidden daemons, the memory bar, and the verification commands. |

Self-test after the round: 96 checks in debug and release. Mutation checks: reverting each of H2, L6, L4, M4 makes its lock fail (7, 1, 1, 1 failures) and the restored tree passes.

## Cross-vendor critic (Codex, 2026-09-15, read-only review of HEAD after round 1)

Verdict FAIL with 3 HIGH and 5 MEDIUM; each reproduced or refuted by the builder before acting.

| Finding | Reproduction | Status |
|---|---|---|
| **HIGH** every IO callback passes through Swift retain/release | Confirmed in the release disassembly: the reabstraction thunk around the closure calls `_swift_retain` and `_swift_release` on each call (no lock or allocation, but runtime work on the IO thread). | Fixed: the IO proc is now a C function (`AudioDeviceCreateIOProcID` with a client-data pointer), no closure, no thunk; `GainMath.warmUp()` runs the render code once before IO starts so no lazy metadata work meets the first callback. |
| **HIGH** rebuilds destroy the old path before the new one exists, so a muted app leaks at full volume for the gap | True by construction (the registry's HAL flag cannot observe it, verified with a 2 ms probe). | Fixed: crossfade. The new path starts silent and fades in over the 30 ms ramp; the old one starts fading out once the new one delivers its first callback and is destroyed 200 ms later; the app is never untapped in between. Measured on a reset at 20 %: the sum of the two gains ran 0.20 → 0.26 → 0.24 → 0.21 → 0.20 over about 100 ms (a +2 dB bump, no dip, no burst); for a muted app both paths are at zero throughout. |
| **HIGH** shared audio state used plain loads and stores | Formally a data race; tear-free on Apple silicon in practice. | Fixed: `Synchronization.Atomic` fields (relaxed ordering) in a non-copyable shared struct owned by the tap. |
| **MED** liveness check can suspend a healthy paused app forever | Reasoning accepted. | Fixed: a suspended app that the HAL reports playing again is rebuilt, up to 2 attempts, then waits for the user. Tested. |
| **MED** suspension survives quit and relaunch | Reasoning accepted. | Fixed: an app that quits drops every trace (tap, wanted, suspension, pending release). Tested. |
| **MED** non-Float32 formats silently bypassed gain and mute | Reasoning accepted. | Fixed: activation refuses a non-Float32 output stream, so the fail safe restores the app with a warning. |
| **MED** startup mutated queue-owned state off the queue | Reasoning accepted. | Fixed: registry and monitor start on their own queue. |
| **MED** planar stereo → mono and mono → planar stereo fell through to index matching | Reproduced in the self-test (left channel only, right buffer silent). | Fixed: one general channel mapper for every layout; 6 new checks, mutation-tested. |
| Note: input buffer 0 assumed to be the tap | Not reproduced: on two duplex devices (Bluetooth headset, USB device with input) the tap was the only input stream. | Documented. |

Self-test after the round: 109 checks in debug and release. Mutation checks: reverting the mono average, the quit cleanup, or the play-retry makes its lock fail.
