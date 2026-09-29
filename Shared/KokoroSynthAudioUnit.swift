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
    public static var renderWait: TimeInterval = 0.25

    private let log = Logger(subsystem: "com.conner.kokorovoice", category: "audiounit")
    private var outputBus: AUAudioUnitBus
    private var _outputBusses: AUAudioUnitBusArray!
    private let lock = NSLock()
    private var session: KokoroSpeechSession?

    /// The SSML of the last request (tests log it to learn the system's format).
    public private(set) var lastSSML: String = ""

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
        log.info("request voice=\(voice.packName, privacy: .public) ssml=\(ssml, privacy: .public)")
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
                buffers[0].mDataByteSize = 0
                actionFlags.pointee = .offlineUnitRenderAction_Complete
                return noErr
            }
            let (n, done) = session.buffer.read(into: frames, max: Int(frameCount), wait: Self.renderWait)
            buffers[0].mDataByteSize = UInt32(n * MemoryLayout<Float>.size)
            if done {
                actionFlags.pointee = .offlineUnitRenderAction_Complete
            }
            return noErr
        }
    }
}

func fourCC(_ s: String) -> FourCharCode {
    s.utf8.reduce(0) { ($0 << 8) | FourCharCode($1) }
}
