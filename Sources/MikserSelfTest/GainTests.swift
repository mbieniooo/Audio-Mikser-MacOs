import Foundation
import CoreAudio
import MikserCore

/// Owns an AudioBufferList plus its sample storage for tests.
final class BufferListBox {
    let list: UnsafeMutableAudioBufferListPointer
    private var storage: [UnsafeMutablePointer<Float>] = []
    let shapes: [(channels: Int, samples: Int)]

    init(_ shapes: [(channels: Int, samples: Int)]) {
        self.shapes = shapes
        list = AudioBufferList.allocate(maximumBuffers: max(1, shapes.count))
        list.count = shapes.count
        for (i, s) in shapes.enumerated() {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: s.samples)
            p.initialize(repeating: 0, count: s.samples)
            storage.append(p)
            list[i] = AudioBuffer(mNumberChannels: UInt32(s.channels), mDataByteSize: UInt32(s.samples * 4), mData: UnsafeMutableRawPointer(p))
        }
    }
    deinit {
        for p in storage { p.deallocate() }
        free(list.unsafeMutablePointer)
    }
    func fill(_ buffer: Int, _ values: [Float]) { for (i, v) in values.enumerated() { storage[buffer][i] = v } }
    func fill(_ buffer: Int, _ f: (Int) -> Float) { for i in 0..<shapes[buffer].samples { storage[buffer][i] = f(i) } }
    func samples(_ buffer: Int) -> [Float] { (0..<shapes[buffer].samples).map { storage[buffer][$0] } }
}

