import Darwin
import Foundation

public enum MemoryStats {
    /// (current, peak) physical footprint in bytes: the numbers jetsam uses.
    public static func footprint() -> (current: UInt64, peak: UInt64) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return (0, 0) }
        return (info.phys_footprint, UInt64(max(0, info.ledger_phys_footprint_peak)))
    }

    public static func mb(_ bytes: UInt64) -> Double { Double(bytes) / 1_048_576 }
}

public struct BenchmarkCase: Sendable {
    public let name: String
    public let text: String
    public let firstAudio: TimeInterval
    public let total: TimeInterval
    public let audioSeconds: Double
    public var realTimeFactor: Double { total > 0 ? audioSeconds / total : 0 }
}

public struct BenchmarkReport: Sendable {
    public var voice: String
    public var loadSeconds: Double
    public var compute: String
    public var baselineMB: Double
    public var peakMB: Double
    public var afterModelsMB: Double = 0
    public var afterWarmUpMB: Double = 0
    public var cases: [BenchmarkCase]
    public var isSimulator: Bool

    /// Plain lines for the screen and the CI log.
    public var lines: [String] {
        var out: [String] = []
        if isSimulator {
            out.append("Measured in the iOS Simulator on a Mac (CPU only, no Neural Engine). A rough estimate, not phone numbers.")
        }
        out.append("Voice: \(voice)")
        out.append("Compute: \(compute)")
        out.append(String(format: "Model load and warm-up: %.2f s", loadSeconds))
        for c in cases {
            out.append(String(
                format: "%@: first audio %.0f ms, total %.0f ms, %.2f s of audio, %@",
                c.name, c.firstAudio * 1000, c.total * 1000, c.audioSeconds,
                Self.speedPhrase(c.realTimeFactor)))
        }
        out.append(String(format: "Memory: %.0f MB after loading the Core ML models and G2P, %.0f MB after the lexicon and a first synthesis",
                          afterModelsMB, afterWarmUpMB))
        out.append(String(format: "Peak memory: %.0f MB (%.0f MB before loading the model, so Kokoro added about %.0f MB)",
                          peakMB, baselineMB, max(0, peakMB - baselineMB)))
        return out
    }

    public static func speedPhrase(_ rtf: Double) -> String {
        if rtf >= 1 {
            return String(format: "%.1f times faster than real time", rtf)
        }
        return String(format: "%.1f times slower than real time", rtf > 0 ? 1 / rtf : 0)
    }

    /// A shorter version to speak aloud.
    public var spokenSummary: String {
        var parts: [String] = []
        for c in cases {
            parts.append("\(c.name): first audio in \(Int((c.firstAudio * 1000).rounded())) milliseconds, \(Self.speedPhrase(c.realTimeFactor)).")
        }
        parts.append("Peak memory \(Int(peakMB.rounded())) megabytes.")
        parts.append("Model load \(String(format: "%.1f", loadSeconds)) seconds.")
        return parts.joined(separator: " ")
    }
}

public enum KokoroBenchmark {
    public static let texts: [(name: String, text: String)] = [
        ("VoiceOver phrase", "Settings, button"),
        ("Sentence", "The quick brown fox jumps over the lazy dog, then naps in the afternoon sun."),
        ("Paragraph", """
            Kokoro is a small text to speech model with eighty two million parameters. \
            It runs on the phone itself, so nothing you read is sent anywhere. \
            On March 3rd, 2026, Dr. Smith paid $45.50 for 12 books at 221B Baker St. \
            This paragraph checks numbers, abbreviations and punctuation; it should sound natural!
            """),
    ]

    /// Load the model, then time each text through the same streaming session
    /// the audio unit uses. `progress` receives a line per step.
    public static func run(
        voice: KokoroVoice = VoiceCatalog.defaultVoice,
        engine: KokoroEngine = .shared,
        progress: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> BenchmarkReport {
        let baseline = MemoryStats.footprint().current
        let loadStart = Date()
        try await engine.prepare(accent: voice.accent)
        let afterModels = MemoryStats.footprint().current
        await engine.warmUp(voice: voice)
        let afterWarm = MemoryStats.footprint().current
        let load = Date().timeIntervalSince(loadStart)
        progress(String(format: "Model loaded in %.2f s", load))

        var cases: [BenchmarkCase] = []
        for (name, text) in texts {
            let session = KokoroSpeechSession(pieces: SpeechPlanner.plan(text: text), voice: voice, engine: engine)
            let start = Date()
            session.start()
            await session.wait()
            let total = Date().timeIntervalSince(start)
            let samples = session.buffer.drainAll(timeout: 1)
            let c = BenchmarkCase(
                name: name, text: text,
                firstAudio: session.buffer.firstAudioLatency ?? total,
                total: total,
                audioSeconds: Double(samples.count) / Double(KokoroEngine.sampleRate))
            cases.append(c)
            progress(String(format: "%@: first audio %.0f ms, %@", name, c.firstAudio * 1000,
                            BenchmarkReport.speedPhrase(c.realTimeFactor)))
        }
        #if targetEnvironment(simulator)
        let sim = true
        #else
        let sim = false
        #endif
        var report = BenchmarkReport(
            voice: voice.displayName, loadSeconds: load, compute: await engine.computeDescription(),
            baselineMB: MemoryStats.mb(baseline), peakMB: MemoryStats.mb(MemoryStats.footprint().peak),
            cases: cases, isSimulator: sim)
        report.afterModelsMB = MemoryStats.mb(afterModels)
        report.afterWarmUpMB = MemoryStats.mb(afterWarm)
        return report
    }
}
