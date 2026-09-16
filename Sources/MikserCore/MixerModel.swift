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
    /// Verification only: the popover draws an opaque window background while a snapshot is taken.
    public var snapshotBackground = false

    @ObservationIgnored public let settings: Settings
    @ObservationIgnored private let registryQueue = DispatchQueue(label: MikserID.bundle + ".registry")
    @ObservationIgnored private let engineQueue = DispatchQueue(label: MikserID.bundle + ".engine", qos: .userInitiated)
    @ObservationIgnored private let registry: ProcessRegistry
    @ObservationIgnored private let output: OutputDeviceMonitor
    @ObservationIgnored public let engine: TapEngine
    @ObservationIgnored private var frozenOrder: [AppGroupKey]?
    @ObservationIgnored private var playingScaled: Set<AppGroupKey> = []
    @ObservationIgnored private var popoverRefresh: DispatchSourceTimer?

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
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !t.isEmpty else { return nil }
        // Exact matches may name anything; a name prefix only ever picks a user-facing app, so "a"
        // cannot land on assistantd.
        return allApps.first { $0.id.raw.lowercased() == t }
            ?? allApps.first { ($0.bundleID ?? "").lowercased() == t }
            ?? allApps.first { $0.displayName.lowercased() == t }
            ?? allApps.first { $0.isUserFacing && $0.displayName.lowercased().hasPrefix(t) }
    }

    public func setLevel(_ level: Double, for key: AppGroupKey) {
        let current = AppLevel(level: level, muted: settings.level(for: key).muted)
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

    /// While the popover is open the row order stays put so nothing jumps under the cursor, and the
    /// playing marks of scaled apps refresh twice a second (their HAL flag goes quiet once tapped).
    public func freezeOrder() {
        refreshPlaying()
        frozenOrder = nil
        rebuildRows()
        frozenOrder = rows.map { $0.id }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if self.refreshPlaying() { self.rebuildRows() }
        }
        timer.resume()
        popoverRefresh = timer
    }

    public func unfreezeOrder() {
        popoverRefresh?.cancel()
        popoverRefresh = nil
        frozenOrder = nil
        rebuildRows()
    }

    /// Returns true when the set of playing scaled apps changed.
    @discardableResult
    private func refreshPlaying() -> Bool {
        let now = engine.playingKeys()
        guard now != playingScaled else { return false }
        playingScaled = now
        return true
    }

    private func isPlaying(_ app: AudioApp) -> Bool {
        activeKeys.contains(app.id) ? playingScaled.contains(app.id) : app.isPlaying
    }

    // MARK: internals

    /// Test hook: replaces the registry snapshot without touching the engine.
    public func _setAppsForTesting(_ apps: [AudioApp], rebuild: Bool) {
        allApps = apps
        if rebuild { rebuildRows() }
    }

    private func push(_ level: AppLevel, _ key: AppGroupKey) {
        if level.isFull { errors[key] = nil }
        if let app = app(for: key) { engine.apply(level, to: app, userInitiated: true) }
        rebuildRows()
    }

    private func registryChanged(_ apps: [AudioApp]) {
        allApps = apps
        engine.processesChanged(apps)
        for app in apps {
            let saved = settings.level(for: app.id)
            if !saved.isFull { engine.apply(saved, to: app, userInitiated: false) }
        }
        rebuildRows()
    }

    /// Test hook: records an error for a row as the engine's fail safe would.
    public func _setErrorForTesting(_ message: String?, for key: AppGroupKey) {
        errors[key] = message
        rebuildRows()
    }

    private func rebuildRows() {
        var visible = allApps.filter { app in
            app.isUserFacing || activeKeys.contains(app.id) || !settings.level(for: app.id).isFull
        }
        let playing = Dictionary(uniqueKeysWithValues: visible.map { ($0.id, isPlaying($0)) })
        func order(_ a: AudioApp, _ b: AudioApp) -> Bool {
            let pa = playing[a.id] ?? false, pb = playing[b.id] ?? false
            if pa != pb { return pa }
            let byName = a.displayName.localizedCaseInsensitiveCompare(b.displayName)
            if byName != .orderedSame { return byName == .orderedAscending }
            return a.id.raw < b.id.raw
        }
        if let frozen = frozenOrder {
            let index = Dictionary(frozen.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
            visible.sort { a, b in
                let ia = index[a.id] ?? Int.max, ib = index[b.id] ?? Int.max
                return ia != ib ? ia < ib : order(a, b)
            }
        } else {
            visible.sort(by: order)
        }
        let newRows = visible.map { app -> MixerRow in
            let level = settings.level(for: app.id)
            return MixerRow(id: app.id, name: app.displayName, icon: app.icon, isPlaying: playing[app.id] ?? false,
                            level: level.level, muted: level.muted, isScaled: activeKeys.contains(app.id),
                            error: errors[app.id])
        }
        if newRows != rows { rows = newRows }
    }
}
