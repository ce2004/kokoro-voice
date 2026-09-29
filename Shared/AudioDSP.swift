import Accelerate
import Foundation

/// Time-stretch, pitch-shift and level handling for Kokoro's 24 kHz output.
public enum AudioDSP {
    /// Kokoro's own speed input sounds natural up to about here. Faster
    /// requests use Kokoro at this speed and WSOLA for the rest.
    public static let maxModelSpeed: Double = 1.6
    public static let minModelSpeed: Double = 0.6
    /// Beyond this WSOLA has to skip so much that speech stops being words.
    public static let maxRate: Double = 6.0

    /// Split a requested speaking-rate multiplier into Kokoro's speed and the
    /// remaining tempo change done by WSOLA.
    public static func split(rate requested: Double) -> (modelSpeed: Double, stretch: Double) {
        let rate = min(max(requested, 0.3), maxRate)
        let model = min(max(rate, minModelSpeed), maxModelSpeed)
        return (model, rate / model)
    }

    /// Apply the post-model part of a prosody: tempo (WSOLA, pitch kept),
    /// pitch (WSOLA + resample, duration kept) and volume.
    public static func process(_ samples: [Float], tempo: Double, pitch: Double, volume: Double) -> [Float] {
        var out = samples
        let p = min(max(pitch, 0.5), 2.0)
        // Pitch shift by p = stretch by p (longer), then resample by p (shorter, higher).
        let wsolaTempo = tempo / p
        if abs(wsolaTempo - 1) > 0.02 {
            out = wsola(out, tempo: wsolaTempo)
        }
        if abs(p - 1) > 0.01 {
            out = resample(out, factor: p)
        }
        let gain = Float(min(max(volume, 0), 2))
        if gain != 1 {
            let unscaled = out
            vDSP.multiply(gain, unscaled, result: &out)
        }
        softLimit(&out)
        return out
    }

    // MARK: - WSOLA

    /// Waveform-similarity overlap-add time stretch. `tempo` > 1 is faster
    /// (shorter output); pitch is unchanged.
    public static func wsola(_ x: [Float], tempo: Double, sampleRate: Int = 24_000) -> [Float] {
        guard tempo > 0, abs(tempo - 1) > 0.001, x.count > 0 else { return x }
        let frame = sampleRate / 40  // 25 ms
        let hopOut = frame / 2  // 50% overlap, Hann windows sum to 1
        let hopIn = Double(hopOut) * tempo
        let tolerance = sampleRate / 160  // +-6.25 ms search
        guard x.count > frame + 2 * tolerance else {
            return resampleLength(x, to: max(1, Int(Double(x.count) / tempo)))
        }

        // Pad so every window and search stays in range.
        let pad = frame + tolerance + hopOut
        var input = [Float](repeating: 0, count: tolerance)
        input += x
        input += [Float](repeating: 0, count: pad + Int(hopIn) + frame)

        let outCount = Int(Double(x.count) / tempo)
        var output = [Float](repeating: 0, count: outCount + frame + hopOut)
        let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: frame, isHalfWindow: false)

