import Foundation
import CoreAudio

/// Pure, allocation-free gain math for the real-time path. Tested without a HAL.
public enum GainMath {
    public struct Result {
        public var gain: Float
        public var peakIn: Float
        public var peakOut: Float
        public init(gain: Float, peakIn: Float = 0, peakOut: Float = 0) {
            self.gain = gain; self.peakIn = peakIn; self.peakOut = peakOut
        }
    }

    /// One-pole smoothing coefficient so a gain change settles in about `seconds`.
    public static func rampCoefficient(sampleRate: Double, seconds: Double = 0.030) -> Float {
        guard sampleRate > 0, seconds > 0 else { return 1 }
        return Float(1 - exp(-1 / (seconds * sampleRate)))
    }

    /// Channel rule shared by every layout: a mono input feeds every output channel, a mono output
    /// averages the input, otherwise channel c gets input channel c and channels past the input stay
    /// silent (never right into centre, LFE or surrounds).
    @inline(__always)
    static func mapped(_ read: (Int) -> Float, inChannels ic: Int, outChannel c: Int, outChannels oc: Int) -> Float {
        if ic == 1 { return read(0) }
        if oc == 1 {
            var sum: Float = 0
            for k in 0..<ic { sum += read(k) }
            return sum / Float(ic)
        }
        return c < ic ? read(c) : 0
    }

    /// Frame-wise ramped gain from one interleaved buffer into another, adapting channel counts.
    @inline(__always)
    public static func mixInterleaved(input: UnsafePointer<Float>, inChannels: Int,
                                      output: UnsafeMutablePointer<Float>, outChannels: Int,
                                      frames: Int, gain start: Float, target: Float, ramp: Float) -> Result {
        let ic = max(1, inChannels), oc = max(1, outChannels)
        var g = start
        var pin: Float = 0, pout: Float = 0
        for f in 0..<frames {
            g += (target - g) * ramp
            let ib = f * ic, ob = f * oc
            if ic == oc {
                for c in 0..<oc {
                    let x = input[ib + c], y = x * g
                    output[ob + c] = y
                    pin = max(pin, abs(x)); pout = max(pout, abs(y))
                }
            } else {
                for k in 0..<ic { pin = max(pin, abs(input[ib + k])) }
                for c in 0..<oc {
                    let x = mapped({ input[ib + $0] }, inChannels: ic, outChannel: c, outChannels: oc)
                    let y = x * g
                    output[ob + c] = y
                    pout = max(pout, abs(y))
                }
            }
        }
        if abs(g - target) < 1e-4 { g = target } // Float32 stalls ~3e-5 short; 1e-4 is -80 dB
        return Result(gain: g, peakIn: pin, peakOut: pout)
    }

