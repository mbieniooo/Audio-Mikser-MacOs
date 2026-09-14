import Foundation
import MikserCore

func groupingSuite(_ h: Harness) {
    h.suite("AppIdentity.stripHelperSuffix") { h in
        let cases: [(String, String)] = [
            ("com.google.Chrome.helper", "com.google.Chrome"),
            ("com.google.Chrome.helper.renderer", "com.google.Chrome"),
            ("com.microsoft.VSCode.helper.GPU", "com.microsoft.VSCode"),
            ("com.spotify.client", "com.spotify.client"),
            ("com.apple.WebKit.GPU", "com.apple.WebKit"),
            ("helper", "helper"),
            ("com.example.HelperPlugin", "com.example"),
            ("a.b", "a.b"),
        ]
        for (input, want) in cases {
            let got = AppIdentity.stripHelperSuffix(input)
            h.check("strip \(input)", got == want, "got \(got)")
        }
    }

    h.suite("Grouping") { h in
        func fakeResolve(_ pid: pid_t, _ hint: String?) -> ResolvedIdentity {
            switch pid {
            case 100, 101, 102:
                return ResolvedIdentity(key: .bundle("com.google.Chrome"), displayName: "Google Chrome",
                                        bundleID: "com.google.Chrome", icon: nil, appPID: 100)
            case 200:
                return ResolvedIdentity(key: .bundle("com.spotify.client"), displayName: "Spotify",
                                        bundleID: "com.spotify.client", icon: nil, appPID: 200, isUserFacingApp: true)
            case 300:
                return ResolvedIdentity(key: .bundle("com.apple.Music"), displayName: "apple music",
                                        bundleID: "com.apple.Music", icon: nil, appPID: 300)
            case 400:
                return ResolvedIdentity(key: .bundle("com.mieszko.mikser"), displayName: "Mikser",
                                        bundleID: "com.mieszko.mikser", icon: nil, appPID: 400)
            default:
                return ResolvedIdentity(key: .name("afplay"), displayName: "afplay", bundleID: nil, icon: nil, appPID: nil)
            }
        }
        let processes = [
            AudioProcess(objectID: 1, pid: 102, bundleID: "com.google.Chrome.helper.renderer", isRunningOutput: false),
            AudioProcess(objectID: 2, pid: 100, bundleID: "com.google.Chrome", isRunningOutput: false),
            AudioProcess(objectID: 3, pid: 101, bundleID: "com.google.Chrome.helper", isRunningOutput: true),
            AudioProcess(objectID: 4, pid: 200, bundleID: "com.spotify.client", isRunningOutput: false),
            AudioProcess(objectID: 5, pid: 300, bundleID: "com.apple.Music", isRunningOutput: false),
            AudioProcess(objectID: 6, pid: 400, bundleID: "com.mieszko.mikser", isRunningOutput: true),
            AudioProcess(objectID: 7, pid: 999, bundleID: nil, isRunningOutput: true),
            AudioProcess(objectID: 8, pid: 555, bundleID: nil, isRunningOutput: true),
        ]
        let rows = Grouping.group(processes, excludingPIDs: [555], resolve: fakeResolve)
        h.check("four rows", rows.count == 4, "got \(rows.map { $0.displayName })")
        let chrome = rows.first { $0.id == .bundle("com.google.Chrome") }
        h.check("chrome folds 3 processes", chrome?.processes.count == 3)
        h.check("chrome processes sorted by pid", chrome?.pids == [100, 101, 102])
        h.check("chrome is playing (one helper runs output)", chrome?.isPlaying == true)
        h.check("mikser itself is dropped", !rows.contains { $0.id == Grouping.ownKey })
        h.check("excluded pid is dropped", !rows.contains { $0.pids.contains(555) })
        h.check("playing rows first", rows.prefix(2).allSatisfy { $0.isPlaying } && !rows[2].isPlaying)
        h.check("playing rows sorted by name", rows[0].displayName == "afplay" && rows[1].displayName == "Google Chrome")
        h.check("silent rows sorted case-insensitively", rows[2].displayName == "apple music" && rows[3].displayName == "Spotify")
        let shuffled = Grouping.group(processes.reversed(), excludingPIDs: [555], resolve: fakeResolve)
        h.check("deterministic for shuffled input", Grouping.sameRows(rows, shuffled))
        var flipped = processes
        flipped[3] = AudioProcess(objectID: 4, pid: 200, bundleID: "com.spotify.client", isRunningOutput: true)
        let rows2 = Grouping.group(flipped, excludingPIDs: [555], resolve: fakeResolve)
        h.check("sameRows detects a playing change", !Grouping.sameRows(rows, rows2))
        let spotify = rows.first { $0.id == .bundle("com.spotify.client") }
        h.check("user-facing flag passes through (true)", spotify?.isUserFacing == true)
        h.check("user-facing flag passes through (false)", chrome?.isUserFacing == false)
    }

    h.suite("AppIdentity live (this machine)") { h in
        h.check("responsibility API resolves", AppIdentity.hasResponsibilityAPI)
        let me = ProcessInfo.processInfo.processIdentifier
        h.check("parentPID of self is set", (AppIdentity.parentPID(of: me) ?? 0) > 0)
        h.check("processName of pid 1 is launchd", AppIdentity.processName(of: 1) == "launchd")
        let r = AppIdentity.resolve(pid: me, bundleIDHint: nil)
        h.check("self resolves to something", !r.displayName.isEmpty, r.displayName)
    }
}
