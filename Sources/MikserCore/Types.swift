import Foundation
import CoreAudio
import AppKit

/// Identity of one row in the mixer: an app (by bundle id) or, as a fallback, a process name.
public struct AppGroupKey: Hashable, Codable, Sendable, CustomStringConvertible {
    public let raw: String
    public init(raw: String) { self.raw = raw }
    public static func bundle(_ id: String) -> AppGroupKey { AppGroupKey(raw: "bundle:" + id) }
    public static func name(_ n: String) -> AppGroupKey { AppGroupKey(raw: "name:" + n) }
    public var description: String { raw }
}

/// One Core Audio process object (a process that has an audio client).
public struct AudioProcess: Equatable, Sendable {
    public let objectID: AudioObjectID
    public let pid: pid_t
    public let bundleID: String?
    public let isRunningOutput: Bool
    public init(objectID: AudioObjectID, pid: pid_t, bundleID: String?, isRunningOutput: Bool) {
        self.objectID = objectID; self.pid = pid; self.bundleID = bundleID; self.isRunningOutput = isRunningOutput
    }
}

/// One row: an app and every audio process that belongs to it (helpers folded in).
public struct AudioApp: Identifiable, Equatable {
    public let id: AppGroupKey
    public let displayName: String
    public let bundleID: String?
    public let processes: [AudioProcess]
    public let icon: NSImage?
    /// True for apps a person can see (Dock or menu bar apps); false for daemons and agents.
    public let isUserFacing: Bool
    public init(id: AppGroupKey, displayName: String, bundleID: String?, processes: [AudioProcess], icon: NSImage?, isUserFacing: Bool = true) {
        self.id = id; self.displayName = displayName; self.bundleID = bundleID; self.processes = processes; self.icon = icon
        self.isUserFacing = isUserFacing
    }
    public var isPlaying: Bool { processes.contains { $0.isRunningOutput } }
    public var processObjectIDs: [AudioObjectID] { processes.map { $0.objectID } }
    public var pids: [pid_t] { processes.map { $0.pid } }
}

/// The user's setting for one app. level is 0...1; 1 and not muted means "untouched, no tap".
public struct AppLevel: Codable, Equatable, Sendable {
    public var level: Double
    public var muted: Bool
    public init(level: Double, muted: Bool) { self.level = min(max(level, 0), 1); self.muted = muted }
    public static let full = AppLevel(level: 1, muted: false)
    public var isFull: Bool { level >= 1 && !muted }
    /// The gain actually applied: 0 when muted.
    public var effectiveGain: Float { muted ? 0 : Float(level) }
}
