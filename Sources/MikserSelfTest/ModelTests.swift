import Foundation
@testable import MikserCore

func modelSuite(_ h: Harness) {
    h.suite("AppTap initial state") { h in
        let muted = AppTap(key: .bundle("x"), requestedObjectIDs: [1], processObjectIDs: [1],
                           outputDeviceID: 0, outputUID: "u", target: 0)
        h.check("a muted tap starts silent (current == target)", muted.currentGain == 0)
        let some = AppTap(key: .bundle("y"), requestedObjectIDs: [1], processObjectIDs: [1],
                          outputDeviceID: 0, outputUID: "u", target: 0.3)
        h.check("current starts at the target gain", some.currentGain == 0.3)
        some.target = 2
        h.check("target clamps to 1", some.target == 1)
    }

    h.suite("MixerModel rows and frozen order") { h in
        MainActor.assumeIsolated {
            let suite = "com.mieszko.mikser.modeltest"
            let defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            let model = MixerModel(settings: Settings(defaults: defaults))
            func app(_ id: String, _ name: String, playing: Bool, userFacing: Bool = true) -> AudioApp {
                AudioApp(id: .bundle(id), displayName: name, bundleID: id,
                         processes: [AudioProcess(objectID: 1, pid: 1, bundleID: id, isRunningOutput: playing)],
                         icon: nil, isUserFacing: userFacing)
            }
            model._setAppsForTesting([app("a", "Alpha", playing: false), app("b", "Beta", playing: true),
                                      app("d", "daemon", playing: true, userFacing: false)], rebuild: true)
            h.check("playing row first", model.rows.map { $0.name } == ["Beta", "Alpha"], "\(model.rows.map { $0.name })")
            h.check("daemons are hidden", !model.rows.contains { $0.name == "daemon" })

            // The playing state flips without a rebuild, then the popover opens.
            model._setAppsForTesting([app("a", "Alpha", playing: true), app("b", "Beta", playing: false)], rebuild: false)
            model.freezeOrder()
            h.check("freezeOrder recomputes the order before freezing it",
                    model.rows.map { $0.name } == ["Alpha", "Beta"], "\(model.rows.map { $0.name })")

            // While open, a change must not reorder rows under the cursor.
            model._setAppsForTesting([app("a", "Alpha", playing: false), app("b", "Beta", playing: true)], rebuild: true)
            h.check("order stays frozen while open", model.rows.map { $0.name } == ["Alpha", "Beta"])
            h.check("but the playing mark updates", model.rows.first { $0.name == "Beta" }?.isPlaying == true)
            model.unfreezeOrder()
            h.check("closing the popover reorders", model.rows.map { $0.name } == ["Beta", "Alpha"])

            // A saved level below 100 keeps a daemon visible.
            model.settings.set(AppLevel(level: 0.5, muted: false), for: .bundle("d"))
            model._setAppsForTesting([app("a", "Alpha", playing: false), app("d", "daemon", playing: false, userFacing: false)], rebuild: true)
            h.check("a scaled daemon is shown", model.rows.contains { $0.name == "daemon" })
            defaults.removePersistentDomain(forName: suite)
        }
    }
}
