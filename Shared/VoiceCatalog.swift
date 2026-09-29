import AVFAudio
import Foundation

/// The Kokoro voices this app exposes to the system. Keep in sync with
/// `VOICES` in scripts/fetch_models.py (the packs bundled in the extension).
public struct KokoroVoice: Hashable, Sendable, Identifiable {
    public enum Accent: String, Sendable { case american, british }

    /// Supertonic voice style name, e.g. `F1`.
    public let packName: String
    /// Short human name, e.g. `Heart`.
    public let shortName: String
    public let isFemale: Bool

    public var id: String { packName }
    public var accent: Accent { .american }
    public var language: String { accent == .british ? "en-GB" : "en-US" }
    /// The name shown in Settings > VoiceOver > Speech > Voice.
    public var displayName: String { "Supertonic \(shortName)" }
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
        KokoroVoice(packName: "F1", shortName: "Female 1", isFemale: true),
        KokoroVoice(packName: "F2", shortName: "Female 2", isFemale: true),
        KokoroVoice(packName: "F3", shortName: "Female 3", isFemale: true),
        KokoroVoice(packName: "F4", shortName: "Female 4", isFemale: true),
        KokoroVoice(packName: "F5", shortName: "Female 5", isFemale: true),
        KokoroVoice(packName: "M1", shortName: "Male 1", isFemale: false),
        KokoroVoice(packName: "M2", shortName: "Male 2", isFemale: false),
        KokoroVoice(packName: "M3", shortName: "Male 3", isFemale: false),
        KokoroVoice(packName: "M4", shortName: "Male 4", isFemale: false),
        KokoroVoice(packName: "M5", shortName: "Male 5", isFemale: false),
    ]

    public static let defaultVoice = all[0]

    /// Resolve a system voice identifier (or a bare pack name) to a voice.
    public static func voice(forIdentifier identifier: String) -> KokoroVoice {
        all.first { $0.identifier == identifier || $0.packName == identifier }
            ?? all.first { identifier.hasSuffix($0.packName) }
            ?? defaultVoice
    }
}
