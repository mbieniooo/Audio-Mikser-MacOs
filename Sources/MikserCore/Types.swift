import Foundation
import CoreAudio
import AppKit

/// The app's bundle identifier: the one place to change when you build your own Mikser.
/// scripts/build.sh writes it into Info.plist and the code signature; queue labels, notification
/// names and aggregate-device UIDs all derive from it. macOS keys the System Audio Recording
/// permission and the saved levels to this value, so changing it later means answering the
/// permission prompt again and setting levels again.
public enum MikserID {
    public static let bundle = "com.mikser.app"
}

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
    /// Devices the process currently does IO with (kAudioProcessPropertyDevices).
    public let devices: [AudioObjectID]
    public init(objectID: AudioObjectID, pid: pid_t, bundleID: String?, isRunningOutput: Bool, devices: [AudioObjectID] = []) {
        self.objectID = objectID; self.pid = pid; self.bundleID = bundleID; self.isRunningOutput = isRunningOutput
        self.devices = devices
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

/// The user's setting for one app. level is 0...1 in steps of 0.01 (what the slider shows); 1 and not
/// muted means "untouched, no tap". Quantizing keeps the display and `isFull` in agreement.
public struct AppLevel: Codable, Equatable, Sendable {
    public var level: Double { didSet { level = Self.quantize(level) } }
    public var muted: Bool
    public init(level: Double, muted: Bool) { self.level = Self.quantize(level); self.muted = muted }
    public static func quantize(_ raw: Double) -> Double {
        guard raw.isFinite else { return 1 }
        return (min(max(raw, 0), 1) * 100).rounded() / 100
    }
    private enum CodingKeys: String, CodingKey { case level, muted }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(level: try c.decode(Double.self, forKey: .level), muted: try c.decode(Bool.self, forKey: .muted))
    }
    public static let full = AppLevel(level: 1, muted: false)
    public var isFull: Bool { level >= 1 && !muted }
    /// The gain actually applied: 0 when muted.
    public var effectiveGain: Float { muted ? 0 : Float(level) }
}
