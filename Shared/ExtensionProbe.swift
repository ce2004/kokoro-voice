import AVFAudio
import AudioToolbox
import Foundation

/// Loads the real speech extension (KokoroSynth.appex) out of process, the
/// way the system does, and talks to it through its message channel. Lets the
/// app measure the extension's own memory and speed on the phone.
public enum ExtensionProbe {
    public enum ProbeError: LocalizedError {
        case notRegistered
        case noChannel
        case timedOut

        public var errorDescription: String? {
            switch self {
            case .notRegistered: return "The system has not registered the Kokoro voice extension."
            case .noChannel: return "The extension did not answer."
            case .timedOut: return "The extension benchmark timed out."
            }
        }
    }

    /// Our audio component as the system sees it, if registered.
    public static func component() -> AVAudioUnitComponent? {
        let d = KokoroSynthAudioUnit.componentDescription
        return AVAudioUnitComponentManager.shared().components(matching: d).first
    }

    public static func instantiate() async throws -> AVAudioUnit {
        guard let c = component() else { throw ProbeError.notRegistered }
        return try await AVAudioUnit.instantiate(with: c.audioComponentDescription, options: [.loadOutOfProcess])
    }

    public static func call(_ unit: AUAudioUnit, _ message: [AnyHashable: Any]) throws -> [AnyHashable: Any] {
        let channel = unit.messageChannel(for: "kokoro")
        guard let reply = channel.callAudioUnit?(message) else { throw ProbeError.noChannel }
        return reply
    }

    /// Run the benchmark inside the extension process; returns its report lines.
    public static func benchmarkInExtension(timeout: TimeInterval = 600) async throws -> [String] {
        let unit = try await instantiate()
        let au = unit.auAudioUnit
        let before = try call(au, ["cmd": "stats"])
        _ = try call(au, ["cmd": "startBenchmark"])
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 500_000_000)
            let r = try call(au, ["cmd": "benchmarkResult"])
            if r["done"] as? Bool == true {
                var lines = ["Inside the voice extension (process \(r["pid"] ?? "?"), \(r["bundle"] ?? "")):"]
                lines += (r["lines"] as? [String]) ?? []
                let startMB = (before["footprintMB"] as? Double) ?? 0
                lines.append(String(format: "Extension memory: %.0f MB when loaded, peak %.0f MB, now %.0f MB",
                                    startMB, (r["peakMB"] as? Double) ?? 0, (r["footprintMB"] as? Double) ?? 0))
                return lines
            }
        }
        throw ProbeError.timedOut
    }
}
