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
    public let alive: Bool
    /// True for an old path that is fading out while its replacement fades in.
    public let retiring: Bool
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
    /// Old paths fading out after a replacement was built; destroyed after `crossfade` seconds.
    private var retiring: [AppTap] = []
    private var wanted: [AppGroupKey: (level: AppLevel, app: AudioApp)] = [:]
    private var pendingRelease: [AppGroupKey: DispatchWorkItem] = [:]
    private var errors: [AppGroupKey: String] = [:]
    /// Keys whose path failed the liveness check: left untouched (full volume). Rebuilt again when the
    /// HAL reports the untapped app playing (at most `livenessRetries` times), on a user action, or
    /// on reset, so a dead path cannot oscillate and a healthy one is not stuck.
    private var suspended: Set<AppGroupKey> = []
    private var livenessAttempts: [AppGroupKey: Int] = [:]
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
    /// Automatic rebuild attempts after a liveness failure before the app stays untouched until the user acts.
    public var livenessRetries = 2
    /// Seconds an old path keeps fading out after its replacement started (5 ramp time constants).
    public var crossfade: TimeInterval = 0.2
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

    /// Scaled apps whose tap carried signal within the last `holdMs`. Never waits on the engine queue.
    public func playingKeys(holdMs: Double = 500) -> Set<AppGroupKey> {
        let snapshot = mirrorLock.withLock { mirror }
        let now = mach_absolute_time()
        return Set(snapshot.values.compactMap { $0.hadSignal(withinMs: holdMs, now: now) ? $0.key : nil })
    }

    /// Pure decision used by the liveness check (tested without Core Audio).
    public static func pathLooksDead(expectedSound: Bool, callbacks: UInt64) -> Bool {
        expectedSound && callbacks == 0
    }

    /// Test hook: puts a key into the suspended state as a failed liveness check would.
    public func _suspendForTesting(_ key: AppGroupKey) {
        queue.sync { suspended.insert(key) }
    }

    // MARK: on queue

    private func notifyActive() {
        let copy = taps
        mirrorLock.withLock { mirror = copy }
        onActiveChange?(Set(taps.keys))
    }

    private func applyLocked(_ level: AppLevel, _ app: AudioApp, userInitiated: Bool) {
        let key = app.id
        if userInitiated {
            suspended.remove(key)
            livenessAttempts[key] = nil
        }
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

    /// Builds the path for `key`. When a path already exists it stays alive and fades out while the
    /// new one fades in, so the app is never untapped in between (a muted app never leaks, a scaled
    /// app never jumps to full volume). With matching 30 ms ramps the two paths sum to a constant.
    private func buildLocked(_ key: AppGroupKey) {
        guard let entry = wanted[key] else { return }
        let old = taps[key]
        let expectSound = entry.app.isPlaying || (old?.hadSignal(withinMs: 1000) ?? false)
        guard output.deviceID != kAudioObjectUnknown, let uid = output.deviceUID else {
            retire(old, key: key)
            fail(key, "no default output device"); return
        }
        // Only tap process objects the HAL still knows; a stale id makes the tap fail with '!obj'.
        let live = Set(HAL.readObjectIDs(HAL.system, kAudioHardwarePropertyProcessObjectList) ?? [])
        let alive = entry.app.processObjectIDs.filter { live.contains($0) }
        guard !alive.isEmpty else {
            // The registry will report the new process set shortly; nothing to fail loudly about.
            retire(old, key: key)
            transientRetries += 1
            notifyActive()
            return
        }
        let tap = AppTap(key: key, requestedObjectIDs: entry.app.processObjectIDs, processObjectIDs: alive,
                         outputDeviceID: output.deviceID, outputUID: uid, target: entry.level.effectiveGain,
                         startSilent: old != nil)
        do {
            try tap.activate()
            taps[key] = tap
            errors[key] = nil
            retire(old, key: key)
            notifyActive()
            if expectSound { scheduleLivenessCheck(key, tap) }
        } catch TapError.coreAudio(let status, _) where status == kAudioHardwareBadObjectError {
            // A process vanished between the list read and the tap creation: transient, retried on the next change.
            tap.invalidate()
            retire(old, key: key)
            transientRetries += 1
            notifyActive()
        } catch {
            tap.invalidate()
            retire(old, key: key)
            fail(key, "\(error)")
        }
    }

    /// Fades an old path out and destroys it after the crossfade; nothing to do when there is none.
    /// The fade-out waits until the replacement has delivered its first callback (bounded wait), so
    /// the two ramps overlap and their sum stays at the level throughout.
    private func retire(_ old: AppTap?, key: AppGroupKey) {
        guard let old else { return }
        if taps[key] === old { taps[key] = nil }
        retiring.append(old)
        let replacement = taps[key]
        func fadeOut(attempt: Int) {
            if let replacement, replacement.callbacks == 0, attempt < 15 {
                queue.asyncAfter(deadline: .now() + 0.02) { [weak self] in
                    guard self != nil else { return }
                    fadeOut(attempt: attempt + 1)
                }
                return
            }
            old.target = 0
            queue.asyncAfter(deadline: .now() + crossfade) { [weak self, weak old] in
                guard let self, let old else { return }
                old.invalidate()
                self.retiring.removeAll { $0 === old }
            }
        }
        fadeOut(attempt: 0)
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
            self.fail(key, "the audio path never started; the app plays at full volume until it plays again, you move its slider, or you reset audio")
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

    private func forget(_ key: AppGroupKey) {
        destroyLocked(key)
        wanted[key] = nil
        suspended.remove(key)
        livenessAttempts[key] = nil
    }

    private func processesChangedLocked(_ apps: [AudioApp]) {
        let byKey = Dictionary(apps.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Apps that quit: drop every trace, including a suspension, so a relaunch starts clean.
        for key in Set(taps.keys).union(wanted.keys).union(suspended).union(pendingRelease.keys) where byKey[key] == nil {
            forget(key)
        }
        for key in Array(taps.keys) {
            guard let app = byKey[key] else { continue }
            if let entry = wanted[key] { wanted[key] = (entry.level, app) }
            if let tap = taps[key], tap.requestedObjectIDs != app.processObjectIDs, wanted[key] != nil {
                rebuilds += 1
                buildLocked(key)
            }
        }
        // A suspended app that the HAL now reports playing (it is untapped, so the flag is trustworthy)
        // gets another attempt, up to the retry budget.
        for key in Array(suspended) {
            guard let app = byKey[key], app.isPlaying, wanted[key] != nil else { continue }
            let attempts = livenessAttempts[key] ?? 0
            guard attempts < livenessRetries else { continue }
            livenessAttempts[key] = attempts + 1
            suspended.remove(key)
            wanted[key] = (wanted[key]!.level, app)
            buildLocked(key)
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
        livenessAttempts.removeAll()
        for key in Array(wanted.keys) { buildLocked(key) }
        for key in Array(taps.keys) where wanted[key] == nil { destroyLocked(key) }
        notifyActive()
    }

    private func stopAllLocked() {
        for (_, work) in pendingRelease { work.cancel() }
        pendingRelease.removeAll()
        for (_, tap) in taps { tap.invalidate() }
        for tap in retiring { tap.invalidate() }
        retiring.removeAll()
        taps.removeAll()
        wanted.removeAll()
        suspended.removeAll()
        livenessAttempts.removeAll()
        mirrorLock.withLock { mirror = [:] }
    }

    private func snapshotLocked() -> EngineStats {
        let now = mach_absolute_time()
        func stats(_ tap: AppTap, retiring: Bool) -> TapStats {
            TapStats(key: tap.key, target: tap.target, current: tap.currentGain,
                     peakIn: tap.peakIn, peakOut: tap.peakOut, callbacks: tap.callbacks,
                     callbackAgeMs: HAL.msBetween(tap.lastCallbackHostTime, now),
                     startDelayMs: tap.firstCallbackHostTime == 0 ? -1 : HAL.msBetween(tap.activatedAt, tap.firstCallbackHostTime),
                     ageMs: HAL.msBetween(tap.activatedAt, now),
                     sinceTargetChangeMs: HAL.msBetween(tap.targetChangedHostTime, now),
                     sampleRate: tap.sampleRate, bufferFrames: tap.bufferFrames,
                     outputUID: tap.outputUID, processObjectIDs: tap.processObjectIDs,
                     alive: tap.isAlive, retiring: retiring)
        }
        let list = taps.values.map { stats($0, retiring: false) } + retiring.map { stats($0, retiring: true) }
        return EngineStats(taps: list.sorted { $0.key.raw < $1.key.raw }, wantedKeys: wanted.keys.sorted { $0.raw < $1.raw },
                           suspendedKeys: suspended.sorted { $0.raw < $1.raw }, errors: errors,
                           rebuilds: rebuilds, transientRetries: transientRetries, failSafes: failSafes, lastError: lastError,
                           outputUID: output.deviceUID, outputName: output.deviceName, sampleRate: output.sampleRate)
    }
}