        var prev = tolerance  // start of the previously copied input frame (padded coords)
        var k = 0
        var scratch = [Float](repeating: 0, count: frame)
        var corr = [Float](repeating: 0, count: 2 * tolerance + 1)
        input.withUnsafeBufferPointer { inp in
            output.withUnsafeMutableBufferPointer { outp in
                while true {
                    let outPos = k * hopOut
                    if outPos >= outCount { break }
                    var start: Int
                    if k == 0 {
                        start = tolerance
                    } else {
                        let nominal = tolerance + Int((Double(k) * hopIn).rounded())
                        // The natural continuation of the last frame we copied.
                        let natural = prev + hopOut
                        let lo = nominal - tolerance
                        guard lo >= 0, lo + 2 * tolerance + hopOut <= inp.count, natural + hopOut <= inp.count else { break }
                        // Cross-correlate the continuation's first half-frame with
                        // candidates in [nominal - tol, nominal + tol].
                        vDSP_conv(
                            inp.baseAddress! + lo, 1,
                            inp.baseAddress! + natural, 1,
                            &corr, 1,
                            vDSP_Length(2 * tolerance + 1), vDSP_Length(hopOut))
                        var best: Float = 0
                        var bestIndex: vDSP_Length = 0
                        vDSP_maxvi(corr, 1, &best, &bestIndex, vDSP_Length(corr.count))
                        start = lo + Int(bestIndex)
                    }
                    guard start + frame <= inp.count else { break }
                    vDSP_vmul(inp.baseAddress! + start, 1, window, 1, &scratch, 1, vDSP_Length(frame))
                    vDSP_vadd(outp.baseAddress! + outPos, 1, scratch, 1, outp.baseAddress! + outPos, 1, vDSP_Length(frame))
                    prev = start
                    k += 1
                }
            }
        }
        return Array(output.prefix(outCount))
    }

    // MARK: - Resampling

    /// Play `x` `factor` times faster (fewer samples, pitch up by `factor`),
    /// with a light low-pass first when shortening to limit aliasing.
    public static func resample(_ x: [Float], factor: Double) -> [Float] {
        let n = max(1, Int(Double(x.count) / factor))
        var src = x
        if factor > 1.05 {
            src = lowPass(src, cutoffFraction: 1 / factor)
        }
        return resampleLength(src, to: n)
    }

    static func resampleLength(_ x: [Float], to n: Int) -> [Float] {
        guard x.count > 1, n > 1 else { return Array(x.prefix(n)) }
        let step = Float(x.count - 1) / Float(n - 1)
        var positions = [Float](repeating: 0, count: n)
        vDSP_vramp([0], [step], &positions, 1, vDSP_Length(n))
        var out = [Float](repeating: 0, count: n)
        // vDSP_vlint reads x[i] and x[i+1]; keep the last index in range.
        var clamped = positions
        var lo: Float = 0
        var hi = Float(x.count) - 1.001
        vDSP_vclip(positions, 1, &lo, &hi, &clamped, 1, vDSP_Length(n))
        vDSP_vlint(x, clamped, 1, &out, 1, vDSP_Length(n), vDSP_Length(x.count))
        return out
    }

    /// Windowed-sinc FIR low-pass; `cutoffFraction` of Nyquist.
    static func lowPass(_ x: [Float], cutoffFraction: Double) -> [Float] {
        let taps = 31
        let fc = min(max(cutoffFraction, 0.05), 1) * 0.5 * 0.9  // cycles per sample
        let window = vDSP.window(ofType: Float.self, usingSequence: .blackman, count: taps, isHalfWindow: false)
        var h = [Float](repeating: 0, count: taps)
        let mid = taps / 2
        for i in 0..<taps {
            let t = Double(i - mid)
            let sinc = t == 0 ? 2 * fc : sin(2 * .pi * fc * t) / (.pi * t)
            h[i] = Float(sinc) * window[i]
        }
        let sum = h.reduce(0, +)
        let raw = h
        vDSP.divide(raw, sum, result: &h)
        var padded = [Float](repeating: 0, count: mid)
        padded += x
        padded += [Float](repeating: 0, count: taps - mid)
        var out = [Float](repeating: 0, count: x.count)
        vDSP_conv(padded, 1, h, 1, &out, 1, vDSP_Length(x.count), vDSP_Length(taps))
        return out
    }

    // MARK: - Levels

    /// Keep peaks under 0.98 without hard clipping.
    public static func softLimit(_ x: inout [Float]) {
        guard let peak = x.map(abs).max(), peak > 0.95 else { return }
        for i in x.indices where abs(x[i]) > 0.9 {
            let s: Float = x[i] < 0 ? -1 : 1
            let over = abs(x[i]) - 0.9
            x[i] = s * (0.9 + 0.08 * tanh(over / 0.08))
        }
    }

    /// Trim silence (below -50 dBFS) from the start/end, keeping a margin.
    public static func trimSilence(_ x: [Float], leading: Bool, trailing: Bool, keepSeconds: Double = 0.01) -> [Float] {
        let threshold: Float = 0.003
        guard let first = x.firstIndex(where: { abs($0) > threshold }),
            let last = x.lastIndex(where: { abs($0) > threshold })
        else { return x }
        let keep = Int(keepSeconds * 24_000)
        let s = leading ? max(0, first - keep) : 0
        let e = trailing ? min(x.count, last + 1 + keep * 6) : x.count
        return s < e ? Array(x[s..<e]) : x
    }

    public static func silence(seconds: Double) -> [Float] {
        [Float](repeating: 0, count: max(0, Int(seconds * 24_000)))
    }

    public static func rms(_ x: [Float]) -> Float {
        x.isEmpty ? 0 : vDSP.rootMeanSquare(x)
    }
}
