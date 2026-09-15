import Foundation
import AppKit

/// Hidden verification channel: distributed notification in, JSON reply file + reply notification out.
/// Commands: ping, set <app> <level>, mute <app>, unmute <app>, reset, stats, dump, quit,
/// output list | output set <name>, login on|off|status, popover open|close.
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
    /// open → true / close → false; returns the last measured popover open time in ms, if any.
    public var popoverHandler: ((Bool) -> Double?)?
    /// Captures the open popover to PNG files in the given directory; calls back with the paths written.
    public var snapshotHandler: ((URL, @escaping ([String]) -> Void) -> Void)?

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
        let args = info["args"] as? [String] ?? []
        let appText = info["app"] as? String ?? args.first ?? ""
        let level = (info["level"] as? NSNumber)?.doubleValue ?? Double(info["level"] as? String ?? "")
            ?? (args.count > 1 ? Double(args[1]) : nil)
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
                        "devices": Array(Set(app.processes.flatMap { $0.devices })).sorted().map { HAL.deviceName($0) ?? "\($0)" },
                        "level": level.level, "muted": level.muted,
                        "scaled": model.activeKeys.contains(app.id), "error": model.errors[app.id] ?? ""]
            }
            reply["visible"] = model.rows.map { $0.id.raw }
            reply["visibleRows"] = model.rows.map { ["key": $0.id.raw, "name": $0.name, "playing": $0.isPlaying, "scaled": $0.isScaled, "level": $0.level, "muted": $0.muted] }
            reply["playingScaled"] = model.engine.playingKeys().map { $0.raw }
            reply["stats"] = Self.statsJSON(model.engine.snapshot())
        case "output":
            let devices = HAL.outputDevices().filter { !$0.name.hasPrefix("Mikser ") }
            let current = HAL.defaultOutputDevice()
            reply["devices"] = devices.map { ["id": Int($0.id), "uid": $0.uid, "name": $0.name, "default": $0.id == current] }
            if args.first?.lowercased() == "set" {
                let wanted = args.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespaces).lowercased()
                if wanted.isEmpty {
                    reply["ok"] = false
                    reply["message"] = "output set needs a device name"
                } else if let dev = devices.first(where: { $0.name.lowercased() == wanted })
                    ?? devices.first(where: { $0.name.lowercased().hasPrefix(wanted) }) {
                    let status = HAL.setDefaultOutputDevice(dev.id)
                    reply["ok"] = status == noErr
                    reply["message"] = status == noErr ? "default output → \(dev.name)" : "could not switch: \(HAL.describe(status))"
                } else {
                    reply["ok"] = false
                    reply["message"] = "no output device matches '\(wanted)'"
                }
            }
        case "login":
            let want = args.first?.lowercased() ?? "status"
            if want == "on" || want == "off" {
                do { try model.setLaunchAtLogin(want == "on") } catch { reply["ok"] = false; reply["message"] = "\(error)" }
            }
            reply["launchAtLogin"] = model.launchAtLogin
        case "popover":
            let open = (args.first?.lowercased() ?? "open") != "close"
            let ms = popoverHandler?(open)
            reply["popoverOpenMs"] = ms ?? -1
            reply["visibleRows"] = model.rows.count
            // Let the popover finish showing before the reply, so the timing is the fresh one.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self else { return }
                var late = reply
                late["popoverOpenMs"] = self.popoverHandler?(open) ?? -1
                self.writeReply(late)
            }
            return
        case "snapshot":
            _ = popoverHandler?(true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self else { return }
                var late = reply
                let dir = Self.replyURL.deletingLastPathComponent()
                late["popoverOpenMs"] = self.popoverHandler?(true) ?? -1
                guard let handler = self.snapshotHandler else { late["files"] = []; self.writeReply(late); return }
                handler(dir) { files in
                    late["files"] = files
                    self.writeReply(late)
                }
            }
            return
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
            "rebuilds": s.rebuilds, "transientRetries": s.transientRetries, "failSafes": s.failSafes, "lastError": s.lastError ?? "",
            "wanted": s.wantedKeys.map { $0.raw },
            "suspended": s.suspendedKeys.map { $0.raw },
            "globalTaps": HAL.tapList().count,
            "mikserDevices": HAL.mikserDeviceNames(),
            "errors": Dictionary(uniqueKeysWithValues: s.errors.map { ($0.key.raw, $0.value) }),
            "taps": s.taps.map { t -> [String: Any] in
                ["key": t.key.raw, "target": t.target, "current": t.current, "peakIn": t.peakIn, "peakOut": t.peakOut,
                 "callbacks": t.callbacks, "callbackAgeMs": t.callbackAgeMs, "startDelayMs": t.startDelayMs, "ageMs": t.ageMs,
                 "sinceTargetChangeMs": t.sinceTargetChangeMs, "sampleRate": t.sampleRate,
                 "bufferFrames": t.bufferFrames, "outputUID": t.outputUID, "objects": t.processObjectIDs.map { Int($0) },
                 "alive": t.alive, "retiring": t.retiring]
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
