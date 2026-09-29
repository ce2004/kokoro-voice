import AVFAudio
import Foundation

/// The Kokoro voices this app exposes to the system. Keep in sync with
/// `VOICES` in scripts/fetch_models.py (the packs bundled in the extension).
public struct KokoroVoice: Hashable, Sendable, Identifiable {
    public enum Accent: String, Sendable { case american, british }

    /// Kokoro voice pack name, e.g. `af_heart`.
    public let packName: String
    /// Short human name, e.g. `Heart`.
    public let shortName: String
    public let isFemale: Bool

    public var id: String { packName }
    public var accent: Accent { packName.hasPrefix("b") ? .british : .american }
    public var language: String { accent == .british ? "en-GB" : "en-US" }
    /// The name shown in Settings > VoiceOver > Speech > Voice.
    public var displayName: String { "Kokoro \(shortName)" }
    /// Stable identifier the system stores when the voice is selected.
    public var identifier: String { "com.conner.kokorovoice.\(packName)" }

    public var providerVoice: AVSpeechSynthesisProviderVoice {
        let voice = AVSpeechSynthesisProviderVoice(
            name: displayName,
            identifier: identifier,
            primaryLanguages: [language],
            supportedLanguages: [language])
        voice.gender = isFemale ? .female : .male
        voice.version = "1.0"
        return voice
    }
}

public enum VoiceCatalog {
    public static let all: [KokoroVoice] = [
        KokoroVoice(packName: "af_heart", shortName: "Heart", isFemale: true),
        KokoroVoice(packName: "af_bella", shortName: "Bella", isFemale: true),
        KokoroVoice(packName: "af_nicole", shortName: "Nicole", isFemale: true),
        KokoroVoice(packName: "am_michael", shortName: "Michael", isFemale: false),
        KokoroVoice(packName: "am_fenrir", shortName: "Fenrir", isFemale: false),
        KokoroVoice(packName: "bf_emma", shortName: "Emma", isFemale: true),
        KokoroVoice(packName: "bf_isabella", shortName: "Isabella", isFemale: true),
        KokoroVoice(packName: "bm_george", shortName: "George", isFemale: false),
        KokoroVoice(packName: "bm_fable", shortName: "Fable", isFemale: false),
    ]

    public static let defaultVoice = all[0]

    /// Resolve a system voice identifier (or a bare pack name) to a voice.
    public static func voice(forIdentifier identifier: String) -> KokoroVoice {
        all.first { $0.identifier == identifier || $0.packName == identifier }
            ?? all.first { identifier.hasSuffix($0.packName) }
            ?? defaultVoice
    }
}
