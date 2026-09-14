import Foundation
import MikserCore

func settingsSuite(_ h: Harness) {
    h.suite("Settings") { h in
        let suite = "com.mieszko.mikser.selftest"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let s = Settings(defaults: defaults)
        h.check("unknown app is full", s.level(for: .bundle("x")) == .full)
        s.set(AppLevel(level: 0.4, muted: false), for: .bundle("com.spotify.client"))
        s.set(AppLevel(level: 1, muted: true), for: .bundle("com.apple.Safari"))
        s.set(AppLevel(level: 1, muted: false), for: .bundle("com.example.full"))
        let reloaded = Settings(defaults: defaults)
        h.check("level round-trips", reloaded.level(for: .bundle("com.spotify.client")) == AppLevel(level: 0.4, muted: false))
        h.check("muted at 100 round-trips", reloaded.level(for: .bundle("com.apple.Safari")) == AppLevel(level: 1, muted: true))
        h.check("full entries are not stored", reloaded.levels["bundle:com.example.full"] == nil)
        h.check("stored count is 2", reloaded.levels.count == 2)
        reloaded.set(.full, for: .bundle("com.spotify.client"))
        h.check("setting full removes the entry", Settings(defaults: defaults).levels.count == 1)
        reloaded.removeAll()
        h.check("removeAll clears", Settings(defaults: defaults).levels.isEmpty)
        defaults.removePersistentDomain(forName: suite)
    }
}
