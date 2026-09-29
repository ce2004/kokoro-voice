import CoreML
import FluidAudio
import Foundation
import os

let kokoroLog = Logger(subsystem: "com.conner.kokorovoice", category: "engine")

public enum KokoroEngineError: LocalizedError {
    case modelsNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .modelsNotFound(let detail): return "Kokoro model files not found: \(detail)"
        }
    }
}

/// One Kokoro model per process, shared by every audio unit instance, the app's
/// test box and the benchmark.
///
/// Wraps FluidAudio's `KokoroAneManager` (the 7-stage Core ML chain,
/// Neural Engine resident) and feeds it models bundled in the extension
/// instead of letting it download them.
public actor KokoroEngine {
    public static let shared = KokoroEngine()

    public static let sampleRate = 24_000

    private var store: KokoroAneModelStore?
    private var manager: KokoroAneManager?
    private var managerAccent: KokoroVoice.Accent?
    private var computeUnits: KokoroAneComputeUnits = .default
    private var usingFallbackUnits = false
    private var hasSynthesized = false

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
        // A test bundle hosted by the app: walk up to the .app.
        var url = Bundle(for: KokoroEngine.self).bundleURL
        while url.pathComponents.count > 1 {
            if url.pathExtension == "app" {
                candidates.append(url.appendingPathComponent("PlugIns/KokoroSynth.appex/Models"))
                break
            }
            url.deleteLastPathComponent()
        }
        for candidate in candidates
        where fm.fileExists(atPath: candidate.appendingPathComponent("kokoro-82m-coreml/ANE/vocab.json").path) {
            return candidate
        }
        throw KokoroEngineError.modelsNotFound(candidates.map(\.path).joined(separator: ", "))
    }

    /// FluidAudio loads its G2P model and lexicon from a fixed cache folder
    /// (`Application Support/fluidaudio/Models/kokoro`). Point that folder at
    /// the bundled files so nothing is ever downloaded. The lexicon is a
    /// symlink so switching between the American and British lexicons is free.
    private static func linkG2PAssets(from models: URL, accent: KokoroVoice.Accent) throws {
        let fm = FileManager.default
        let src = models.appendingPathComponent("kokoro")
        let dst = try TtsCacheDirectory.ensure()
            .appendingPathComponent("Models/kokoro")
        // An old whole-directory symlink or a stale bundle path: start clean.
        if let type = try? fm.attributesOfItem(atPath: dst.path)[.type] as? FileAttributeType,
            type == .typeSymbolicLink
        {
            try fm.removeItem(at: dst)
        }
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)

        let lexicon = accent == .british ? "gb_lexicon.tsv" : "us_lexicon.tsv"
        let links: [(String, String)] = [
            ("G2PEncoder.mlmodelc", "G2PEncoder.mlmodelc"),
            ("G2PDecoder.mlmodelc", "G2PDecoder.mlmodelc"),
            ("g2p_vocab.json", "g2p_vocab.json"),
            ("us_lexicon_cache.json", lexicon),
        ]
        for (name, target) in links {
            let link = dst.appendingPathComponent(name)
            let targetURL = src.appendingPathComponent(target)
            if let existing = try? fm.destinationOfSymbolicLink(atPath: link.path),
                existing == targetURL.path
            {
                continue
            }
            try? fm.removeItem(at: link)
            try fm.createSymbolicLink(at: link, withDestinationURL: targetURL)
        }
    }

    // MARK: - Lifecycle

    /// Load the models (once) and the lexicon for `accent`.
    public func prepare(accent: KokoroVoice.Accent = .american) async throws {
        if manager != nil, managerAccent == accent { return }
        let start = Date()
        let models = try Self.modelsDirectory()
        try Self.linkG2PAssets(from: models, accent: accent)
        if store == nil {
            store = KokoroAneModelStore(directory: models, computeUnits: computeUnits, variant: .english)
        }
        // A fresh manager per accent: its lexicon cache is per instance, so the
        // old lexicon is freed. The Core ML chain lives in the shared store.
        let newManager = KokoroAneManager(
            variant: .english, defaultVoice: VoiceCatalog.defaultVoice.packName, modelStore: store)
        manager = nil
        do {
            try await newManager.initialize()
        } catch where !usingFallbackUnits {
            // The Neural Engine route failed to load (for example if the OS
            // refuses ANE work for this process). Fall back to the CPU.
            kokoroLog.error("model load failed on the default route: \(error.localizedDescription, privacy: .public); retrying on CPU")
            usingFallbackUnits = true
            computeUnits = .cpuOnly
            store = KokoroAneModelStore(directory: models, computeUnits: computeUnits, variant: .english)
            return try await prepare(accent: accent)
        }
        manager = newManager
        managerAccent = accent
        lastLoadSeconds = Date().timeIntervalSince(start)
        kokoroLog.info("Kokoro ready (\(accent.rawValue, privacy: .public)) in \(self.lastLoadSeconds, privacy: .public) s")
    }

    /// Run the whole pipeline once on a short phrase so the first real
    /// request doesn't pay for lexicon parsing and Core ML's first-run setup.
    /// Does nothing once any synthesis has run, so a new audio unit instance
    /// never makes a real request wait behind a warm-up.
    public func warmUp(voice: KokoroVoice = VoiceCatalog.defaultVoice) async {
        guard !hasSynthesized else { return }
        do {
            _ = try await synthesize("Ready.", voice: voice)
        } catch {
            kokoroLog.error("warm-up failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Text -> 24 kHz mono float samples.
    public func synthesize(_ text: String, voice: KokoroVoice, speed: Float = 1.0) async throws -> [Float] {
        try await prepare(accent: voice.accent)
        guard let manager else { throw KokoroEngineError.modelsNotFound("manager not ready") }
        let result = try await manager.synthesizeDetailed(
            text: text, voice: voice.packName, speed: speed)
        hasSynthesized = true
        return result.samples
    }

    /// Text -> the phoneme string Kokoro will speak (diagnostics and tests).
    public func phonemes(_ text: String, voice: KokoroVoice = VoiceCatalog.defaultVoice) async throws -> String {
        try await prepare(accent: voice.accent)
        guard let manager else { return "" }
        return try await manager.phonemes(for: text)
    }

    // MARK: - Reporting

    /// Human description of where the chain runs.
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
            return "CPU only (Neural Engine route failed to load)" + sim
        }
        let units = computeUnits
        let aneStages = [units.albert, units.postAlbert, units.alignment, units.prosody, units.noise,
                         units.vocoder, units.tail].filter { $0 == .cpuAndNeuralEngine || $0 == .all }.count
        let placement = "\(aneStages) of 7 stages asked for the Neural Engine, the rest CPU\(units.noise == .cpuAndGPU ? "/GPU" : "")"
        return (hasANE ? "Neural Engine available; " : "No Neural Engine available; ") + placement + sim
    }
}
