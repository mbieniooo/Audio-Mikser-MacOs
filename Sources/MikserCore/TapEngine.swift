import Foundation
import CoreAudio

public struct TapStats {
    public let key: AppGroupKey
    public let target: Float
    public let current: Float
    public let peakIn: Float
    public let peakOut: Float
    public let callbacks: UInt64
    public let callbackAgeMs: Double
    /// Time from AudioDeviceStart to the first IO callback; -1 until the first callback.
    public let startDelayMs: Double
    public let ageMs: Double
    public let sampleRate: Double
    public let bufferFrames: UInt32
    public let outputUID: String
    public let processObjectIDs: [AudioObjectID]
    public let isFloat32: Bool
    public let alive: Bool
}

public struct EngineStats {
    public let taps: [TapStats]
    public let wantedKeys: [AppGroupKey]
    public let errors: [AppGroupKey: String]
    public let rebuilds: Int
    public let transientRetries: Int
    public let failSafes: Int
    public let lastError: String?
    public let outputUID: String?
    public let outputName: String?
    public let sampleRate: Double
}

/// Owns one AppTap per scaled app. Everything runs on one serial queue shared with the OutputDeviceMonitor.
public final class TapEngine {
    private let queue: DispatchQueue
    private let output: OutputDeviceMonitor
    private var taps: [AppGroupKey: AppTap] = [:]
    private var wanted: [AppGroupKey: (level: AppLevel, app: AudioApp)] = [:]
    private var pendingRelease: [AppGroupKey: DispatchWorkItem] = [:]
    private var errors: [AppGroupKey: String] = [:]
    private var transientRetries = 0
    private var rebuilds = 0
    private var failSafes = 0
    private var lastError: String?
    private static let timebase: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000 // host ticks → ms
    }()

    /// Seconds an app stays tapped after returning to full volume, so sliding through 100 does not thrash.
    public var releaseDelay: TimeInterval = 2.0
    /// On `queue`: an app's path failed and it was returned to normal audio.
    public var onFailSafe: ((AppGroupKey, String) -> Void)?
    /// On `queue`: the set of scaled apps changed.
    public var onActiveChange: ((Set<AppGroupKey>) -> Void)?

    public init(queue: DispatchQueue, output: OutputDeviceMonitor) {
        self.queue = queue
        self.output = output
        output.onChange = { [weak self] reason in self?.rebuildAllLocked(reason: reason) }
    }

    // MARK: public API (safe from any thread)

    public func apply(_ level: AppLevel, to app: AudioApp) {
        queue.async { [self] in applyLocked(level, app) }
    }

    public func processesChanged(_ apps: [AudioApp]) {
        queue.async { [self] in processesChangedLocked(apps) }
    }

    public func rebuildAll(reason: String) {
        queue.async { [self] in rebuildAllLocked(reason: reason) }
    }

    public func stopAll() {
        queue.sync { stopAllLocked() }
    }

    public func snapshot() -> EngineStats {
        queue.sync { snapshotLocked() }
    }

    public func activeKeys() -> Set<AppGroupKey> {
        queue.sync { Set(taps.keys) }
    }

    // MARK: on queue

    private func applyLocked(_ level: AppLevel, _ app: AudioApp) {
        let key = app.id
        if level.isFull {
            wanted[key] = nil
            guard let tap = taps[key] else { return }
            tap.target = 1
            pendingRelease[key]?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.wanted[key] == nil else { return }
                self.pendingRelease[key] = nil
                self.destroyLocked(key)
            }
            pendingRelease[key] = work
            queue.asyncAfter(deadline: .now() + releaseDelay, execute: work)
            return
        }
        pendingRelease[key]?.cancel()
        pendingRelease[key] = nil
        wanted[key] = (level, app)
        if let tap = taps[key], tap.isActive,
           tap.requestedObjectIDs == app.processObjectIDs, tap.outputUID == output.deviceUID {
            tap.target = level.effectiveGain
            return
        }
        buildLocked(key)
    }

    private func buildLocked(_ key: AppGroupKey) {
        guard let entry = wanted[key] else { return }
        if let old = taps[key] { old.invalidate(); taps[key] = nil }
        guard output.deviceID != kAudioObjectUnknown, let uid = output.deviceUID else {
            fail(key, "no default output device"); return
        }
        // Only tap process objects the HAL still knows; a stale id makes the tap fail with '!obj'.
        let live = Set(HAL.readObjectIDs(HAL.system, kAudioHardwarePropertyProcessObjectList) ?? [])
        let alive = entry.app.processObjectIDs.filter { live.contains($0) }
        guard !alive.isEmpty else {
            // The registry will report the new process set shortly; nothing to fail loudly about.
            transientRetries += 1
            onActiveChange?(Set(taps.keys))
            return
        }
        let tap = AppTap(key: key, requestedObjectIDs: entry.app.processObjectIDs, processObjectIDs: alive,
                         outputDeviceID: output.deviceID, outputUID: uid, target: entry.level.effectiveGain)
        do {
            try tap.activate()
            taps[key] = tap
            errors[key] = nil
            onActiveChange?(Set(taps.keys))
        } catch TapError.coreAudio(let status, _) where status == kAudioHardwareBadObjectError {
            // A process vanished between the list read and the tap creation: transient, retried on the next change.
            tap.invalidate()
            transientRetries += 1
            onActiveChange?(Set(taps.keys))
        } catch {
            tap.invalidate()
            fail(key, "\(error)")
        }
    }

    private func fail(_ key: AppGroupKey, _ message: String) {
        failSafes += 1
        lastError = "\(key.raw): \(message)"
        errors[key] = message
        onFailSafe?(key, message)
        onActiveChange?(Set(taps.keys))
    }

    private func destroyLocked(_ key: AppGroupKey) {
        pendingRelease[key]?.cancel()
        pendingRelease[key] = nil
        if let tap = taps[key] {
            tap.invalidate()
            taps[key] = nil
            onActiveChange?(Set(taps.keys))
        }
    }

    private func processesChangedLocked(_ apps: [AudioApp]) {
        let byKey = Dictionary(apps.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for key in Array(taps.keys) {
            guard let app = byKey[key] else {
                // The app quit; its saved level lives in Settings, the path is gone.
                destroyLocked(key)
                wanted[key] = nil
                continue
            }
            if let entry = wanted[key] { wanted[key] = (entry.level, app) }
            if let tap = taps[key], tap.requestedObjectIDs != app.processObjectIDs, wanted[key] != nil {
                rebuilds += 1
                buildLocked(key)
            }
        }
        for (key, entry) in wanted where taps[key] == nil {
            if let app = byKey[key], !app.processObjectIDs.isEmpty {
                wanted[key] = (entry.level, app)
                buildLocked(key)
            }
        }
    }

    private func rebuildAllLocked(reason: String) {
        rebuilds += 1
        for key in Array(taps.keys) {
            taps[key]?.invalidate()
            taps[key] = nil
        }
        for key in Array(wanted.keys) { buildLocked(key) }
        onActiveChange?(Set(taps.keys))
    }

    private func stopAllLocked() {
        for (_, work) in pendingRelease { work.cancel() }
        pendingRelease.removeAll()
        for (_, tap) in taps { tap.invalidate() }
        taps.removeAll()
        wanted.removeAll()
    }

    private func snapshotLocked() -> EngineStats {
        let now = mach_absolute_time()
        let stats = taps.values.map { tap -> TapStats in
            let last = tap.lastCallbackHostTime
            let age = last == 0 ? -1 : Double(now &- last) * Self.timebase
            let first = tap.firstCallbackHostTime
            let startDelay = (first == 0 || tap.activatedAt == 0) ? -1 : Double(first &- tap.activatedAt) * Self.timebase
            let ageSinceStart = tap.activatedAt == 0 ? -1 : Double(now &- tap.activatedAt) * Self.timebase
            return TapStats(key: tap.key, target: tap.target, current: tap.currentGain,
                            peakIn: tap.peakIn, peakOut: tap.peakOut, callbacks: tap.callbacks,
                            callbackAgeMs: age, startDelayMs: startDelay, ageMs: ageSinceStart,
                            sampleRate: tap.sampleRate, bufferFrames: tap.bufferFrames,
                            outputUID: tap.outputUID, processObjectIDs: tap.processObjectIDs,
                            isFloat32: tap.isFloat32, alive: tap.isAlive)
        }.sorted { $0.key.raw < $1.key.raw }
        return EngineStats(taps: stats, wantedKeys: wanted.keys.sorted { $0.raw < $1.raw }, errors: errors,
                           rebuilds: rebuilds, transientRetries: transientRetries, failSafes: failSafes, lastError: lastError,
                           outputUID: output.deviceUID, outputName: output.deviceName, sampleRate: output.sampleRate)
    }
}
