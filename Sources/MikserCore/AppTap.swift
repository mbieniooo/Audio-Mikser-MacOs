import Foundation
import CoreAudio
import AudioToolbox
import Synchronization

public enum TapError: Error, CustomStringConvertible {
    case coreAudio(OSStatus, String)
    case notReady(String)
    public var description: String {
        switch self {
        case let .coreAudio(status, what): return "\(what): Core Audio error \(HAL.describe(status))"
        case let .notReady(what): return what
        }
    }
}

/// State shared between the control side and the HAL IO thread. Every field is an atomic read and
/// written with relaxed ordering: each value stands on its own, there is no cross-field invariant.
struct TapSharedState: ~Copyable {
    let target = Atomic<Float>(1)
    let current = Atomic<Float>(1)
    let peakIn = Atomic<Float>(0)
    let peakOut = Atomic<Float>(0)
    let ramp = Atomic<Float>(1)
    let callbacks = Atomic<UInt64>(0)
    let lastCallback = Atomic<UInt64>(0)
    let firstCallback = Atomic<UInt64>(0)
    let lastSignal = Atomic<UInt64>(0)
    let targetChanged = Atomic<UInt64>(0)
}

/// The HAL IO callback: a C function with no closure context, so nothing is retained, released or
/// allocated on the IO thread. `clientData` is the tap's shared state.
private let mikserIOProc: AudioDeviceIOProc = { _, _, input, _, output, _, clientData in
    guard let clientData else { return noErr }
    AppTap.render(input: input, output: output, state: clientData.assumingMemoryBound(to: TapSharedState.self))
    return noErr
}

/// One app's scaling path: a process tap that mutes the app's direct output, a private aggregate
/// device on the current default output, and an IO proc that re-renders the tapped audio with a
/// ramped gain. Teardown restores the app's normal audio.
public final class AppTap {
    let key: AppGroupKey
    /// The app's process objects as the registry reported them (used to detect process-set changes).
    let requestedObjectIDs: [AudioObjectID]
    /// The subset that was alive when the tap was created (what the tap actually covers).
    let processObjectIDs: [AudioObjectID]
    let outputDeviceID: AudioObjectID
    let outputUID: String
    let createdAt = Date()
    private(set) var tapID = AudioObjectID(kAudioObjectUnknown)
    private(set) var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private(set) var sampleRate: Double = 0
    private(set) var bufferFrames: UInt32 = 0
    private(set) var activatedAt: UInt64 = 0
    private let state: UnsafeMutablePointer<TapSharedState>

    /// `startSilent` makes the path fade in from zero (used when it replaces an older path that is
    /// fading out); otherwise it starts at the target so a muted app never leaks its first 30 ms.
    public init(key: AppGroupKey, requestedObjectIDs: [AudioObjectID], processObjectIDs: [AudioObjectID],
                outputDeviceID: AudioObjectID, outputUID: String, target: Float, startSilent: Bool = false) {
        self.key = key
        self.requestedObjectIDs = requestedObjectIDs
        self.processObjectIDs = processObjectIDs
        self.outputDeviceID = outputDeviceID
        self.outputUID = outputUID
        state = .allocate(capacity: 1)
        state.initialize(to: TapSharedState())
        let clamped = max(0, min(1, target))
        state.pointee.target.store(clamped, ordering: .relaxed)
        state.pointee.current.store(startSilent ? 0 : clamped, ordering: .relaxed)
    }

    deinit {
        teardown()
        state.deinitialize(count: 1)
        state.deallocate()
    }

    public var target: Float {
        get { state.pointee.target.load(ordering: .relaxed) }
        set {
            state.pointee.target.store(max(0, min(1, newValue)), ordering: .relaxed)
            state.pointee.targetChanged.store(mach_absolute_time(), ordering: .relaxed)
        }
    }
    public var currentGain: Float { state.pointee.current.load(ordering: .relaxed) }
    var peakIn: Float { state.pointee.peakIn.load(ordering: .relaxed) }
    var peakOut: Float { state.pointee.peakOut.load(ordering: .relaxed) }
    var callbacks: UInt64 { state.pointee.callbacks.load(ordering: .relaxed) }
    var lastCallbackHostTime: UInt64 { state.pointee.lastCallback.load(ordering: .relaxed) }
    var firstCallbackHostTime: UInt64 { state.pointee.firstCallback.load(ordering: .relaxed) }
    var lastSignalHostTime: UInt64 { state.pointee.lastSignal.load(ordering: .relaxed) }
    var targetChangedHostTime: UInt64 { state.pointee.targetChanged.load(ordering: .relaxed) }
    var isActive: Bool { procID != nil }
    var isAlive: Bool { aggregateID != kAudioObjectUnknown && HAL.isAlive(aggregateID) }

