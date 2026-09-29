import CoreML
import FluidAudio
import Foundation
import os

let kokoroLog = Logger(subsystem: "com.conner.kokorovoice", category: "engine")

public enum KokoroEngineError: LocalizedError {
    case modelsNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .modelsNotFound(let detail): return "Voice model files not found: \(detail)"
        }
    }
}

/// One TTS model per process, shared by every audio unit instance, the app's
/// test box and the benchmark.
///
/// Engine: Supertonic 3 (FluidAudio's 4-stage Core ML port; the diffusion
/// step model runs on the Neural Engine in fixed-length int4 buckets).
/// Models are bundled in the extension; nothing is downloaded.
/// (The type keeps its original name; the first build used Kokoro-82M.)
public actor KokoroEngine {
    public static let shared = KokoroEngine()

    /// Supertonic 3 outputs 44.1 kHz mono.
    public static let sampleRate = 44_100
    /// Denoising steps: the quality/latency middle ground (upstream default 8).
    public static let steps = 3
    /// Supertonic's natural speaking speed multiplier (upstream default).
    static let baseSpeed: Float = 1.05

    private var manager: Supertonic3Manager?
    private var styles: [String: Supertonic3VoiceStyle] = [:]
    private var usingFallbackUnits = false
    private var hasSynthesized = false
    private var phraseCache: [String: [Float]] = [:]

    /// Wall time of the last model load (seconds), for the benchmark.
    public private(set) var lastLoadSeconds: Double = 0

    public init() {}

    // MARK: - Model files

    /// `<bundle>/Models`: the extension's own resources inside the extension,
    /// or the embedded extension's resources when running in the app.
    public static func modelsDirectory() throws -> URL {
        let fm = FileManager.default
        var candidates: [URL] = []
        let main = Bundle.main
        if main.bundleURL.pathExtension == "appex", let res = main.resourceURL {
            candidates.append(res.appendingPathComponent("Models"))
        }
        if let plugins = main.builtInPlugInsURL {
            candidates.append(plugins.appendingPathComponent("KokoroSynth.appex/Models"))
        }
        var url = Bundle(for: KokoroEngine.self).bundleURL
        while url.pathComponents.count > 1 {
            if url.pathExtension == "app" {
                candidates.append(url.appendingPathComponent("PlugIns/KokoroSynth.appex/Models"))
                break
            }
            url.deleteLastPathComponent()
        }
        for candidate in candidates
        where fm.fileExists(atPath: candidate.appendingPathComponent("supertonic-3/tts.json").path) {
            return candidate
        }
        throw KokoroEngineError.modelsNotFound(candidates.map(\.path).joined(separator: ", "))
    }

    // MARK: - Lifecycle

    public func prepare(accent: KokoroVoice.Accent = .american) async throws {
        if manager != nil { return }
        let start = Date()
        let models = try Self.modelsDirectory()
        let units: MLComputeUnits = usingFallbackUnits ? .cpuOnly : .cpuAndNeuralEngine
        let m = Supertonic3Manager(directory: models, computeUnits: units, vectorEstimator: .aneBucketed(.int4))
        do {
            try await m.initialize()
        } catch where !usingFallbackUnits {
            kokoroLog.error("model load failed: \(error.localizedDescription, privacy: .public); retrying on CPU")
            usingFallbackUnits = true
            return try await prepare(accent: accent)
        }
        manager = m
        lastLoadSeconds = Date().timeIntervalSince(start)
        kokoroLog.notice("Supertonic ready in \(self.lastLoadSeconds, privacy: .public) s")
    }

    private func style(for voice: KokoroVoice) throws -> Supertonic3VoiceStyle {
        if let s = styles[voice.packName] { return s }
        let url = try Self.modelsDirectory().appendingPathComponent("supertonic-3/voice_styles/\(voice.packName).json")
        let s = try Supertonic3VoiceStyle.load(from: url)
        styles[voice.packName] = s
        return s
    }

    /// Run the whole pipeline once so the first real request doesn't pay for
    /// Core ML's first-run setup. No-op once anything has been synthesized.
    public func warmUp(voice: KokoroVoice = VoiceCatalog.defaultVoice) async {
        guard !hasSynthesized else { return }
        do {
            _ = try await synthesize("Ready.", voice: voice)
        } catch {
            kokoroLog.error("warm-up failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Text -> 44.1 kHz mono float samples.
    public func synthesize(_ text: String, voice: KokoroVoice, speed: Float = 1.0) async throws -> [Float] {
        // Short phrases ("button", "heading", app names) repeat constantly in
        // VoiceOver: serve them from a small in-memory cache.
        let cacheKey = "\(voice.packName)|\(speed)|\(text)"
        if text.count <= 40, let cached = phraseCache[cacheKey] {
            return cached
        }
        try await prepare(accent: voice.accent)
        guard let manager else { throw KokoroEngineError.modelsNotFound("manager not ready") }
        let spoken = Self.normalize(text)
        do {
            let result = try await manager.synthesize(
                text: spoken, language: "en", style: try style(for: voice),
                totalSteps: Self.steps, speed: Self.baseSpeed * speed, silenceDuration: 0.05)
            hasSynthesized = true
            if text.count <= 40 {
                if phraseCache.count >= 300 { phraseCache.removeAll(keepingCapacity: true) }
                phraseCache[cacheKey] = result.samples
            }
            return result.samples
        } catch where !usingFallbackUnits {
            // The Neural Engine path failed at run time: reload on the CPU once.
            kokoroLog.error("synthesis failed: \(error.localizedDescription, privacy: .public); reloading on CPU")
            usingFallbackUnits = true
            await manager.cleanup()
            self.manager = nil
            return try await synthesize(text, voice: voice, speed: speed)
        }
    }

    /// Numbers, currency, times and dates to words (NeMo text normalization).
    static func normalize(_ text: String) -> String {
        NemoTextNormalizer.normalize(text, language: .english)
    }

    /// What the engine will actually read (diagnostics and tests).
    public func phonemes(_ text: String, voice: KokoroVoice = VoiceCatalog.defaultVoice) async throws -> String {
        Self.normalize(text)
    }

    // MARK: - Reporting

    public func computeDescription() -> String {
        let hasANE = MLModel.availableComputeDevices.contains {
            if case .neuralEngine = $0 { return true }
            return false
        }
        #if targetEnvironment(simulator)
        let sim = " (iOS Simulator: Core ML runs on the Mac's CPU)"
        #else
        let sim = ""
        #endif
        if usingFallbackUnits {
            return "Supertonic 3, \(Self.steps) steps, CPU only (Neural Engine route failed)" + sim
        }
        return "Supertonic 3, \(Self.steps) steps; " + (hasANE ? "Neural Engine available, " : "no Neural Engine, ")
            + "diffusion steps on the Neural Engine (int4), encoder and vocoder CPU/Neural Engine" + sim
    }
}
