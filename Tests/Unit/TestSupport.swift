import Accelerate
import Foundation
import XCTest

@testable import KokoroKit

enum TestAudio {
    static let sampleRate = 24_000

    /// Where WAVs go. CI sets TEST_RUNNER_KOKORO_OUT, which reaches the test
    /// process as KOKORO_OUT (the simulator can write to host paths).
    static var outputDirectory: URL = {
        let env = ProcessInfo.processInfo.environment["KOKORO_OUT"]
        let url = env.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("kokoro-samples")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static func saveWAV(_ samples: [Float], name: String, sampleRate: Int = 24_000) {
        var data = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let pcm = samples.map { Int16(max(-1, min(1, $0)) * 32767) }
        data.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + pcm.count * 2))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(UInt32(pcm.count * 2))
        pcm.withUnsafeBytes { data.append(contentsOf: $0) }
        let url = outputDirectory.appendingPathComponent(name)
        try? data.write(to: url)
        print("OK wrote \(url.path)")
    }

    static func peak(_ x: [Float]) -> Float { x.map(abs).max() ?? 0 }

    static func clippedFraction(_ x: [Float]) -> Double {
        x.isEmpty ? 0 : Double(x.filter { abs($0) >= 0.999 }.count) / Double(x.count)
    }

    /// Median fundamental frequency over voiced frames (autocorrelation).
    static func medianF0(_ x: [Float], sampleRate: Int = 24_000) -> Double {
        let frame = sampleRate / 25  // 40 ms
        let hop = sampleRate / 100
        let minLag = sampleRate / 400, maxLag = sampleRate / 70
        let loudness = AudioDSP.rms(x)
        var f0s: [Double] = []
        var i = 0
        while i + frame + maxLag < x.count {
            let seg = Array(x[i..<(i + frame + maxLag)])
            let head = Array(seg.prefix(frame))
            let energy = vDSP.sumOfSquares(head)
            if AudioDSP.rms(head) > loudness * 0.5, energy > 0 {
                var bestLag = 0
                var best: Float = 0
                for lag in minLag...maxLag {
                    var dot: Float = 0
                    vDSP_dotpr(seg, 1, Array(seg[lag..<(lag + frame)]), 1, &dot, vDSP_Length(frame))
                    let e2 = vDSP.sumOfSquares(Array(seg[lag..<(lag + frame)]))
                    let r = dot / sqrt(energy * e2 + 1e-9)
                    if r > best { best = r; bestLag = lag }
                }
                if best > 0.6, bestLag > 0 { f0s.append(Double(sampleRate) / Double(bestLag)) }
            }
            i += hop
        }
        guard !f0s.isEmpty else { return 0 }
        return f0s.sorted()[f0s.count / 2]
    }

    static func seconds(_ x: [Float]) -> Double { Double(x.count) / Double(sampleRate) }

    /// Seconds of audio that is actually speech (above -40 dBFS in 20 ms windows):
    /// compares speaking rates without leading/trailing silence skewing it.
    static func voicedSeconds(_ x: [Float]) -> Double {
        let w = sampleRate / 50
        var n = 0
        var i = 0
        while i + w <= x.count {
            if AudioDSP.rms(Array(x[i..<(i + w)])) > 0.01 { n += 1 }
            i += w
        }
        return Double(n) * 0.02
    }

    /// Synthesize through the streaming session (the audio unit's path).
    static func sessionAudio(_ text: String, voice: KokoroVoice = VoiceCatalog.defaultVoice,
                             prosody: Prosody = Prosody()) async -> [Float] {
        let session = KokoroSpeechSession(pieces: SpeechPlanner.plan(text: text, prosody: prosody), voice: voice)
        session.start()
        await session.wait()
        return session.buffer.drainAll(timeout: 2)
    }
}
