import Foundation
import AppKit
import Observation
import ServiceManagement

/// One visible row of the mixer.
public struct MixerRow: Identifiable, Equatable {
    public let id: AppGroupKey
    public let name: String
    public let icon: NSImage?
    public let isPlaying: Bool
    public let level: Double
    public let muted: Bool
    public let isScaled: Bool
    public let error: String?

    public static func == (a: MixerRow, b: MixerRow) -> Bool {
        a.id == b.id && a.name == b.name && a.isPlaying == b.isPlaying && a.level == b.level
            && a.muted == b.muted && a.isScaled == b.isScaled && a.error == b.error
    }
}

/// Main-actor state for the UI: owns the registry, the output monitor, the engine and the settings.
@MainActor
@Observable
public final class MixerModel {
    public private(set) var rows: [MixerRow] = []
    public private(set) var allApps: [AudioApp] = []
    public private(set) var activeKeys: Set<AppGroupKey> = []
    public private(set) var errors: [AppGroupKey: String] = [:]
    public private(set) var isRunning = false
    public private(set) var startError: String?

    @ObservationIgnored public let settings: Settings
    @ObservationIgnored private let registryQueue = DispatchQueue(label: "com.mieszko.mikser.registry")
    @ObservationIgnored private let engineQueue = DispatchQueue(label: "com.mieszko.mikser.engine", qos: .userInitiated)
    @ObservationIgnored private let registry: ProcessRegistry
    @ObservationIgnored private let output: OutputDeviceMonitor
    @ObservationIgnored public let engine: TapEngine
    @ObservationIgnored private var frozenOrder: [AppGroupKey]?

    public init(settings: Settings = Settings()) {
        self.settings = settings
        registry = ProcessRegistry(queue: registryQueue)
        output = OutputDeviceMonitor(queue: engineQueue)
        engine = TapEngine(queue: engineQueue, output: output)
    }

    public func start() {
        registry.onChange = { [weak self] apps in
            Task { @MainActor [weak self] in self?.registryChanged(apps) }
        }
        engine.onActiveChange = { [weak self] keys in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.activeKeys = keys
                for key in keys { self.errors[key] = nil }
                self.rebuildRows()
            }
        }
        engine.onFailSafe = { [weak self] key, message in
            Task { @MainActor [weak self] in
                self?.errors[key] = message
                self?.rebuildRows()
            }
        }
        do {
            try output.start()
            try registry.start()
            isRunning = true
        } catch {
            startError = "\(error)"
        }
    }

    public func stop() {
        engine.stopAll()
        registry.stop()
        output.stop()
        isRunning = false
    }

    // MARK: user actions

    public func app(for key: AppGroupKey) -> AudioApp? { allApps.first { $0.id == key } }

    /// Resolves a row by key, bundle id, or display name (case-insensitive). For the control channel.
    public func app(matching text: String) -> AudioApp? {
        let t = text.lowercased()
        return allApps.first { $0.id.raw.lowercased() == t }
            ?? allApps.first { ($0.bundleID ?? "").lowercased() == t }
            ?? allApps.first { $0.displayName.lowercased() == t }
            ?? allApps.first { $0.displayName.lowercased().hasPrefix(t) }
    }

    public func setLevel(_ level: Double, for key: AppGroupKey) {
        var current = settings.level(for: key)
        current.level = min(max(level, 0), 1)
        settings.set(current, for: key)
        push(current, key)
    }

    public func setMuted(_ muted: Bool, for key: AppGroupKey) {
        var current = settings.level(for: key)
        current.muted = muted
        settings.set(current, for: key)
        push(current, key)
    }

    public func resetAudio() {
        engine.rebuildAll(reason: "reset requested")
        registry.refresh()
    }

    public var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    public func setLaunchAtLogin(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }

    /// While the popover is open the row order stays put so nothing jumps under the cursor.
    public func freezeOrder() { frozenOrder = rows.map { $0.id } }
    public func unfreezeOrder() { frozenOrder = nil; rebuildRows() }

    // MARK: internals

    private func push(_ level: AppLevel, _ key: AppGroupKey) {
        if let app = app(for: key) { engine.apply(level, to: app) }
        rebuildRows()
    }

    private func registryChanged(_ apps: [AudioApp]) {
        allApps = apps
        engine.processesChanged(apps)
        for app in apps {
            let saved = settings.level(for: app.id)
            if !saved.isFull { engine.apply(saved, to: app) }
        }
        rebuildRows()
    }

    private func rebuildRows() {
        var visible = allApps.filter { app in
            app.isUserFacing || activeKeys.contains(app.id) || !settings.level(for: app.id).isFull
        }
        if let order = frozenOrder {
            let index = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
            visible.sort { a, b in
                let ia = index[a.id] ?? Int.max, ib = index[b.id] ?? Int.max
                return ia != ib ? ia < ib : Grouping.rowOrder(a, b)
            }
        } else {
            visible.sort(by: Grouping.rowOrder)
        }
        let newRows = visible.map { app -> MixerRow in
            let level = settings.level(for: app.id)
            return MixerRow(id: app.id, name: app.displayName, icon: app.icon, isPlaying: app.isPlaying,
                            level: level.level, muted: level.muted, isScaled: activeKeys.contains(app.id),
                            error: errors[app.id])
        }
        if newRows != rows { rows = newRows }
    }
}
