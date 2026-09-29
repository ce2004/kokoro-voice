import XCTest

@testable import KokoroKit

/// Runs the real Kokoro model (Core ML, CPU in the simulator).
final class SynthesisTests: XCTestCase {
    static let texts: [(file: String, text: String, minSeconds: Double, maxSeconds: Double)] = [
        ("phrase", "Settings, button", 0.5, 3),
        ("sentence", "The quick brown fox jumps over the lazy dog, then naps in the afternoon sun.", 3, 9),
        ("paragraph", KokoroBenchmark.texts[2].text, 12, 45),
    ]

    func test1_TextsInSeveralVoices() async throws {
        let engine = KokoroEngine.shared
        let voices = ["af_heart", "am_michael", "bf_emma"].map { VoiceCatalog.voice(forIdentifier: $0) }
        for voice in voices {
            for t in Self.texts {
                let samples = try await engine.synthesize(t.text, voice: voice)
                let seconds = TestAudio.seconds(samples)
                let rms = AudioDSP.rms(samples)
                let peak = TestAudio.peak(samples)
                let clipped = TestAudio.clippedFraction(samples)
                print(String(format: "OK %@ %@: %.2f s at %d Hz, rms %.3f, peak %.3f, clipped %.5f%%",
                             voice.packName, t.file, seconds, KokoroEngine.sampleRate, rms, peak, clipped * 100))
                XCTAssertEqual(KokoroEngine.sampleRate, 24_000)
                XCTAssertGreaterThan(rms, 0.01, "\(voice.packName) \(t.file) is (nearly) silent")
                XCTAssertLessThan(clipped, 0.0005, "\(voice.packName) \(t.file) clips")
                XCTAssertLessThanOrEqual(peak, 1.0)
                XCTAssertGreaterThan(seconds, t.minSeconds, "\(voice.packName) \(t.file) too short")
                XCTAssertLessThan(seconds, t.maxSeconds, "\(voice.packName) \(t.file) too long")
                TestAudio.saveWAV(samples, name: "\(voice.packName)_\(t.file).wav")
            }
        }
    }

    /// Numbers, abbreviations and punctuation: log the phonemes so a human
    /// can check them in the CI log, and assert the obvious ones.
    func test2_TextNormalization() async throws {
        let engine = KokoroEngine.shared
        let cases = ["$45.50", "March 3rd, 2026", "Dr. Smith", "3:45 PM", "12 books", "e.g. this", "Wi-Fi", "iPhone"]
        for c in cases {
            let ph = try await engine.phonemes(c)
            print("OK phonemes \(c) -> \(ph)")
            XCTAssertFalse(ph.isEmpty, c)
            XCTAssertFalse(ph.contains(where: { $0.isNumber }), "digits left unread in \(c): \(ph)")
        }
        let gb = try await engine.phonemes("tomato", voice: VoiceCatalog.voice(forIdentifier: "bf_emma"))
        let us = try await engine.phonemes("tomato", voice: VoiceCatalog.voice(forIdentifier: "af_heart"))
        print("OK tomato: British \(gb), American \(us)")
        XCTAssertNotEqual(gb, us, "British voices should use the British lexicon")
    }

    /// A faster rate makes shorter audio at the same pitch; pitch changes F0.
    func test3_RateAndPitch() async throws {
        let text = "The quick brown fox jumps over the lazy dog, then naps in the afternoon sun."
        let base = await TestAudio.sessionAudio(text)
        let baseVoiced = TestAudio.voicedSeconds(base)
        let baseF0 = TestAudio.medianF0(base)
        print(String(format: "OK rate 1.0: %.2f s (%.2f s voiced), f0 %.0f Hz", TestAudio.seconds(base), baseVoiced, baseF0))
        XCTAssertGreaterThan(baseF0, 80)
        TestAudio.saveWAV(base, name: "rate_1x.wav")
        for rate in [1.5, 2.0, 3.0, 4.0] {
            let audio = await TestAudio.sessionAudio(text, prosody: Prosody(rate: rate))
            let voiced = TestAudio.voicedSeconds(audio)
            let f0 = TestAudio.medianF0(audio)
            let speedup = baseVoiced / max(voiced, 0.01)
            print(String(format: "OK rate %.1f: %.2f s (%.2f s voiced, %.2fx shorter), f0 %.0f Hz (%.0f%% of normal)",
                         rate, TestAudio.seconds(audio), voiced, speedup, f0, f0 / baseF0 * 100))
            XCTAssertEqual(speedup, rate, accuracy: rate * 0.25, "rate \(rate)")
            XCTAssertEqual(f0, baseF0, accuracy: baseF0 * 0.12, "pitch drifted at rate \(rate)")
            TestAudio.saveWAV(audio, name: String(format: "rate_%.1fx.wav", rate))
        }
        let high = await TestAudio.sessionAudio(text, prosody: Prosody(pitch: 1.25))
        let highF0 = TestAudio.medianF0(high)
        print(String(format: "OK pitch 1.25: %.2f s, f0 %.0f Hz (%.2fx)", TestAudio.seconds(high), highF0, highF0 / baseF0))
        XCTAssertEqual(highF0 / baseF0, 1.25, accuracy: 0.1)
        XCTAssertEqual(TestAudio.voicedSeconds(high), baseVoiced, accuracy: baseVoiced * 0.15)
        TestAudio.saveWAV(high, name: "pitch_1.25.wav")
    }
}
