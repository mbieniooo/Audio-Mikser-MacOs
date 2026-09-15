import Foundation
import CoreAudio
import MikserCore

let args = CommandLine.arguments

if args.contains("--live-registry") {
    let queue = DispatchQueue(label: "mikser.selftest.registry")
    let registry = ProcessRegistry(queue: queue)
    let done = DispatchSemaphore(value: 0)
    var snapshot: [AudioApp] = []
    registry.onChange = { rows in snapshot = rows }
    do { try registry.start() } catch { print("start failed: \(error)"); exit(1) }
    _ = done.wait(timeout: .now() + 2)
    queue.sync {
        for app in snapshot {
            let mark = (app.isPlaying ? "P" : " ") + (app.isUserFacing ? "U" : " ")
            print("\(mark) \(app.displayName) [\(app.id.raw)] pids=\(app.pids) bundle=\(app.bundleID ?? "-")")
        }
        print("\(snapshot.count) rows")
    }
    registry.stop()
    exit(0)
}

if let i = args.firstIndex(of: "--watch"), args.count > i + 2, let pid = pid_t(args[i + 1]), let secs = Double(args[i + 2]) {
    // Polls one process's HAL "running output" flag every 2 ms and prints each transition.
    var pidCopy = pid
    var addr = HAL.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
    var object = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let st = withUnsafePointer(to: &pidCopy) { AudioObjectGetPropertyData(HAL.system, &addr, UInt32(MemoryLayout<pid_t>.size), $0, &size, &object) }
    guard st == noErr, object != kAudioObjectUnknown else { print("no process object for pid \(pid): \(HAL.describe(st))"); exit(1) }
    let start = Date()
    var last: UInt32? = nil
    var flips = 0
    while Date().timeIntervalSince(start) < secs {
        let v = HAL.readUInt32(object, kAudioProcessPropertyIsRunningOutput) ?? 99
        if v != last {
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            print("t=\(ms)ms runningOutput=\(v)")
            if last != nil { flips += 1 }
            last = v
        }
        usleep(2000)
    }
    print("flips=\(flips)")
    exit(0)
}

if let i = args.firstIndex(of: "--listen-all"), args.count > i + 1, let secs = Double(args[i + 1]) {
    // Mimics ProcessRegistry's listeners and prints every event: process list changes and, per
    // process object, IsRunningOutput / IsRunning changes. Tells whether the HAL delivers them.
    let q = DispatchQueue(label: "probe")
    let start = Date()
    func stamp() -> String { "t=\(Int(Date().timeIntervalSince(start) * 1000))ms" }
    var known: Set<AudioObjectID> = []
    var blocks: [AudioObjectPropertyListenerBlock] = []
    func watch(_ obj: AudioObjectID) {
        for (name, sel) in [("IsRunningOutput", kAudioProcessPropertyIsRunningOutput), ("IsRunning", kAudioProcessPropertyIsRunning)] {
            var a = HAL.address(sel)
            let b: AudioObjectPropertyListenerBlock = { _, _ in
                let v = HAL.readUInt32(obj, sel) ?? 99
                print("\(stamp()) event \(name) obj=\(obj) pid=\(HAL.readUInt32(obj, kAudioProcessPropertyPID) ?? 0) value=\(v)")
            }
            let st = AudioObjectAddPropertyListenerBlock(obj, &a, q, b)
            if st != noErr { print("\(stamp()) add listener \(name) obj=\(obj) failed \(HAL.describe(st))") }
            blocks.append(b)
        }
    }
    func sync() {
        let now = Set(HAL.readObjectIDs(HAL.system, kAudioHardwarePropertyProcessObjectList) ?? [])
        for o in now.subtracting(known) {
            let pid = HAL.readUInt32(o, kAudioProcessPropertyPID) ?? 0
            let ro = HAL.readUInt32(o, kAudioProcessPropertyIsRunningOutput) ?? 99
            print("\(stamp()) list: added obj=\(o) pid=\(pid) runningOutput=\(ro)")
            watch(o)
        }
        for o in known.subtracting(now) { print("\(stamp()) list: removed obj=\(o)") }
        known = now
    }
    var la = HAL.address(kAudioHardwarePropertyProcessObjectList)
    let lb: AudioObjectPropertyListenerBlock = { _, _ in sync() }
    _ = AudioObjectAddPropertyListenerBlock(HAL.system, &la, q, lb)
    q.sync { sync(); print("\(stamp()) listening: \(known.count) process objects") }
    Thread.sleep(forTimeInterval: secs)
    q.sync { print("\(stamp()) done") }
    exit(0)
}

if args.contains("--taps") {
    print("global taps visible to this process: \(HAL.tapList().count)")
    print("Mikser aggregate devices visible: \(HAL.mikserDeviceNames())")
    print("default output: \(HAL.defaultOutputDevice().flatMap { HAL.deviceName($0) } ?? "-")")
    exit(0)
}

let h = Harness()

h.suite("Types") { h in
    h.check("AppLevel clamps", AppLevel(level: 1.7, muted: false).level == 1)
    h.check("AppLevel.full is full", AppLevel.full.isFull)
    h.check("muted is not full", !AppLevel(level: 1, muted: true).isFull)
    h.check("muted gain is 0", AppLevel(level: 0.5, muted: true).effectiveGain == 0)
}

groupingSuite(h)
gainSuite(h)
settingsSuite(h)
modelSuite(h)
reviewFixSuite(h)

h.finish()
