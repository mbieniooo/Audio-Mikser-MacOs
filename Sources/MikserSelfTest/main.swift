import Foundation
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

h.finish()
