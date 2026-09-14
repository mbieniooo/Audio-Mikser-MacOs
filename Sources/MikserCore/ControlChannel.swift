import Foundation
import AppKit

/// Hidden verification channel: distributed notification in, JSON reply file + reply notification out.
/// Commands: ping, set <app> <level>, mute <app>, unmute <app>, reset, stats, dump, quit.
@MainActor
public final class ControlChannel {
    public nonisolated static let controlName = Notification.Name("com.mieszko.mikser.control")
    public nonisolated static let replyName = Notification.Name("com.mieszko.mikser.reply")
    public nonisolated static var replyURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Mikser", isDirectory: true).appendingPathComponent("reply.json")
    }

    private let model: MixerModel
    private var observer: NSObjectProtocol?
    public var onQuit: (() -> Void)?

    public init(model: MixerModel) { self.model = model }

    public func install() {
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Self.controlName, object: nil, queue: .main) { [weak self] note in
            let info = note.userInfo ?? [:]
            Task { @MainActor [weak self] in self?.handle(info) }
        }
    }

    public func remove() {
        if let o = observer { DistributedNotificationCenter.default().removeObserver(o); observer = nil }
    }

    private func handle(_ info: [AnyHashable: Any]) {
        let cmd = (info["cmd"] as? String ?? "").lowercased()
        let appText = info["app"] as? String ?? ""
        let level = (info["level"] as? NSNumber)?.doubleValue ?? Double(info["level"] as? String ?? "")
        var reply: [String: Any] = ["cmd": cmd, "at": Date().timeIntervalSince1970, "ok": true]

        func needApp() -> AudioApp? {
            if let app = model.app(matching: appText) { return app }
            reply["ok"] = false
            reply["message"] = "no audio app matches '\(appText)'"
            return nil
        }

        switch cmd {
        case "ping":
            reply["message"] = "pong"
        case "set":
            if let app = needApp() {
                guard let level, (0...1).contains(level) else { reply["ok"] = false; reply["message"] = "level must be 0…1"; break }
                model.setLevel(level, for: app.id)
                reply["message"] = "\(app.displayName) → \(Int((level * 100).rounded()))%"
                reply["app"] = app.id.raw
            }
        case "mute", "unmute":
            if let app = needApp() {
                model.setMuted(cmd == "mute", for: app.id)
                reply["message"] = "\(app.displayName) \(cmd)d"
                reply["app"] = app.id.raw
            }
        case "reset":
            model.resetAudio()
            reply["message"] = "rebuilding every tap"
        case "stats":
            reply["stats"] = Self.statsJSON(model.engine.snapshot())
        case "dump":
            reply["rows"] = model.allApps.map { app -> [String: Any] in
                let level = model.settings.level(for: app.id)
                return ["key": app.id.raw, "name": app.displayName, "bundle": app.bundleID ?? "",
                        "pids": app.pids.map { Int($0) }, "objects": app.processObjectIDs.map { Int($0) },
                        "playing": app.isPlaying, "userFacing": app.isUserFacing,
                        "level": level.level, "muted": level.muted,
                        "scaled": model.activeKeys.contains(app.id), "error": model.errors[app.id] ?? ""]
            }
            reply["visible"] = model.rows.map { $0.id.raw }
            reply["stats"] = Self.statsJSON(model.engine.snapshot())
        case "quit":
            reply["message"] = "quitting"
            writeReply(reply)
            onQuit?()
            return
        default:
            reply["ok"] = false
            reply["message"] = "unknown command '\(cmd)'"
        }
        writeReply(reply)
    }

    nonisolated static func statsJSON(_ s: EngineStats) -> [String: Any] {
        [
            "outputUID": s.outputUID ?? "", "outputName": s.outputName ?? "", "sampleRate": s.sampleRate,
            "rebuilds": s.rebuilds, "failSafes": s.failSafes, "lastError": s.lastError ?? "",
            "wanted": s.wantedKeys.map { $0.raw },
            "errors": Dictionary(uniqueKeysWithValues: s.errors.map { ($0.key.raw, $0.value) }),
            "taps": s.taps.map { t -> [String: Any] in
                ["key": t.key.raw, "target": t.target, "current": t.current, "peakIn": t.peakIn, "peakOut": t.peakOut,
                 "callbacks": t.callbacks, "callbackAgeMs": t.callbackAgeMs, "sampleRate": t.sampleRate,
                 "bufferFrames": t.bufferFrames, "outputUID": t.outputUID, "objects": t.processObjectIDs.map { Int($0) },
                 "float32": t.isFloat32, "alive": t.alive]
            },
        ]
    }

    private func writeReply(_ reply: [String: Any]) {
        let url = Self.replyURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: reply, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("Mikser control: could not write reply: \(error)")
        }
        DistributedNotificationCenter.default().postNotificationName(Self.replyName, object: nil, userInfo: nil, deliverImmediately: true)
    }
}
