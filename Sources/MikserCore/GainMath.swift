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

    /// Frame-wise ramped gain from one interleaved buffer into another, adapting channel counts:
    /// equal layouts copy 1:1, a mono output averages the frame, a wider output repeats the last input channel.
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
            } else if oc == 1 {
                var sum: Float = 0
                for c in 0..<ic { let x = input[ib + c]; sum += x; pin = max(pin, abs(x)) }
                let y = sum / Float(ic) * g
                output[ob] = y; pout = max(pout, abs(y))
            } else {
                // Wider output: a mono input feeds every channel; a multi-channel input feeds its own
                // channels and leaves the rest silent (never right into centre, LFE or surrounds).
                for c in 0..<oc {
                    let x: Float = ic == 1 ? input[ib] : (c < ic ? input[ib + c] : 0)
                    let y = x * g
                    output[ob + c] = y
                    pin = max(pin, abs(x)); pout = max(pout, abs(y))
                }
            }
        }
        if abs(g - target) < 1e-4 { g = target } // Float32 stalls ~3e-5 short; 1e-4 is -80 dB
        return Result(gain: g, peakIn: pin, peakOut: pout)
    }

    /// Whole buffer lists. Handles same-shape lists, planar input into an interleaved output,
    /// interleaved input into planar outputs, and anything else index-matched. Unwritten output is zeroed.
    public static func mixLists(input: UnsafeMutableAudioBufferListPointer,
                                output: UnsafeMutableAudioBufferListPointer,
                                gain start: Float, target: Float, ramp: Float) -> Result {
        let inCount = input.count, outCount = output.count
        guard outCount > 0 else { return Result(gain: start) }
        guard inCount > 0 else { silence(output); return Result(gain: start) }

        let inPlanar = inCount > 1 && input.allSatisfy { $0.mNumberChannels == 1 }
        let outPlanar = outCount > 1 && output.allSatisfy { $0.mNumberChannels == 1 }

        if inPlanar, outCount == 1, output[0].mNumberChannels > 1 {
            guard let out = output[0].mData?.assumingMemoryBound(to: Float.self) else { return Result(gain: start) }
            let oc = Int(output[0].mNumberChannels)
            var frames = sampleCount(output[0]) / oc
            for b in input { frames = min(frames, sampleCount(b)) }
            var g = start
            var pin: Float = 0, pout: Float = 0
            for f in 0..<frames {
                g += (target - g) * ramp
                for c in 0..<oc {
                    let source = inCount == 1 ? 0 : c
                    if source >= inCount { out[f * oc + c] = 0; continue }
                    guard let src = input[source].mData?.assumingMemoryBound(to: Float.self) else { continue }
                    let x = src[f], y = x * g
                    out[f * oc + c] = y
                    pin = max(pin, abs(x)); pout = max(pout, abs(y))
                }
            }
            zeroTail(output[0], from: frames * oc)
            if abs(g - target) < 1e-4 { g = target } // Float32 stalls ~3e-5 short; 1e-4 is -80 dB
            return Result(gain: g, peakIn: pin, peakOut: pout)
        }

        if outPlanar, inCount == 1, input[0].mNumberChannels > 1 {
            guard let src = input[0].mData?.assumingMemoryBound(to: Float.self) else { silence(output); return Result(gain: start) }
            let ic = Int(input[0].mNumberChannels)
            var frames = sampleCount(input[0]) / ic
            for b in output { frames = min(frames, sampleCount(b)) }
            var g = start
            var pin: Float = 0, pout: Float = 0
            for f in 0..<frames {
                g += (target - g) * ramp
                for c in 0..<outCount {
                    guard let out = output[c].mData?.assumingMemoryBound(to: Float.self) else { continue }
                    let x: Float = ic == 1 ? src[f] : (c < ic ? src[f * ic + c] : 0)
                    let y = x * g
                    out[f] = y
                    pin = max(pin, abs(x)); pout = max(pout, abs(y))
                }
            }
            for b in output { zeroTail(b, from: frames) }
            if abs(g - target) < 1e-4 { g = target } // Float32 stalls ~3e-5 short; 1e-4 is -80 dB
            return Result(gain: g, peakIn: pin, peakOut: pout)
        }

        var result = Result(gain: start)
        for i in 0..<outCount {
            let ob = output[i]
            guard let out = ob.mData?.assumingMemoryBound(to: Float.self) else { continue }
            guard i < inCount, let src = input[i].mData?.assumingMemoryBound(to: Float.self) else {
                zeroTail(ob, from: 0); continue
            }
            let ic = max(1, Int(input[i].mNumberChannels)), oc = max(1, Int(ob.mNumberChannels))
            let frames = min(sampleCount(input[i]) / ic, sampleCount(ob) / oc)
            let r = mixInterleaved(input: src, inChannels: ic, output: out, outChannels: oc,
                                   frames: frames, gain: start, target: target, ramp: ramp)
            zeroTail(ob, from: frames * oc)
            result.gain = r.gain
            result.peakIn = max(result.peakIn, r.peakIn)
            result.peakOut = max(result.peakOut, r.peakOut)
        }
        return result
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
