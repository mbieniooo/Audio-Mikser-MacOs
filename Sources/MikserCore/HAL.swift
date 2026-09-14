import Foundation
import CoreAudio

/// Thin, typed readers over the Core Audio HAL property API.
public enum HAL {
    public static let system = AudioObjectID(kAudioObjectSystemObject)

    public static func address(_ selector: AudioObjectPropertySelector,
                               scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                               element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    @discardableResult
    public static func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                               scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                               into value: inout T) -> OSStatus {
        var addr = address(selector, scope: scope)
        var size = UInt32(MemoryLayout<T>.size)
        return withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0) }
    }

    public static func readUInt32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                  scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var v: UInt32 = 0
        return read(object, selector, scope: scope, into: &v) == noErr ? v : nil
    }

    public static func readFloat64(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                   scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> Double? {
        var v: Float64 = 0
        return read(object, selector, scope: scope, into: &v) == noErr ? v : nil
    }

    public static func readObjectID(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> AudioObjectID? {
        var v = AudioObjectID(kAudioObjectUnknown)
        guard read(object, selector, into: &v) == noErr, v != kAudioObjectUnknown else { return nil }
        return v
    }

    public static func readString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                  scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> String? {
        var addr = address(selector, scope: scope)
        var value: Unmanaged<CFString>? = nil
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0) }
        guard status == noErr, let s = value?.takeRetainedValue() as String? else { return nil }
        return s.isEmpty ? nil : s
    }

    public static func readObjectIDs(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID]? {
        var addr = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr else { return nil }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var list = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &list) == noErr else { return nil }
        return Array(list.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    public static func readASBD(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope) -> AudioStreamBasicDescription? {
        var v = AudioStreamBasicDescription()
        return read(object, selector, scope: scope, into: &v) == noErr ? v : nil
    }

    // MARK: devices

    public static func defaultOutputDevice() -> AudioObjectID? { readObjectID(system, kAudioHardwarePropertyDefaultOutputDevice) }
    public static func deviceUID(_ device: AudioObjectID) -> String? { readString(device, kAudioDevicePropertyDeviceUID) }
    public static func deviceName(_ device: AudioObjectID) -> String? { readString(device, kAudioObjectPropertyName) }
    public static func nominalSampleRate(_ device: AudioObjectID) -> Double? { readFloat64(device, kAudioDevicePropertyNominalSampleRate) }
    public static func bufferFrameSize(_ device: AudioObjectID) -> UInt32? { readUInt32(device, kAudioDevicePropertyBufferFrameSize) }
    public static func isAlive(_ device: AudioObjectID) -> Bool { (readUInt32(device, kAudioDevicePropertyDeviceIsAlive) ?? 0) != 0 }
    public static func tapList() -> [AudioObjectID] { readObjectIDs(system, kAudioHardwarePropertyTapList) ?? [] }

    public static func fourCC(_ status: OSStatus) -> String {
        let bytes = withUnsafeBytes(of: status.bigEndian) { Array($0) }
        let printable = bytes.allSatisfy { (32...126).contains($0) }
        return printable ? String(bytes.map { Character(UnicodeScalar($0)) }) : String(status)
    }

    public static func describe(_ status: OSStatus) -> String { "\(status) (\(fourCC(status)))" }
}
