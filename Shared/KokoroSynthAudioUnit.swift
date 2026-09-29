import AVFAudio
import AudioToolbox
import Foundation
import os

/// The speech synthesis provider: VoiceOver and Spoken Content send SSML to
/// `synthesizeSpeechRequest`, then pull audio through the render block.
///
/// Lives in KokoroKit (not only the extension) so tests can instantiate it
/// in-process and drive it exactly like the system does.
open class KokoroSynthAudioUnit: AVSpeechSynthesisProviderAudioUnit {
    public static let componentDescription = AudioComponentDescription(
        componentType: kAudioUnitType_SpeechSynthesizer,
        componentSubType: fourCC("koko"),
        componentManufacturer: fourCC("Cnnr"),
        componentFlags: 0,
        componentFlagsMask: 0)

    /// Native Kokoro rate: 24 kHz mono float32, non-interleaved.
    public static let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: Double(KokoroEngine.sampleRate),
        channels: 1, interleaved: false)!

    /// How long one render call waits for the synthesizer before returning
    /// what it has. The render thread here is an offline pull, not a
    /// real-time I/O thread.
    /// If the host's render call is not honoured partially (it may count the
    /// whole buffer), returning early inserts silence, so wait generously.
    public static var renderWait: TimeInterval = 1.5

    private let log = Logger(subsystem: "com.conner.kokorovoice", category: "audiounit")
    private var outputBus: AUAudioUnitBus
    private var _outputBusses: AUAudioUnitBusArray!
    private let lock = NSLock()
    private var session: KokoroSpeechSession?

    /// The SSML of the last request (tests log it to learn the system's format).
    public private(set) var lastSSML: String = ""
    /// Frames the render block produced on its last call (diagnostics).
    public private(set) var lastRenderedFrames = 0

    public override init(componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions = []) throws {
        outputBus = try AUAudioUnitBus(format: Self.outputFormat)
        try super.init(componentDescription: componentDescription, options: options)
        _outputBusses = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outputBus])
        maximumFramesToRender = 4096
        // Load the model in the background so the first request is quick.
        Task.detached(priority: .userInitiated) {
            await KokoroEngine.shared.warmUp()
        }
    }

    public override var outputBusses: AUAudioUnitBusArray { _outputBusses }

    public override var speechVoices: [AVSpeechSynthesisProviderVoice] {
        get { VoiceCatalog.all.map(\.providerVoice) }
        set {}
    }

    public override func synthesizeSpeechRequest(_ speechRequest: AVSpeechSynthesisProviderRequest) {
        let ssml = speechRequest.ssmlRepresentation
        let voice = VoiceCatalog.voice(forIdentifier: speechRequest.voice.identifier)
        log.notice("request voice=\(voice.packName, privacy: .public) ssml=\(ssml, privacy: .public)")
        let newSession = KokoroSpeechSession(pieces: SpeechPlanner.plan(ssml: ssml), voice: voice)
        lock.lock()
        session?.cancel()
        session = newSession
        lastSSML = ssml
        lock.unlock()
        newSession.start()
    }

    public override func cancelSpeechRequest() {
        lock.lock()
        let old = session
        session = nil
        lock.unlock()
        old?.cancel()
        log.info("cancel")
    }

    public var currentSession: KokoroSpeechSession? {
        lock.lock()
        defer { lock.unlock() }
        return session
    }

    public override var internalRenderBlock: AUInternalRenderBlock {
        return { [weak self] actionFlags, _, frameCount, _, outputData, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(outputData)
            guard let self, let data = buffers[0].mData else {
                actionFlags.pointee = .offlineUnitRenderAction_Complete
                return noErr
            }
            let frames = data.assumingMemoryBound(to: Float.self)
            frames.update(repeating: 0, count: Int(frameCount))
            guard let session = self.currentSession else {
                self.lastRenderedFrames = 0
                buffers[0].mDataByteSize = 0
                actionFlags.pointee = .offlineUnitRenderAction_Complete
                return noErr
            }
            let (n, done) = session.buffer.read(into: frames, max: Int(frameCount), wait: Self.renderWait)
            self.lastRenderedFrames = n
            buffers[0].mDataByteSize = UInt32(n * MemoryLayout<Float>.size)
            if done {
                actionFlags.pointee = .offlineUnitRenderAction_Complete
            }
            return noErr
        }
    }
}

extension KokoroSynthAudioUnit {
    /// A message channel so the app (and tests) can talk to the real extension
    /// process: ask for its memory use and run the benchmark inside it.
    public override func messageChannel(for channelName: String) -> AUMessageChannel {
        ExtensionChannel(unit: self)
    }
}

/// Messages: ["cmd": "stats"] -> footprint; ["cmd": "startBenchmark"] then
/// poll ["cmd": "benchmarkResult"] -> ["lines": [String], "done": Bool].
/// ["cmd": "speak", "ssml": String, "voice": String] and ["cmd": "cancel"] call
/// synthesizeSpeechRequest / cancelSpeechRequest on this unit, so a host can
/// pull the audio through the out-of-process render block, like the system.
final class ExtensionChannel: NSObject, AUMessageChannel {
    private weak var unit: KokoroSynthAudioUnit?

    init(unit: KokoroSynthAudioUnit) {
        self.unit = unit
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var benchLines: [String] = []
    nonisolated(unsafe) private static var benchDone = false
    nonisolated(unsafe) private static var benchRunning = false

    var callHostBlock: CallHostBlock? {
        get { nil }
        set {}
    }

    func callAudioUnit(_ message: [AnyHashable: Any]) -> [AnyHashable: Any] {
        let (current, peak) = MemoryStats.footprint()
        var reply: [AnyHashable: Any] = [
            "pid": Int(ProcessInfo.processInfo.processIdentifier),
            "bundle": Bundle.main.bundleIdentifier ?? "",
            "footprintMB": MemoryStats.mb(current),
            "peakMB": MemoryStats.mb(peak),
        ]
        switch message["cmd"] as? String {
        case "startBenchmark":
            Self.lock.lock()
            let start = !Self.benchRunning
            if start {
                Self.benchRunning = true
                Self.benchDone = false
                Self.benchLines = []
            }
            Self.lock.unlock()
            if start {
                Task.detached(priority: .userInitiated) {
                    var lines: [String]
                    do {
                        lines = try await KokoroBenchmark.run().lines
                    } catch {
                        lines = ["Benchmark failed in the extension: \(error.localizedDescription)"]
                    }
                    Self.lock.lock()
                    Self.benchLines = lines
                    Self.benchDone = true
                    Self.benchRunning = false
                    Self.lock.unlock()
                }
            }
            reply["started"] = start
        case "speak":
            let ssml = message["ssml"] as? String ?? ""
            let voice = VoiceCatalog.voice(forIdentifier: message["voice"] as? String ?? "")
            unit?.synthesizeSpeechRequest(AVSpeechSynthesisProviderRequest(ssmlRepresentation: ssml, voice: voice.providerVoice))
            reply["accepted"] = unit != nil
        case "cancel":
            unit?.cancelSpeechRequest()
            reply["accepted"] = unit != nil
        case "benchmarkResult":
            Self.lock.lock()
            reply["done"] = Self.benchDone
            reply["lines"] = Self.benchLines
            Self.lock.unlock()
        default:
            break
        }
        return reply
    }
}

func fourCC(_ s: String) -> FourCharCode {
    s.utf8.reduce(0) { ($0 << 8) | FourCharCode($1) }
}
