import AVFAudio
import Foundation

/// The Kokoro voices this app exposes to the system. Keep in sync with
/// `VOICES` in scripts/fetch_models.py (the packs bundled in the extension).
public struct KokoroVoice: Hashable, Sendable, Identifiable {
    public enum Accent: String, Sendable { case american, british }

    /// Piper model name (`lessac`, `amy`) or `espeak`.
    public let packName: String
    /// Short human name, e.g. `Heart`.
    public let shortName: String
    public let isFemale: Bool

    public var id: String { packName }
    public var accent: Accent { .american }
    public var language: String { accent == .british ? "en-GB" : "en-US" }
    /// The name shown in Settings > VoiceOver > Speech > Voice.
    public var displayName: String { isESpeak ? "eSpeak" : "Piper \(shortName)" }
    public var isESpeak: Bool { packName == "espeak" }
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
        KokoroVoice(packName: "lessac", shortName: "Lessac", isFemale: true),
        KokoroVoice(packName: "amy", shortName: "Amy", isFemale: true),
        KokoroVoice(packName: "espeak", shortName: "eSpeak", isFemale: false),
    ]

    /// Piper model loaded first (and used to initialise eSpeak NG).
    public static let defaultPiperModel = "lessac"

    public static let defaultVoice = all[0]

    /// Resolve a system voice identifier (or a bare pack name) to a voice.
    public static func voice(forIdentifier identifier: String) -> KokoroVoice {
        all.first { $0.identifier == identifier || $0.packName == identifier }
            ?? all.first { identifier.hasSuffix($0.packName) }
            ?? defaultVoice
    }
}
