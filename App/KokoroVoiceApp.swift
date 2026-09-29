import AVFAudio
import KokoroKit
import SwiftUI

@main
struct KokoroVoiceApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

/// Plays a speech session in the app as it is synthesized.
@MainActor
final class StreamPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var pump: Task<Void, Never>?
    private var session: KokoroSpeechSession?

    init() {
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: KokoroSynthAudioUnit.outputFormat)
    }

    func play(_ session: KokoroSpeechSession) {
        stop()
        self.session = session
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        if !engine.isRunning { try? engine.start() }
        node.play()
        session.start()
        let buffer = session.buffer
        let node = self.node
        pump = Task.detached(priority: .userInitiated) {
            let format = KokoroSynthAudioUnit.outputFormat
            while !Task.isCancelled {
                guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800) else { break }
                let (n, done) = buffer.read(into: pcm.floatChannelData![0], max: 4800, wait: 0.2)
                if n > 0 {
                    pcm.frameLength = AVAudioFrameCount(n)
                    node.scheduleBuffer(pcm, completionHandler: nil)
                }
                if done { break }
            }
        }
    }

    func stop() {
        session?.cancel()
        pump?.cancel()
        node.stop()
        session = nil
    }
}
