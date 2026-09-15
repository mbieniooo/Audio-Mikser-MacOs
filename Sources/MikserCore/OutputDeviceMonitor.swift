import Foundation
import CoreAudio
import AppKit

/// Tracks the system default output device, its sample rate, and wake from sleep. Event-driven only.
public final class OutputDeviceMonitor {
    private let queue: DispatchQueue
    private var defaultListener: AudioObjectPropertyListenerBlock?
    private var rateListener: AudioObjectPropertyListenerBlock?
    private var listenedDevice = AudioObjectID(kAudioObjectUnknown)
    private var wakeObserver: NSObjectProtocol?
    private var started = false
    private let queueKey = DispatchSpecificKey<Bool>()

    public private(set) var deviceID = AudioObjectID(kAudioObjectUnknown)
    public private(set) var deviceUID: String?
    public private(set) var deviceName: String?
    public private(set) var sampleRate: Double = 0
    /// Called on `queue` with a short reason whenever the output changed, its rate changed, or the Mac woke.
    public var onChange: ((String) -> Void)?

    public init(queue: DispatchQueue) {
        self.queue = queue
        queue.setSpecific(key: queueKey, value: true)
    }
    deinit { stop() }

    public func start() throws {
        var failure: RegistryError?
        let body = {
            var addr = HAL.address(kAudioHardwarePropertyDefaultOutputDevice)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.refresh(reason: "default output changed") }
            let status = AudioObjectAddPropertyListenerBlock(HAL.system, &addr, self.queue, block)
            guard status == noErr else { failure = RegistryError.coreAudio(status, "adding the default output listener"); return }
            self.defaultListener = block
            self.wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
                guard let self else { return }
                self.queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.refresh(reason: "wake", always: true) }
            }
            self.started = true
            self.readDevice()
            self.relisten()
        }
        if DispatchQueue.getSpecific(key: queueKey) == true { body() } else { queue.sync(execute: body) }
        if let failure { throw failure }
    }

    public func stop() {
        if DispatchQueue.getSpecific(key: queueKey) == true { stopLocked() } else { queue.sync { stopLocked() } }
    }

    private func stopLocked() {
        if let block = defaultListener {
            var addr = HAL.address(kAudioHardwarePropertyDefaultOutputDevice)
            AudioObjectRemovePropertyListenerBlock(HAL.system, &addr, queue, block)
            defaultListener = nil
        }
        if let block = rateListener, listenedDevice != kAudioObjectUnknown {
            var addr = HAL.address(kAudioDevicePropertyNominalSampleRate)
            AudioObjectRemovePropertyListenerBlock(listenedDevice, &addr, queue, block)
        }
        rateListener = nil
        listenedDevice = AudioObjectID(kAudioObjectUnknown)
        if let o = wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(o); wakeObserver = nil }
        started = false
    }

    private func readDevice() {
        deviceID = HAL.defaultOutputDevice() ?? AudioObjectID(kAudioObjectUnknown)
        deviceUID = deviceID == kAudioObjectUnknown ? nil : HAL.deviceUID(deviceID)
        deviceName = deviceID == kAudioObjectUnknown ? nil : HAL.deviceName(deviceID)
        sampleRate = HAL.nominalSampleRate(deviceID) ?? 0
    }

    /// On `queue`. Re-reads the device; notifies when something changed (or always, for wake).
    private func refresh(reason: String, always: Bool = false) {
        guard started else { return }
        let before = (deviceID, deviceUID, sampleRate)
        readDevice()
        relisten()
        let changed = before.0 != deviceID || before.1 != deviceUID || before.2 != sampleRate
        if changed || always { onChange?(reason) }
    }

    private func relisten() {
        guard listenedDevice != deviceID else { return }
        if let block = rateListener, listenedDevice != kAudioObjectUnknown {
            var addr = HAL.address(kAudioDevicePropertyNominalSampleRate)
            AudioObjectRemovePropertyListenerBlock(listenedDevice, &addr, queue, block)
            rateListener = nil
        }
        listenedDevice = deviceID
        guard deviceID != kAudioObjectUnknown else { return }
        var addr = HAL.address(kAudioDevicePropertyNominalSampleRate)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.refresh(reason: "sample rate changed") }
        if AudioObjectAddPropertyListenerBlock(deviceID, &addr, queue, block) == noErr { rateListener = block }
    }
}
