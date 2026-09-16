import Foundation
import CoreAudio
import MikserCore

/// Regression locks for the red-team findings of 2026-09-14.
func reviewFixSuite(_ h: Harness) {
    h.suite("H2: levels are quantized so the display and isFull agree") { h in
        h.check("0.995 rounds to full", AppLevel(level: 0.995, muted: false).isFull)
        h.check("0.994 is 99%", AppLevel(level: 0.994, muted: false).level == 0.99)
        h.check("0.005 is 1%", AppLevel(level: 0.005, muted: false).level == 0.01)
        h.check("nan becomes full", AppLevel(level: .nan, muted: false).isFull)
        var v = AppLevel(level: 0.5, muted: false); v.level = 0.996
        h.check("assignment quantizes too", v.isFull)
        let decoded = try? JSONDecoder().decode([String: AppLevel].self, from: Data(#"{"x":{"level":0.997,"muted":false}}"#.utf8))
        h.check("a stored 0.997 decodes as full", decoded?["x"]?.isFull == true)
        let suite = MikserID.bundle + ".h2test"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(Data(#"{"bundle:old":{"level":0.998,"muted":false},"bundle:keep":{"level":0.4,"muted":false}}"#.utf8), forKey: Settings.levelsKey)
        let s = Settings(defaults: defaults)
        h.check("legacy near-full entries are dropped on load", s.levels["bundle:old"] == nil && s.levels["bundle:keep"]?.level == 0.4)
        defaults.removePersistentDomain(forName: suite)
        MainActor.assumeIsolated {
            let d2 = UserDefaults(suiteName: suite + ".model")!
            d2.removePersistentDomain(forName: suite + ".model")
            let model = MixerModel(settings: Settings(defaults: d2))
            let app = AudioApp(id: .bundle("com.example.a"), displayName: "A", bundleID: "com.example.a",
                               processes: [AudioProcess(objectID: 1, pid: 1, bundleID: nil, isRunningOutput: false)], icon: nil)
            model._setAppsForTesting([app], rebuild: true)
            model.setLevel(0.995, for: app.id)
            h.check("setLevel(0.995) stores nothing and shows 100%", model.settings.levels.isEmpty && model.rows.first?.level == 1)
            d2.removePersistentDomain(forName: suite + ".model")
        }
    }

    h.suite("L6: channel expansion never sends right into surrounds") { h in
        let ramp = GainMath.rampCoefficient(sampleRate: 48_000)
        let stereo = BufferListBox([(2, 4)]); stereo.fill(0, [0.1, 0.9, 0.1, 0.9])
        let quad = BufferListBox([(4, 8)]); quad.fill(0) { _ in 7 }
        _ = GainMath.mixLists(input: stereo.list, output: quad.list, gain: 1, target: 1, ramp: ramp)
        h.check("stereo into 4 channels: L, R, silence, silence", quad.samples(0) == [0.1, 0.9, 0, 0, 0.1, 0.9, 0, 0], "\(quad.samples(0))")
        let mono = BufferListBox([(1, 2)]); mono.fill(0, [0.3, 0.3])
        let quad2 = BufferListBox([(4, 8)])
        _ = GainMath.mixLists(input: mono.list, output: quad2.list, gain: 1, target: 1, ramp: ramp)
        h.check("mono into 4 channels duplicates", quad2.samples(0).allSatisfy { abs($0 - 0.3) < 1e-6 })
        let planar = BufferListBox([(1, 2), (1, 2)]); planar.fill(0, [1, 2]); planar.fill(1, [10, 20])
        let inter4 = BufferListBox([(4, 8)]); inter4.fill(0) { _ in 7 }
        _ = GainMath.mixLists(input: planar.list, output: inter4.list, gain: 1, target: 1, ramp: ramp)
        h.check("planar stereo into 4-channel interleaved: extra channels silent", inter4.samples(0) == [1, 10, 0, 0, 2, 20, 0, 0], "\(inter4.samples(0))")
        let inter2 = BufferListBox([(2, 4)]); inter2.fill(0, [1, 10, 2, 20])
        let planar4 = BufferListBox([(1, 2), (1, 2), (1, 2), (1, 2)]); for i in 0..<4 { planar4.fill(i) { _ in 7 } }
        _ = GainMath.mixLists(input: inter2.list, output: planar4.list, gain: 1, target: 1, ramp: ramp)
        h.check("interleaved stereo into 4 planar: extra buffers silent", planar4.samples(2) == [0, 0] && planar4.samples(3) == [0, 0] && planar4.samples(1) == [10, 20])
    }

    h.suite("L4 + M4: error glyph clears at 100; name prefixes only hit user-facing apps") { h in
        MainActor.assumeIsolated {
            let suite = MikserID.bundle + ".l4test"
            let defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            let model = MixerModel(settings: Settings(defaults: defaults))
            func app(_ id: String, _ name: String, userFacing: Bool) -> AudioApp {
                AudioApp(id: .bundle(id), displayName: name, bundleID: id,
                         processes: [AudioProcess(objectID: 1, pid: 1, bundleID: id, isRunningOutput: false)],
                         icon: nil, isUserFacing: userFacing)
            }
            let safari = app("com.apple.Safari", "Safari", userFacing: true)
            let assistant = app("com.apple.assistantd", "assistantd", userFacing: false)
            model._setAppsForTesting([safari, assistant], rebuild: true)
            model._setErrorForTesting("path failed", for: safari.id)
            h.check("error shows on the row", model.rows.first { $0.id == safari.id }?.error == "path failed")
            model.setLevel(1.0, for: safari.id)
            h.check("returning to 100 clears the error", model.rows.first { $0.id == safari.id }?.error == nil)
            h.check("prefix 'a' does not pick assistantd", model.app(matching: "a") == nil)
            h.check("prefix 's' picks Safari", model.app(matching: "s")?.id == safari.id)
            h.check("exact bundle id still reaches a daemon", model.app(matching: "com.apple.assistantd")?.id == assistant.id)
            h.check("empty text matches nothing", model.app(matching: "  ") == nil)
            defaults.removePersistentDomain(forName: suite)
        }
    }

    h.suite("Codex MED-5: planar/mono layouts use the same channel rule") { h in
        let ramp = GainMath.rampCoefficient(sampleRate: 48_000)
        let planar = BufferListBox([(1, 2), (1, 2)]); planar.fill(0, [1, 2]); planar.fill(1, [10, 20])
        let mono = BufferListBox([(1, 2)])
        _ = GainMath.mixLists(input: planar.list, output: mono.list, gain: 1, target: 1, ramp: ramp)
        h.check("planar stereo into mono averages", mono.samples(0) == [5.5, 11], "\(mono.samples(0))")
        let monoIn = BufferListBox([(1, 2)]); monoIn.fill(0, [0.3, 0.4])
        let planarOut = BufferListBox([(1, 2), (1, 2)])
        _ = GainMath.mixLists(input: monoIn.list, output: planarOut.list, gain: 1, target: 1, ramp: ramp)
        h.check("mono into planar stereo duplicates", planarOut.samples(0) == [0.3, 0.4] && planarOut.samples(1) == [0.3, 0.4])
        let planar4 = BufferListBox([(1, 2), (1, 2), (1, 2), (1, 2)]); for i in 0..<4 { planar4.fill(i) { _ in Float(i + 1) } }
        let stereoOut = BufferListBox([(2, 4)])
        _ = GainMath.mixLists(input: planar4.list, output: stereoOut.list, gain: 1, target: 1, ramp: ramp)
        h.check("planar 4 into interleaved stereo keeps the first two channels", stereoOut.samples(0) == [1, 2, 1, 2], "\(stereoOut.samples(0))")
        let quadIn = BufferListBox([(4, 8)]); quadIn.fill(0, [1, 2, 3, 4, 1, 2, 3, 4])
        let monoOut = BufferListBox([(1, 2)])
        _ = GainMath.mixLists(input: quadIn.list, output: monoOut.list, gain: 1, target: 1, ramp: ramp)
        h.check("quad into mono averages all four", monoOut.samples(0) == [2.5, 2.5])
        let peaks = GainMath.mixLists(input: planar.list, output: mono.list, gain: 0.5, target: 0.5, ramp: ramp)
        h.check("peaks reflect input and output", peaks.peakIn == 20 && abs(peaks.peakOut - 5.5) < 1e-5, "\(peaks)")
        GainMath.warmUp()
        h.check("warmUp runs", true)
    }

    h.suite("Codex MED-1/2: liveness suspension clears on quit and retries when the app plays") { h in
        let queue = DispatchQueue(label: "test.engine")
        let monitor = OutputDeviceMonitor(queue: queue) // never started: no default output → builds fail fast
        let engine = TapEngine(queue: queue, output: monitor)
        let key = AppGroupKey.bundle("com.example.live")
        func app(playing: Bool) -> AudioApp {
            AudioApp(id: key, displayName: "Live", bundleID: "com.example.live",
                     processes: [AudioProcess(objectID: 7, pid: 7, bundleID: nil, isRunningOutput: playing)], icon: nil)
        }
        engine.apply(AppLevel(level: 0.5, muted: false), to: app(playing: false))
        var s = engine.snapshot()
        h.check("build without an output device fails safe", s.errors[key] == "no default output device", "\(s.errors)")
        engine._suspendForTesting(key)
        h.check("suspended", engine.snapshot().suspendedKeys == [key])
        engine.processesChanged([app(playing: false)])
        h.check("a silent suspended app stays suspended", engine.snapshot().suspendedKeys == [key])
        engine.processesChanged([app(playing: true)])
        s = engine.snapshot()
        h.check("a playing suspended app is retried (suspension lifted, attempt made)", s.suspendedKeys.isEmpty && s.failSafes >= 2, "suspended=\(s.suspendedKeys) failSafes=\(s.failSafes)")
        engine._suspendForTesting(key); engine.processesChanged([app(playing: true)])
        engine._suspendForTesting(key); engine.processesChanged([app(playing: true)])
        h.check("retry budget exhausted: stays suspended", engine.snapshot().suspendedKeys == [key])
        engine.processesChanged([])
        s = engine.snapshot()
        h.check("app quit clears suspension and wanted", s.suspendedKeys.isEmpty && s.wantedKeys.isEmpty, "\(s.suspendedKeys) \(s.wantedKeys)")
        engine.apply(AppLevel(level: 0.5, muted: false), to: app(playing: true), userInitiated: false)
        h.check("relaunched app gets its saved level applied again", engine.snapshot().wantedKeys == [key])
        engine.stopAll()
    }

    h.suite("M3: liveness decision") { h in
        h.check("playing app, no callbacks → dead", TapEngine.pathLooksDead(expectedSound: true, callbacks: 0))
        h.check("playing app with callbacks → fine", !TapEngine.pathLooksDead(expectedSound: true, callbacks: 3))
        h.check("silent app, no callbacks → fine (auto-paused IO)", !TapEngine.pathLooksDead(expectedSound: false, callbacks: 0))
    }

    h.suite("AppTap target stamp") { h in
        let tap = AppTap(key: .bundle("t"), requestedObjectIDs: [1], processObjectIDs: [1], outputDeviceID: 0, outputUID: "u", target: 0.5)
        h.check("no target change yet", !tap.hadSignal(withinMs: 1000))
        tap.target = 0.25
        h.check("target applied", tap.target == 0.25)
    }
}