    /// Whole buffer lists, any layout: interleaved or planar on either side, any channel counts.
    /// Identical interleaved shapes take the fast path; everything else goes through one general
    /// frame loop with the channel rule above. Unwritten output is zeroed.
    public static func mixLists(input: UnsafeMutableAudioBufferListPointer,
                                output: UnsafeMutableAudioBufferListPointer,
                                gain start: Float, target: Float, ramp: Float) -> Result {
        let inCount = input.count, outCount = output.count
        guard outCount > 0 else { return Result(gain: start) }
        guard inCount > 0 else { silence(output); return Result(gain: start) }

        let inPlanar = inCount > 1 && input.allSatisfy { $0.mNumberChannels == 1 }
        let outPlanar = outCount > 1 && output.allSatisfy { $0.mNumberChannels == 1 }
        let ic = max(1, inPlanar ? inCount : Int(input[0].mNumberChannels))
        let oc = max(1, outPlanar ? outCount : Int(output[0].mNumberChannels))

        if !inPlanar, !outPlanar, inCount == 1, outCount == 1 {
            guard let src = input[0].mData?.assumingMemoryBound(to: Float.self),
                  let out = output[0].mData?.assumingMemoryBound(to: Float.self) else { silence(output); return Result(gain: start) }
            let frames = min(sampleCount(input[0]) / ic, sampleCount(output[0]) / oc)
            let r = mixInterleaved(input: src, inChannels: ic, output: out, outChannels: oc,
                                   frames: frames, gain: start, target: target, ramp: ramp)
            zeroTail(output[0], from: frames * oc)
            return r
        }

        // General path. Frames = the shortest buffer on either side.
        var frames = Int.max
        if inPlanar { for b in input { frames = min(frames, sampleCount(b)) } } else { frames = min(frames, sampleCount(input[0]) / ic) }
        if outPlanar { for b in output { frames = min(frames, sampleCount(b)) } } else { frames = min(frames, sampleCount(output[0]) / oc) }
        if frames == Int.max { frames = 0 }

        var g = start
        var pin: Float = 0, pout: Float = 0
        for f in 0..<frames {
            g += (target - g) * ramp
            @inline(__always) func read(_ k: Int) -> Float {
                if inPlanar {
                    guard let p = input[k].mData?.assumingMemoryBound(to: Float.self) else { return 0 }
                    return p[f]
                }
                guard let p = input[0].mData?.assumingMemoryBound(to: Float.self) else { return 0 }
                return p[f * ic + k]
            }
            for k in 0..<ic { pin = max(pin, abs(read(k))) }
            for c in 0..<oc {
                let y = mapped(read, inChannels: ic, outChannel: c, outChannels: oc) * g
                pout = max(pout, abs(y))
                if outPlanar {
                    if let p = output[c].mData?.assumingMemoryBound(to: Float.self) { p[f] = y }
                } else if let p = output[0].mData?.assumingMemoryBound(to: Float.self) {
                    p[f * oc + c] = y
                }
            }
        }
        if outPlanar { for b in output { zeroTail(b, from: frames) } } else { zeroTail(output[0], from: frames * oc); for i in 1..<max(1, outCount) where i < outCount { zeroTail(output[i], from: 0) } }
        if abs(g - target) < 1e-4 { g = target }
        return Result(gain: g, peakIn: pin, peakOut: pout)
    }

    /// Runs the render code once on tiny buffers so lazy runtime work (type metadata, caches) happens
    /// off the IO thread. Called before the first IO callback.
    public static func warmUp() {
        let list = AudioBufferList.allocate(maximumBuffers: 2)
        defer { free(list.unsafeMutablePointer) }
        var a: [Float] = [0.1, 0.2, 0.3, 0.4], b: [Float] = [0, 0, 0, 0]
        a.withUnsafeMutableBufferPointer { ap in
            b.withUnsafeMutableBufferPointer { bp in
                list.count = 1
                list[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: 16, mData: UnsafeMutableRawPointer(ap.baseAddress))
                let out = AudioBufferList.allocate(maximumBuffers: 1)
                defer { free(out.unsafeMutablePointer) }
                out[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: 16, mData: UnsafeMutableRawPointer(bp.baseAddress))
                _ = mixLists(input: list, output: out, gain: 1, target: 0.5, ramp: 0.5)
                _ = mixLists(input: list, output: out, gain: 1, target: 0.5, ramp: 0.5)
            }
        }
    }

    /// Bit-exact copy for unexpected stream formats: no gain, no reinterpretation.
    public static func passthrough(input: UnsafeMutableAudioBufferListPointer, output: UnsafeMutableAudioBufferListPointer) {
        for i in 0..<output.count {
            let ob = output[i]
            guard let out = ob.mData else { continue }
            let outBytes = Int(ob.mDataByteSize)
            guard i < input.count, let src = input[i].mData else { memset(out, 0, outBytes); continue }
            let n = min(Int(input[i].mDataByteSize), outBytes)
            memcpy(out, src, n)
            if n < outBytes { memset(out.advanced(by: n), 0, outBytes - n) }
        }
    }

    public static func silence(_ output: UnsafeMutableAudioBufferListPointer) {
        for b in output { zeroTail(b, from: 0) }
    }

    @inline(__always) static func sampleCount(_ b: AudioBuffer) -> Int { Int(b.mDataByteSize) / MemoryLayout<Float>.size }

    @inline(__always) static func zeroTail(_ b: AudioBuffer, from sample: Int) {
        guard let p = b.mData?.assumingMemoryBound(to: Float.self) else { return }
        let n = sampleCount(b)
        if sample < n { p.advanced(by: sample).update(repeating: 0, count: n - sample) }
    }
}
