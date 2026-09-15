import Foundation
import CoreAudio

public enum RegistryError: Error, CustomStringConvertible {
    case coreAudio(OSStatus, String)
    public var description: String {
        switch self {
        case let .coreAudio(status, what): return "Core Audio error \(status) while \(what)"
        }
    }
}

/// Watches Core Audio's process objects and publishes grouped rows. Event-driven only: no timers.
public final class ProcessRegistry {
    private let queue: DispatchQueue
    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private var systemListener: AudioObjectPropertyListenerBlock?
    private var processListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var identityCache: [pid_t: ResolvedIdentity] = [:]
    private var started = false
    private let queueKey = DispatchSpecificKey<Bool>()

    /// Called on `queue` whenever the grouped rows change (and once after start).
    public var onChange: (([AudioApp]) -> Void)?
    public private(set) var apps: [AudioApp] = []

    public init(queue: DispatchQueue) {
        self.queue = queue
        queue.setSpecific(key: queueKey, value: true)
    }

    deinit { stop() }

    /// Runs `body` on the registry queue, synchronously, without deadlocking if already on it.
    private func onQueue(_ body: () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) == true { body() } else { queue.sync(execute: body) }
    }

    public func start() throws {
        var failure: RegistryError?
        onQueue {
            var address = Self.processListAddress
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.refreshLocked(force: false)
            }
            let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
            guard status == noErr else { failure = RegistryError.coreAudio(status, "adding the process list listener"); return }
            systemListener = block
            started = true
            refreshLocked(force: true)
        }
        if let failure { throw failure }
    }

    public func stop() { onQueue { stopLocked() } }

    private func stopLocked() {
        if let block = systemListener {
            var address = Self.processListAddress
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
            systemListener = nil
        }
        for (object, block) in processListeners {
            var address = Self.runningAddress
            AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
        }
        processListeners.removeAll()
        started = false
    }

    /// Re-read everything now; fires onChange only if the rows changed. Safe from any thread.
    public func refresh() {
        queue.async { [weak self] in self?.refreshLocked(force: false) }
    }

    // MARK: - internals (all on `queue`)

    private func refreshLocked(force: Bool) {
        guard started else { return }
        let objects = (try? Self.readProcessObjectList()) ?? []
        var processes: [AudioProcess] = []
        processes.reserveCapacity(objects.count)
        for object in objects {
            guard let pid = Self.readPID(object) else { continue }
            processes.append(AudioProcess(objectID: object,
                                          pid: pid,
                                          bundleID: Self.readBundleID(object),
                                          isRunningOutput: Self.readIsRunningOutput(object),
                                          devices: Self.readDevices(object)))
        }
        syncProcessListeners(current: Set(objects))
        let livePIDs = Set(processes.map { $0.pid })
        identityCache = identityCache.filter { livePIDs.contains($0.key) }
        let rows = Grouping.group(processes, excludingPIDs: [ownPID]) { pid, hint in
            if let cached = identityCache[pid] { return cached }
            let resolved = AppIdentity.resolve(pid: pid, bundleIDHint: hint)
            identityCache[pid] = resolved
            return resolved
        }
        if force || !Grouping.sameRows(rows, apps) {
            apps = rows
            onChange?(rows)
        }
    }

    private func syncProcessListeners(current: Set<AudioObjectID>) {
        for (object, block) in processListeners where !current.contains(object) {
            var address = Self.runningAddress
            AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
            processListeners[object] = nil
        }
        // macOS 26.6 delivers change events for kAudioProcessPropertyIsRunning but not for
        // IsRunningOutput (verified with a listener probe), so listen to IsRunning and re-read the
        // output flag on every event.
        for object in current where processListeners[object] == nil {
            var address = Self.runningAddress
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.refreshLocked(force: false)
            }
            if AudioObjectAddPropertyListenerBlock(object, &address, queue, block) == noErr {
                processListeners[object] = block
            }
        }
    }

    // MARK: - Core Audio property reads

    static let processListAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    static let runningOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioProcessPropertyIsRunningOutput,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    static let runningAddress = AudioObjectPropertyAddress(
        mSelector: kAudioProcessPropertyIsRunning,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    static func readProcessObjectList() throws -> [AudioObjectID] {
        var address = processListAddress
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        var status = AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size)
        guard status == noErr else { throw RegistryError.coreAudio(status, "sizing the process list") }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var list = [AudioObjectID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(system, &address, 0, nil, &size, &list)
        guard status == noErr else { throw RegistryError.coreAudio(status, "reading the process list") }
        return Array(list.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    static func readPID(_ object: AudioObjectID) -> pid_t? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var pid: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &pid)
        return status == noErr ? pid : nil
    }

    static func readBundleID(_ object: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>? = nil
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let string = value?.takeRetainedValue() as String? else { return nil }
        return string.isEmpty ? nil : string
    }

    static func readDevices(_ object: AudioObjectID) -> [AudioObjectID] {
        HAL.readObjectIDs(object, kAudioProcessPropertyDevices) ?? []
    }

    static func readIsRunningOutput(_ object: AudioObjectID) -> Bool {
        var address = runningOutputAddress
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        return status == noErr && value != 0
    }
}
