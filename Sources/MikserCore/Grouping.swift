import Foundation

/// Pure grouping logic: audio processes → one row per app. No Core Audio calls here.
public enum Grouping {
    public static let ownKey = AppGroupKey.bundle(MikserID.bundle)

    public static func group(_ processes: [AudioProcess],
                             excludingPIDs: Set<pid_t>,
                             resolve: (pid_t, String?) -> ResolvedIdentity) -> [AudioApp] {
        var members: [AppGroupKey: (identity: ResolvedIdentity, processes: [AudioProcess])] = [:]
        for process in processes where !excludingPIDs.contains(process.pid) {
            let identity = resolve(process.pid, process.bundleID)
            if identity.key == ownKey { continue }
            if members[identity.key] == nil {
                members[identity.key] = (identity, [])
            }
            members[identity.key]?.processes.append(process)
        }
        var apps = members.map { key, entry -> AudioApp in
            AudioApp(id: key,
                     displayName: entry.identity.displayName,
                     bundleID: entry.identity.bundleID,
                     processes: entry.processes.sorted { $0.pid < $1.pid },
                     icon: entry.identity.icon,
                     isUserFacing: entry.identity.isUserFacingApp)
        }
        apps.sort(by: rowOrder)
        return apps
    }

    /// Playing rows first, then name (case-insensitive), then key. Deterministic.
    public static func rowOrder(_ a: AudioApp, _ b: AudioApp) -> Bool {
        if a.isPlaying != b.isPlaying { return a.isPlaying }
        let byName = a.displayName.localizedCaseInsensitiveCompare(b.displayName)
        if byName != .orderedSame { return byName == .orderedAscending }
        return a.id.raw < b.id.raw
    }

    /// Equality that ignores icons (NSImage compares by identity).
    public static func sameRows(_ a: [AudioApp], _ b: [AudioApp]) -> Bool {
        guard a.count == b.count else { return false }
        for (x, y) in zip(a, b) {
            if x.id != y.id || x.displayName != y.displayName || x.bundleID != y.bundleID
                || x.processes != y.processes || x.isPlaying != y.isPlaying || x.isUserFacing != y.isUserFacing {
                return false
            }
        }
        return true
    }
}
