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
    /// Milliseconds since the target was last changed; -1 if never changed since creation.
    public let sinceTargetChangeMs: Double
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
    public let suspendedKeys: [AppGroupKey]
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
    /// Keys whose path failed the liveness check: left untouched (full volume) and not rebuilt by the
    /// registry until the user moves the slider or resets, so a broken path cannot oscillate.
    private var suspended: Set<AppGroupKey> = []
    private var transientRetries = 0
    private var rebuilds = 0
    private var failSafes = 0
    private var lastError: String?
    // Lock-protected mirror of `taps` for readers that must never wait on the engine queue (the main
    // thread while a tap is being built).
    private let mirrorLock = NSLock()
    private var mirror: [AppGroupKey: AppTap] = [:]

    /// Seconds an app stays tapped after returning to full volume, so sliding through 100 does not thrash.
    public var releaseDelay: TimeInterval = 2.0
    /// Seconds after creating a tap for a playing app before "no callbacks yet" counts as a dead path.
    public var livenessDelay: TimeInterval = 2.5
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

    /// `userInitiated` clears a suspension; the registry's automatic re-applies pass false.
    public func apply(_ level: AppLevel, to app: AudioApp, userInitiated: Bool = true) {
        queue.async { [self] in applyLocked(level, app, userInitiated: userInitiated) }
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

    /// Never waits on the engine queue.
    public func activeKeys() -> Set<AppGroupKey> {
        mirrorLock.withLock { Set(mirror.keys) }
    }

    /// Scaled apps whose tap carried signal within the last `holdMs`. A tapped process no longer reports
    /// "running output" to the HAL (its direct path is muted), so this replaces that flag for scaled
    /// apps. Never waits on the engine queue.
    public func playingKeys(holdMs: Double = 500) -> Set<AppGroupKey> {
        let snapshot = mirrorLock.withLock { mirror }
        let now = mach_absolute_time()
        return Set(snapshot.values.compactMap { $0.hadSignal(withinMs: holdMs, now: now) ? $0.key : nil })
    }

    /// Pure decision used by the liveness check (tested without Core Audio).
    public static func pathLooksDead(expectedSound: Bool, callbacks: UInt64) -> Bool {
        expectedSound && callbacks == 0
    }

    // MARK: on queue

    private func notifyActive() {
        let copy = taps
        mirrorLock.withLock { mirror = copy }
        onActiveChange?(Set(taps.keys))
    }

    private func applyLocked(_ level: AppLevel, _ app: AudioApp, userInitiated: Bool) {
        let key = app.id
        if userInitiated { suspended.remove(key) }
        if level.isFull {
            wanted[key] = nil
            errors[key] = nil
            guard let tap = taps[key] else { notifyActive(); return }
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
        guard !suspended.contains(key) else { return }
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
        var expectSound = entry.app.isPlaying
        if let old = taps[key] {
            expectSound = expectSound || old.hadSignal(withinMs: 1000)
            old.invalidate()
            taps[key] = nil
        }
        guard output.deviceID != kAudioObjectUnknown, let uid = output.deviceUID else {
            fail(key, "no default output device"); return
        }
        // Only tap process objects the HAL still knows; a stale id makes the tap fail with '!obj'.
        let live = Set(HAL.readObjectIDs(HAL.system, kAudioHardwarePropertyProcessObjectList) ?? [])
        let alive = entry.app.processObjectIDs.filter { live.contains($0) }
        guard !alive.isEmpty else {
            // The registry will report the new process set shortly; nothing to fail loudly about.
            transientRetries += 1
            notifyActive()
            return
        }
        let tap = AppTap(key: key, requestedObjectIDs: entry.app.processObjectIDs, processObjectIDs: alive,
                         outputDeviceID: output.deviceID, outputUID: uid, target: entry.level.effectiveGain)
        do {
            try tap.activate()
            taps[key] = tap
            errors[key] = nil
            notifyActive()
            if expectSound { scheduleLivenessCheck(key, tap) }
        } catch TapError.coreAudio(let status, _) where status == kAudioHardwareBadObjectError {
            // A process vanished between the list read and the tap creation: transient, retried on the next change.
            tap.invalidate()
            transientRetries += 1
            notifyActive()
        } catch {
            tap.invalidate()
            fail(key, "\(error)")
        }
    }

    /// One-shot, event-driven: a tap made for an app that was audibly playing must start delivering
    /// callbacks within `livenessDelay`; otherwise the app would sit muted with nobody rendering it.
    private func scheduleLivenessCheck(_ key: AppGroupKey, _ tap: AppTap) {
        queue.asyncAfter(deadline: .now() + livenessDelay) { [weak self, weak tap] in
            guard let self, let tap, self.taps[key] === tap else { return }
            guard Self.pathLooksDead(expectedSound: true, callbacks: tap.callbacks) else { return }
            self.taps[key] = nil
            tap.invalidate()
            self.suspended.insert(key)
            self.fail(key, "the audio path never started; the app plays at full volume until you move its slider or reset audio")
        }
    }

    private func fail(_ key: AppGroupKey, _ message: String) {
        failSafes += 1
        lastError = "\(key.raw): \(message)"
        errors[key] = message
        onFailSafe?(key, message)
        notifyActive()
    }

    private func destroyLocked(_ key: AppGroupKey) {
        pendingRelease[key]?.cancel()
        pendingRelease[key] = nil
        errors[key] = nil
        if let tap = taps[key] {
            tap.invalidate()
            taps[key] = nil
        }
        notifyActive()
    }

    private func processesChangedLocked(_ apps: [AudioApp]) {
        let byKey = Dictionary(apps.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for key in Array(taps.keys) {
            guard let app = byKey[key] else {
                // The app quit; its saved level lives in Settings, the path is gone.
                destroyLocked(key)
                wanted[key] = nil
                suspended.remove(key)
                continue
            }
            if let entry = wanted[key] { wanted[key] = (entry.level, app) }
            if let tap = taps[key], tap.requestedObjectIDs != app.processObjectIDs, wanted[key] != nil {
                rebuilds += 1
                buildLocked(key)
            }
        }
        for (key, entry) in wanted where taps[key] == nil && !suspended.contains(key) {
            if let app = byKey[key], !app.processObjectIDs.isEmpty {
                wanted[key] = (entry.level, app)
                buildLocked(key)
            }
        }
    }

    private func rebuildAllLocked(reason: String) {
        rebuilds += 1
        suspended.removeAll()
        for key in Array(taps.keys) {
            taps[key]?.invalidate()
            taps[key] = nil
        }
        for key in Array(wanted.keys) { buildLocked(key) }
        notifyActive()
    }

    private func stopAllLocked() {
        for (_, work) in pendingRelease { work.cancel() }
        pendingRelease.removeAll()
        for (_, tap) in taps { tap.invalidate() }
        taps.removeAll()
        wanted.removeAll()
        suspended.removeAll()
        mirrorLock.withLock { mirror = [:] }
    }

    private func snapshotLocked() -> EngineStats {
        let now = mach_absolute_time()
        let stats = taps.values.map { tap -> TapStats in
            TapStats(key: tap.key, target: tap.target, current: tap.currentGain,
                     peakIn: tap.peakIn, peakOut: tap.peakOut, callbacks: tap.callbacks,
                     callbackAgeMs: HAL.msBetween(tap.lastCallbackHostTime, now),
                     startDelayMs: tap.firstCallbackHostTime == 0 ? -1 : HAL.msBetween(tap.activatedAt, tap.firstCallbackHostTime),
                     ageMs: HAL.msBetween(tap.activatedAt, now),
                     sinceTargetChangeMs: HAL.msBetween(tap.targetChangedHostTime, now),
                     sampleRate: tap.sampleRate, bufferFrames: tap.bufferFrames,
                     outputUID: tap.outputUID, processObjectIDs: tap.processObjectIDs,
                     isFloat32: tap.isFloat32, alive: tap.isAlive)
        }.sorted { $0.key.raw < $1.key.raw }
        return EngineStats(taps: stats, wantedKeys: wanted.keys.sorted { $0.raw < $1.raw },
                           suspendedKeys: suspended.sorted { $0.raw < $1.raw }, errors: errors,
                           rebuilds: rebuilds, transientRetries: transientRetries, failSafes: failSafes, lastError: lastError,
                           outputUID: output.deviceUID, outputName: output.deviceName, sampleRate: output.sampleRate)
    }
}