func gainSuite(_ h: Harness) {
    let sr = 48_000.0
    let ramp = GainMath.rampCoefficient(sampleRate: sr)

    h.suite("GainMath.rampCoefficient") { h in
        h.approx("48 kHz, 30 ms", Double(ramp), 1 - exp(-1.0 / (0.030 * sr)), tol: 1e-7)
        h.check("44.1 kHz ramps faster per sample", GainMath.rampCoefficient(sampleRate: 44_100) > ramp)
        h.check("degenerate sample rate snaps", GainMath.rampCoefficient(sampleRate: 0) == 1)
    }

    h.suite("GainMath ramp behaviour") { h in
        let frames = 512
        let input = BufferListBox([(2, frames * 2)]); input.fill(0) { _ in 1.0 }
        let output = BufferListBox([(2, frames * 2)])
        var g: Float = 1
        var r = GainMath.mixLists(input: input.list, output: output.list, gain: g, target: 0.2, ramp: ramp)
        let out = output.samples(0)
        var monotone = true
        var maxStep: Float = 0
        for f in 1..<frames {
            let a = out[(f - 1) * 2], b = out[f * 2]
            if b > a + 1e-7 { monotone = false }
            maxStep = max(maxStep, abs(a - b))
        }
        h.check("gain falls monotonically toward the target", monotone)
        h.check("no per-sample step larger than the one-pole allows", maxStep <= ramp * 0.8 + 1e-6, "max step \(maxStep), bound \(ramp * 0.8)")
        h.check("both channels get the same gain per frame", out[0] == out[1] && out[100] == out[101])
        h.approx("first sample already moved by one step", Double(out[0]), Double(1 - 0.8 * ramp), tol: 1e-6)
        g = r.gain
        var buffers = 1
        while buffers < 15 { r = GainMath.mixLists(input: input.list, output: output.list, gain: g, target: 0.2, ramp: ramp); g = r.gain; buffers += 1 }
        h.check("settled within 150 ms (7680 frames)", abs(g - 0.2) < 0.01, "gain \(g)")
        while buffers < 200 { r = GainMath.mixLists(input: input.list, output: output.list, gain: g, target: 0.2, ramp: ramp); g = r.gain; buffers += 1 }
        h.check("snaps exactly onto the target once converged", g == 0.2, "gain \(g)")
        h.approx("peak in is the input peak", Double(r.peakIn), 1.0, tol: 1e-6)
        h.approx("peak out is input peak times gain", Double(r.peakOut), 0.2, tol: 1e-6)
    }

    h.suite("GainMath steady gain and levels") { h in
        let frames = 480
        let input = BufferListBox([(2, frames * 2)])
        input.fill(0) { i in Float(0.5 * sin(2 * Double.pi * 440 * Double(i / 2) / sr)) }
        let output = BufferListBox([(2, frames * 2)])
        let r = GainMath.mixLists(input: input.list, output: output.list, gain: 0.2, target: 0.2, ramp: ramp)
        let inS = input.samples(0), outS = output.samples(0)
        var maxErr: Float = 0
        for i in 0..<inS.count { maxErr = max(maxErr, abs(outS[i] - inS[i] * 0.2)) }
        h.check("every sample is input times 0.2", maxErr < 1e-6, "max error \(maxErr)")
        h.approx("peak ratio out/in is the level", Double(r.peakOut / r.peakIn), 0.2, tol: 1e-5)
        let muteOut = BufferListBox([(2, frames * 2)])
        var g: Float = 0.2
        for _ in 0..<200 { g = GainMath.mixLists(input: input.list, output: muteOut.list, gain: g, target: 0, ramp: ramp).gain }
        h.check("target 0 converges to exact silence", g == 0 && muteOut.samples(0).allSatisfy { $0 == 0 })
    }

    h.suite("GainMath channel layouts") { h in
        let stereo = BufferListBox([(2, 8)]); stereo.fill(0, [0.4, 0.8, 0.4, 0.8, 0.4, 0.8, 0.4, 0.8])
        let mono = BufferListBox([(1, 4)])
        _ = GainMath.mixLists(input: stereo.list, output: mono.list, gain: 1, target: 1, ramp: ramp)
        h.check("stereo into mono averages each frame", mono.samples(0).allSatisfy { abs($0 - 0.6) < 1e-6 }, "\(mono.samples(0))")
        let monoIn = BufferListBox([(1, 4)]); monoIn.fill(0, [0.3, 0.3, 0.3, 0.3])
        let stereoOut = BufferListBox([(2, 8)])
        _ = GainMath.mixLists(input: monoIn.list, output: stereoOut.list, gain: 1, target: 1, ramp: ramp)
        h.check("mono into stereo duplicates", stereoOut.samples(0).allSatisfy { abs($0 - 0.3) < 1e-6 })

        let planar = BufferListBox([(1, 4), (1, 4)]); planar.fill(0, [1, 2, 3, 4]); planar.fill(1, [10, 20, 30, 40])
        let inter = BufferListBox([(2, 8)])
        _ = GainMath.mixLists(input: planar.list, output: inter.list, gain: 0.5, target: 0.5, ramp: ramp)
        h.check("planar into interleaved keeps frames aligned", inter.samples(0) == [0.5, 5, 1, 10, 1.5, 15, 2, 20], "\(inter.samples(0))")

        let inter2 = BufferListBox([(2, 8)]); inter2.fill(0, [1, 10, 2, 20, 3, 30, 4, 40])
        let planar2 = BufferListBox([(1, 4), (1, 4)])
        _ = GainMath.mixLists(input: inter2.list, output: planar2.list, gain: 1, target: 1, ramp: ramp)
        h.check("interleaved into planar splits channels", planar2.samples(0) == [1, 2, 3, 4] && planar2.samples(1) == [10, 20, 30, 40])

        let short = BufferListBox([(2, 4)]); short.fill(0, [1, 1, 1, 1])
        let long = BufferListBox([(2, 8)]); long.fill(0) { _ in 7 }
        _ = GainMath.mixLists(input: short.list, output: long.list, gain: 1, target: 1, ramp: ramp)
        h.check("unwritten output tail is zeroed", long.samples(0) == [1, 1, 1, 1, 0, 0, 0, 0], "\(long.samples(0))")

        let noInput = BufferListBox([]); let out = BufferListBox([(2, 4)]); out.fill(0) { _ in 9 }
        _ = GainMath.mixLists(input: noInput.list, output: out.list, gain: 1, target: 1, ramp: ramp)
        h.check("no input means silence, not garbage", out.samples(0).allSatisfy { $0 == 0 })

        let src = BufferListBox([(2, 4)]); src.fill(0, [1, 2, 3, 4]); let dst = BufferListBox([(2, 4)])
        GainMath.passthrough(input: src.list, output: dst.list)
        h.check("passthrough is bit-exact", dst.samples(0) == [1, 2, 3, 4])
    }

    h.suite("HAL on this machine") { h in
        let dev = HAL.defaultOutputDevice()
        h.check("default output device exists", dev != nil)
        if let dev {
            h.check("device has a UID", HAL.deviceUID(dev) != nil, HAL.deviceUID(dev) ?? "nil")
            h.check("device has a name", HAL.deviceName(dev) != nil, HAL.deviceName(dev) ?? "nil")
            h.check("sample rate is sane", (HAL.nominalSampleRate(dev) ?? 0) >= 8000)
            h.check("device is alive", HAL.isAlive(dev))
        }
        h.check("fourCC renders", HAL.fourCC(OSStatus(0x77686F3F)) == "who?")
    }
}
