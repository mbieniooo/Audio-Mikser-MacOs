import Foundation
import AppKit
import Darwin

/// What one audio process resolves to: the app that owns it (helpers fold into their parent).
public struct ResolvedIdentity {
    public let key: AppGroupKey
    public let displayName: String
    public let bundleID: String?
    public let icon: NSImage?
    public let appPID: pid_t?
    /// Dock apps and menu bar apps are user-facing; daemons, agents and bare processes are not.
    public let isUserFacingApp: Bool
    public init(key: AppGroupKey, displayName: String, bundleID: String?, icon: NSImage?, appPID: pid_t?, isUserFacingApp: Bool = false) {
        self.key = key; self.displayName = displayName; self.bundleID = bundleID; self.icon = icon; self.appPID = appPID
        self.isUserFacingApp = isUserFacingApp
    }
}

public enum AppIdentity {
    // MARK: step a — the OS's own "responsible process" (maps Safari's WebKit XPC helpers to Safari)

    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t

    private static let responsibleFn: ResponsibleFn? = {
        var sym: UnsafeMutableRawPointer? = nil
        if let handle = dlopen("/usr/lib/system/libquarantine.dylib", RTLD_NOW) {
            sym = dlsym(handle, "responsibility_get_pid_responsible_for_pid")
        }
        if sym == nil {
            // RTLD_DEFAULT is (void*)-2 on Darwin
            sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
        }
        guard let found = sym else { return nil }
        return unsafeBitCast(found, to: ResponsibleFn.self)
    }()

    public static var hasResponsibilityAPI: Bool { responsibleFn != nil }

    public static func responsiblePID(for pid: pid_t) -> pid_t? {
        guard let fn = responsibleFn else { return nil }
        let r = fn(pid)
        return r > 0 ? r : nil
    }

    // MARK: step b — parent walk via sysctl

    private static func kinfo(of pid: pid_t) -> kinfo_proc? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let rc = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
        guard rc == 0, size > 0 else { return nil }
        return info
    }

    public static func parentPID(of pid: pid_t) -> pid_t? {
        guard let info = kinfo(of: pid) else { return nil }
        return info.kp_eproc.e_ppid
    }

    /// Short process name (kernel p_comm, at most 16 characters).
    public static func processName(of pid: pid_t) -> String? {
        guard var info = kinfo(of: pid) else { return nil }
        let name = withUnsafePointer(to: &info.kp_proc.p_comm) { ptr -> String in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) }
        }
        return name.isEmpty ? nil : name
    }

    // MARK: step c — bundle id heuristics (pure)

    static let helperComponents: Set<String> = [
        "helper", "renderer", "gpu", "plugin", "plugins", "utility", "networking", "crashpad", "xpc", "service",
    ]

    public static func stripHelperSuffix(_ bundleID: String) -> String {
        var parts = bundleID.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        while parts.count > 2, let last = parts.last?.lowercased(),
              helperComponents.contains(last) || last.hasPrefix("helper") {
            parts.removeLast()
        }
        return parts.joined(separator: ".")
    }

    // MARK: resolution

    public static func resolve(pid: pid_t, bundleIDHint: String?) -> ResolvedIdentity {
        // a) responsible process
        if let rp = responsiblePID(for: pid), let app = runningApp(rp) {
            return identity(from: app)
        }
        // b) the process itself, then its ancestors
        var current: pid_t? = pid
        var hops = 0
        while let p = current, p > 1, hops < 6 {
            if let app = runningApp(p) { return identity(from: app) }
            current = parentPID(of: p)
            hops += 1
        }
        // c) bundle id hint with helper suffixes stripped
        if let hint = bundleIDHint, !hint.isEmpty {
            let stripped = stripHelperSuffix(hint)
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: stripped).first {
                return identity(from: app)
            }
            let name = stripped.split(separator: ".").last.map(String.init) ?? stripped
            return ResolvedIdentity(key: .bundle(stripped), displayName: name, bundleID: stripped, icon: nil, appPID: nil)
        }
        // d) process name
        let name = processName(of: pid) ?? "pid \(pid)"
        return ResolvedIdentity(key: .name(name), displayName: name, bundleID: nil, icon: nil, appPID: nil)
    }

    private static func runningApp(_ pid: pid_t) -> NSRunningApplication? {
        guard let app = NSRunningApplication(processIdentifier: pid), app.bundleIdentifier != nil else { return nil }
        return app
    }

    private static func identity(from app: NSRunningApplication) -> ResolvedIdentity {
        let id = app.bundleIdentifier ?? "unknown"
        return ResolvedIdentity(key: .bundle(id), displayName: app.localizedName ?? id, bundleID: id,
                                icon: app.icon, appPID: app.processIdentifier,
                                isUserFacingApp: Self.isUserFacing(app))
    }

    /// Dock apps always; menu bar apps unless they are Apple system agents (Siri, Control Center, loginwindow…).
    static func isUserFacing(_ app: NSRunningApplication) -> Bool {
        switch app.activationPolicy {
        case .regular: return true
        case .accessory: return !(app.bundleURL?.path.hasPrefix("/System/") ?? true)
        default: return false
        }
    }
}
