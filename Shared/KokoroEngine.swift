@_implementationOnly import CSherpaOnnx
import Foundation
import os

let kokoroLog = Logger(subsystem: "com.conner.kokorovoice", category: "engine")

public enum KokoroEngineError: LocalizedError {
    case modelsNotFound(String)
    case loadFailed(String)

    public var errorDescription: String? {
        switch self {
        case .modelsNotFound(let detail): return "Voice model files not found: \(detail)"
        case .loadFailed(let detail): return "Could not load the voice: \(detail)"
        }
    }
}

/// eSpeak NG hands audio to a C callback; collect it here (only ever used
/// from inside the engine actor, one synthesis at a time).
nonisolated(unsafe) private var espeakSamples: [Int16] = []
private let espeakCallback: @convention(c) (UnsafeMutablePointer<Int16>?, Int32, UnsafeMutableRawPointer?) -> Int32 = { wav, n, _ in
    if let wav, n > 0 { espeakSamples.append(contentsOf: UnsafeBufferPointer(start: wav, count: Int(n))) }
    return 0
}

/// One TTS engine per process, shared by every audio unit instance, the app's
/// test box and the benchmark. The model stays loaded and warm for the life
/// of the process; it is never reloaded per request.
///
/// Engine: Piper (VITS, one forward pass) through sherpa-onnx + ONNX Runtime
/// on the CPU, with eSpeak NG as its phonemizer. The "eSpeak" voice calls
/// eSpeak NG's own synthesizer directly (practically instant).
/// (The type keeps its original name; earlier builds used Kokoro and
/// Supertonic, kept in Alternatives/.)
public actor KokoroEngine {
    public static let shared = KokoroEngine()

    /// Piper medium voices and eSpeak NG both output 22.05 kHz mono.
    public static let sampleRate = 22_050

    private var tts: OpaquePointer?
    private var ttsVoice: String?
    private var hasSynthesized = false
    private var phraseCache: [String: [Float]] = [:]
    private static let processStart = Date()
    private var requestCount = 0

    public private(set) var lastLoadSeconds: Double = 0

    public init() {}

    // MARK: - Model files

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
        where fm.fileExists(atPath: candidate.appendingPathComponent("piper/espeak-ng-data").path) {
            return candidate
        }
        throw KokoroEngineError.modelsNotFound(candidates.map(\.path).joined(separator: ", "))
    }

    // MARK: - Lifecycle

    /// Load the Piper model for `voice` (once; a different Piper voice
    /// replaces it). eSpeak needs Piper's init too: it sets up eSpeak NG.
    private func load(piperVoice name: String) throws {
        if tts != nil, ttsVoice == name { return }
        let start = Date()
        let dir = try Self.modelsDirectory().appendingPathComponent("piper")
        if let old = tts {
            SherpaOnnxDestroyOfflineTts(old)
            tts = nil
        }
        var config = SherpaOnnxOfflineTtsConfig()
        let model = strdup(dir.appendingPathComponent("\(name).onnx").path)
        let tokens = strdup(dir.appendingPathComponent("\(name)-tokens.txt").path)
        let data = strdup(dir.appendingPathComponent("espeak-ng-data").path)
        let provider = strdup("cpu")
        defer { free(model); free(tokens); free(data); free(provider) }
        config.model.vits.model = UnsafePointer(model)
        config.model.vits.tokens = UnsafePointer(tokens)
        config.model.vits.data_dir = UnsafePointer(data)
        config.model.vits.noise_scale = 0.667
        config.model.vits.noise_scale_w = 0.8
        config.model.vits.length_scale = 1.0
        config.model.num_threads = 2
        config.model.provider = UnsafePointer(provider)
        config.max_num_sentences = 1
        guard let created = SherpaOnnxCreateOfflineTts(&config) else {
            throw KokoroEngineError.loadFailed("sherpa-onnx rejected \(name)")
        }
        tts = created
        ttsVoice = name
        lastLoadSeconds = Date().timeIntervalSince(start)
        kokoroLog.notice("Piper \(name, privacy: .public) loaded in \(self.lastLoadSeconds, privacy: .public) s (pid \(ProcessInfo.processInfo.processIdentifier))")
    }

    public func prepare(accent: KokoroVoice.Accent = .american) async throws {
        try load(piperVoice: ttsVoice ?? VoiceCatalog.defaultPiperModel)
    }

    /// Run one tiny synthesis so the first real request is warm.
    /// No-op once anything has been synthesized.
    public func warmUp(voice: KokoroVoice = VoiceCatalog.defaultVoice) async {
        guard !hasSynthesized else { return }
        do {
            _ = try await synthesize("Ready.", voice: voice)
        } catch {
            kokoroLog.error("warm-up failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Text -> 22.05 kHz mono float samples. `speed` > 1 is faster.
    public func synthesize(_ text: String, voice: KokoroVoice, speed: Float = 1.0) async throws -> [Float] {
        requestCount += 1
        if requestCount == 1 || requestCount % 50 == 0 {
            // Tells us (in the device log) whether VoiceOver keeps this process
            // alive between utterances or cold-starts it.
            kokoroLog.notice("request \(self.requestCount) in pid \(ProcessInfo.processInfo.processIdentifier), process age \(Date().timeIntervalSince(Self.processStart), privacy: .public) s")
        }
        let cacheKey = "\(voice.packName)|\(speed)|\(text)"
        if text.count <= 40, let cached = phraseCache[cacheKey] { return cached }

        let samples: [Float]
        if voice.isESpeak {
            samples = try espeak(text, speed: speed)
        } else {
            try load(piperVoice: voice.packName)
            guard let tts else { throw KokoroEngineError.loadFailed("no model") }
            guard let audio = SherpaOnnxOfflineTtsGenerate(tts, text, 0, speed) else {
                throw KokoroEngineError.loadFailed("generation failed")
            }
            defer { SherpaOnnxDestroyOfflineTtsGeneratedAudio(audio) }
            let a = audio.pointee
            samples = a.n > 0 ? Array(UnsafeBufferPointer(start: a.samples, count: Int(a.n))) : []
        }
        hasSynthesized = true
        if text.count <= 40 {
            if phraseCache.count >= 300 { phraseCache.removeAll(keepingCapacity: true) }
            phraseCache[cacheKey] = samples
        }
        return samples
    }

    private func espeak(_ text: String, speed: Float) throws -> [Float] {
        // eSpeak NG is initialised (synchronous output, bundled data) by the
        // Piper engine; make sure one exists.
        try load(piperVoice: ttsVoice ?? VoiceCatalog.defaultPiperModel)
        espeakSamples.removeAll(keepingCapacity: true)
        espeak_SetSynthCallback(espeakCallback)
        _ = espeak_SetVoiceByName("en-us")
        _ = espeak_SetParameter(1, Int32(min(max(175 * speed, 80), 450)), 0)  // espeakRATE, words per minute
        let bytes = Array(text.utf8) + [0]
        _ = bytes.withUnsafeBytes { buf in
            // POS_CHARACTER = 1, espeakCHARS_UTF8 = 1
            espeak_Synth(buf.baseAddress, buf.count, 0, 1, 0, 1, nil, nil)
        }
        _ = espeak_Synchronize()
        let out = espeakSamples.map { Float($0) / 32768 }
        espeakSamples.removeAll(keepingCapacity: true)
        return out
    }

    /// What the engine will read (diagnostics and tests).
    public func phonemes(_ text: String, voice: KokoroVoice = VoiceCatalog.defaultVoice) async throws -> String {
        text
    }

    public func computeDescription() -> String {
        #if targetEnvironment(simulator)
        let sim = " (iOS Simulator on a Mac)"
        #else
        let sim = ""
        #endif
        return "Piper medium (int8) on the CPU via ONNX Runtime, 2 threads; eSpeak NG native" + sim
    }
}
