import Foundation
import CoreAudio
import AudioToolbox

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

/// One app's scaling path: a process tap that mutes the app's direct output, a private aggregate
/// device on the current default output, and an IO proc that re-renders the tapped audio with a
/// ramped gain. Teardown restores the app's normal audio.
final class AppTap {
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
    private let ioQueue: DispatchQueue
    private(set) var sampleRate: Double = 0
    private(set) var bufferFrames: UInt32 = 0
    private(set) var isFloat32 = true
    private(set) var activatedAt: UInt64 = 0

    // Shared with the real-time thread. Aligned 32/64-bit loads and stores are atomic on Apple
    // silicon; the IO block only ever sees these raw pointers, never `self`.
    // floats: 0 target, 1 current, 2 peakIn, 3 peakOut, 4 ramp
    // counters: 0 callbacks, 1 last host time, 2 first host time, 3 last host time with signal above -80 dB.
    private let floats: UnsafeMutablePointer<Float>
    private let counters: UnsafeMutablePointer<UInt64>

    init(key: AppGroupKey, requestedObjectIDs: [AudioObjectID], processObjectIDs: [AudioObjectID],
         outputDeviceID: AudioObjectID, outputUID: String, target: Float) {
        self.key = key
        self.requestedObjectIDs = requestedObjectIDs
        self.processObjectIDs = processObjectIDs
        self.outputDeviceID = outputDeviceID
        self.outputUID = outputUID
        floats = .allocate(capacity: 5)
        floats.initialize(repeating: 0, count: 5)
        floats[0] = max(0, min(1, target))
        // A new tap is a new path: start at the target so a muted app never leaks its first 30 ms.
        floats[1] = floats[0]
        counters = .allocate(capacity: 4)
        counters.initialize(repeating: 0, count: 4)
        ioQueue = DispatchQueue(label: "com.mieszko.mikser.io", qos: .userInteractive)
    }

    deinit {
        teardown()
        floats.deallocate()
        counters.deallocate()
    }

    var target: Float {
        get { floats[0] }
        set { floats[0] = max(0, min(1, newValue)) }
    }
    var currentGain: Float { floats[1] }
    var peakIn: Float { floats[2] }
    var peakOut: Float { floats[3] }
    var callbacks: UInt64 { counters[0] }
    var lastCallbackHostTime: UInt64 { counters[1] }
    var firstCallbackHostTime: UInt64 { counters[2] }
    var lastSignalHostTime: UInt64 { counters[3] }
    var isActive: Bool { procID != nil }
    var isAlive: Bool { aggregateID != kAudioObjectUnknown && HAL.isAlive(aggregateID) }

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

        sampleRate = HAL.nominalSampleRate(aggregateID) ?? 48_000
        bufferFrames = HAL.bufferFrameSize(aggregateID) ?? 0
        floats[4] = GainMath.rampCoefficient(sampleRate: sampleRate)
        if let format = HAL.readASBD(aggregateID, kAudioDevicePropertyStreamFormat, scope: kAudioDevicePropertyScopeOutput) {
            isFloat32 = format.mFormatID == kAudioFormatLinearPCM
                && (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0
                && format.mBitsPerChannel == 32
        }

        let floats = self.floats, counters = self.counters, float32 = isFloat32
        var proc: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregateID, ioQueue) { _, input, _, output, _ in
            AppTap.render(input: input, output: output, floats: floats, counters: counters, isFloat32: float32)
        }
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

    private static func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>,
                               floats: UnsafeMutablePointer<Float>, counters: UnsafeMutablePointer<UInt64>, isFloat32: Bool) {
        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outList = UnsafeMutableAudioBufferListPointer(output)
        counters[0] &+= 1
        counters[1] = mach_absolute_time()
        if counters[2] == 0 { counters[2] = counters[1] }
        guard isFloat32 else { GainMath.passthrough(input: inList, output: outList); return }
        let r = GainMath.mixLists(input: inList, output: outList, gain: floats[1], target: floats[0], ramp: floats[4])
        floats[1] = r.gain
        floats[2] = r.peakIn
        floats[3] = r.peakOut
        if r.peakIn > 1e-4 { counters[3] = counters[1] }
    }
}