    /// True when the tap carried signal above -80 dB within the last `ms` milliseconds.
    public func hadSignal(withinMs ms: Double, now: UInt64 = mach_absolute_time()) -> Bool {
        let last = lastSignalHostTime
        guard last != 0 else { return false }
        return HAL.msBetween(last, now) < ms
    }

    func activate() throws {
        let description = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        description.uuid = UUID()
        description.name = "Mikser:\(key.raw)"
        description.muteBehavior = .mutedWhenTapped
        description.isPrivate = true
        description.isExclusive = false
        description.isMixdown = true

        var tap = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &tap), "creating the process tap")
        guard tap != kAudioObjectUnknown else { throw TapError.notReady("the process tap came back with no id") }
        tapID = tap

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Mikser \(key.raw)",
            kAudioAggregateDeviceUIDKey: "com.mieszko.mikser.aggregate." + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceClockDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        do {
            try check(AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregate), "creating the aggregate device")
        } catch { teardown(); throw error }
        aggregateID = aggregate

        // The aggregate can take a moment to publish its streams; bounded wait, never a periodic timer.
        var ready = false
        for _ in 0..<20 {
            if HAL.isAlive(aggregateID),
               HAL.readASBD(aggregateID, kAudioDevicePropertyStreamFormat, scope: kAudioDevicePropertyScopeOutput) != nil {
                ready = true
                break
            }
            usleep(50_000)
        }
        guard ready else { teardown(); throw TapError.notReady("the aggregate device did not become ready within 1 s") }

        // Only Float32 PCM is rendered; anything else is refused so the fail safe restores the app
        // instead of a passthrough that would ignore the gain and the mute.
        guard let format = HAL.readASBD(aggregateID, kAudioDevicePropertyStreamFormat, scope: kAudioDevicePropertyScopeOutput),
              format.mFormatID == kAudioFormatLinearPCM, (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0,
              format.mBitsPerChannel == 32 else {
            teardown()
            throw TapError.notReady("the output stream is not Float32 PCM")
        }
        sampleRate = HAL.nominalSampleRate(aggregateID) ?? 48_000
        bufferFrames = HAL.bufferFrameSize(aggregateID) ?? 0
        state.pointee.ramp.store(GainMath.rampCoefficient(sampleRate: sampleRate), ordering: .relaxed)

        GainMath.warmUp() // touch the render code once here, so the first IO callback meets no lazy runtime work

        var proc: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcID(aggregateID, mikserIOProc, UnsafeMutableRawPointer(state), &proc)
        guard status == noErr, let created = proc else { teardown(); throw TapError.coreAudio(status, "creating the IO proc") }
        procID = created
        do { try check(AudioDeviceStart(aggregateID, created), "starting the aggregate device") } catch { teardown(); throw error }
        activatedAt = mach_absolute_time()
    }

    func invalidate() { teardown() }

    /// HAL-required order: stop → destroy IO proc → destroy aggregate → destroy tap.
    private func teardown() {
        if aggregateID != kAudioObjectUnknown {
            if let proc = procID {
                AudioDeviceStop(aggregateID, proc)
                AudioDeviceDestroyIOProcID(aggregateID, proc)
                procID = nil
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private func check(_ status: OSStatus, _ what: String) throws {
        guard status == noErr else { throw TapError.coreAudio(status, what) }
    }

    // MARK: - Real-time path. No allocation, no locks, no Objective-C, no logging, no `self`.

    static func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>,
                       state: UnsafeMutablePointer<TapSharedState>) {
        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outList = UnsafeMutableAudioBufferListPointer(output)
        let now = mach_absolute_time()
        state.pointee.callbacks.wrappingAdd(1, ordering: .relaxed)
        state.pointee.lastCallback.store(now, ordering: .relaxed)
        if state.pointee.firstCallback.load(ordering: .relaxed) == 0 { state.pointee.firstCallback.store(now, ordering: .relaxed) }
        let r = GainMath.mixLists(input: inList, output: outList,
                                  gain: state.pointee.current.load(ordering: .relaxed),
                                  target: state.pointee.target.load(ordering: .relaxed),
                                  ramp: state.pointee.ramp.load(ordering: .relaxed))
        state.pointee.current.store(r.gain, ordering: .relaxed)
        state.pointee.peakIn.store(r.peakIn, ordering: .relaxed)
        state.pointee.peakOut.store(r.peakOut, ordering: .relaxed)
        if r.peakIn > 1e-4 { state.pointee.lastSignal.store(now, ordering: .relaxed) }
    }
}
