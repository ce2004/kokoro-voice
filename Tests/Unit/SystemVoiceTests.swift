import AVFAudio
import XCTest

@testable import KokoroKit

/// End to end through the OS: AVSpeechSynthesizer -> speech daemon -> our
/// extension (KokoroSynth.appex) -> buffers. Only possible if the simulator
/// registers the extension's voices.
final class SystemVoiceTests: XCTestCase {
    private func findVoice(_ identifier: String, timeout: TimeInterval) async -> AVSpeechSynthesisVoice? {
        AVSpeechSynthesisProviderVoice.updateSpeechVoices()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let v = AVSpeechSynthesisVoice.speechVoices().first(where: { $0.identifier == identifier }) {
                return v
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return nil
    }

    private func write(_ utterance: AVSpeechUtterance, timeout: TimeInterval) async -> (samples: [Float], format: AVAudioFormat?, firstBuffer: TimeInterval?) {
        let synth = AVSpeechSynthesizer()
        var samples: [Float] = []
        var format: AVAudioFormat?
        var first: TimeInterval?
        let start = Date()
        let done = expectation(description: "all buffers")
        var fulfilled = false
        synth.write(utterance) { buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            if pcm.frameLength == 0 {
                if !fulfilled { fulfilled = true; done.fulfill() }
                return
            }
            if first == nil { first = Date().timeIntervalSince(start) }
            format = pcm.format
            if let ch = pcm.floatChannelData {
                samples += UnsafeBufferPointer(start: ch[0], count: Int(pcm.frameLength))
            } else if let ch = pcm.int16ChannelData {
                samples += UnsafeBufferPointer(start: ch[0], count: Int(pcm.frameLength)).map { Float($0) / 32768 }
            }
        }
        await fulfillment(of: [done], timeout: timeout)
        _ = synth
        return (samples, format, first)
    }

    func testSpeakThroughSystemSynthesizer() async throws {
        let voice = VoiceCatalog.defaultVoice
        let all = AVSpeechSynthesisVoice.speechVoices()
        print("INFO audio component registered: \(ExtensionProbe.component().map { "\($0.name) by \($0.manufacturerName)" } ?? "no")")
        guard let systemVoice = await findVoice(voice.identifier, timeout: 90) else {
            let kokoro = AVSpeechSynthesisVoice.speechVoices().filter { $0.name.contains("Kokoro") }
            print("INFO system voices: \(all.count), Kokoro among them: \(kokoro.count)")
            throw XCTSkip("The simulator did not list the extension's voices after updateSpeechVoices(); end-to-end check not possible here.")
        }
        print("OK system lists \(systemVoice.name) (\(systemVoice.identifier), \(systemVoice.language))")

        let utterance = AVSpeechUtterance(string: "Settings, button. The quick brown fox jumps over the lazy dog.")
        utterance.voice = systemVoice
        let normal = await write(utterance, timeout: 180)
        let f = normal.format
        print(String(format: "OK system synthesizer: %.2f s of audio, first buffer after %.0f ms, format %@, rms %.3f",
                     TestAudio.seconds(normal.samples), (normal.firstBuffer ?? -1) * 1000,
                     f.map { "\($0.sampleRate) Hz \($0.channelCount) ch \($0.commonFormat.rawValue)" } ?? "none",
                     AudioDSP.rms(normal.samples)))
        XCTAssertGreaterThan(TestAudio.seconds(normal.samples), 1)
        XCTAssertGreaterThan(AudioDSP.rms(normal.samples), 0.005)
        if let f { TestAudio.saveWAV(normal.samples, name: "system_synthesizer.wav", sampleRate: Int(f.sampleRate)) }

        let fastUtterance = AVSpeechUtterance(string: "Settings, button. The quick brown fox jumps over the lazy dog.")
        fastUtterance.voice = systemVoice
        fastUtterance.rate = AVSpeechUtteranceMaximumSpeechRate
        let fast = await write(fastUtterance, timeout: 180)
        let ratio = TestAudio.voicedSeconds(normal.samples) / max(TestAudio.voicedSeconds(fast.samples), 0.01)
        print(String(format: "OK system synthesizer at maximum rate: %.2f s of audio (%.2fx shorter than default)",
                     TestAudio.seconds(fast.samples), ratio))
        XCTAssertGreaterThan(ratio, 1.3, "the system's rate did not reach the voice")
        if let ff = fast.format { TestAudio.saveWAV(fast.samples, name: "system_synthesizer_max_rate.wav", sampleRate: Int(ff.sampleRate)) }
    }
}

/// The real KokoroSynth.appex, loaded out of process like the system loads it.
final class ExtensionProcessTests: XCTestCase {
    func testExtensionOutOfProcess() async throws {
        guard let c = ExtensionProbe.component() else {
            throw XCTSkip("AVAudioUnitComponentManager does not list the extension's 'ausp' component in this simulator.")
        }
        print("OK component: \(c.name) by \(c.manufacturerName), type \(c.typeName), sandboxSafe \(c.isSandboxSafe)")
        let unit = try await ExtensionProbe.instantiate()
        let au = unit.auAudioUnit
        print("OK instantiated out of process: \(type(of: au)), provider subclass: \(au is AVSpeechSynthesisProviderAudioUnit)")
        let stats = try ExtensionProbe.call(au, ["cmd": "stats"])
        print("OK extension process: \(stats)")
        XCTAssertNotEqual(stats["pid"] as? Int, Int(ProcessInfo.processInfo.processIdentifier), "should be another process")
        if let provider = au as? AVSpeechSynthesisProviderAudioUnit {
            print("OK extension voices via proxy: \(provider.speechVoices.map(\.name))")
        }
        try renderAcrossProcesses(au)
        let lines = try await ExtensionProbe.benchmarkInExtension()
        for line in lines { print("BENCH-EXT \(line)") }
        XCTAssertTrue(lines.contains { $0.contains("first audio") }, "\(lines)")
    }

    /// Request speech in the extension process, then pull the audio through
    /// the out-of-process render block (the path the speech daemon uses).
    private func renderAcrossProcesses(_ au: AUAudioUnit) throws {
        let format = au.outputBusses[0].format
        print("OK extension output format: \(format)")
        XCTAssertEqual(format.sampleRate, 24_000)
        au.maximumFramesToRender = 1024
        try au.allocateRenderResources()
        defer { au.deallocateRenderResources() }

        func pull(until stop: (Double, [Float]) -> Bool, timeout: TimeInterval) -> (audio: [Float], firstAudio: TimeInterval?, complete: Bool) {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
            var audio: [Float] = []
            var first: TimeInterval?
            let start = Date()
            while Date().timeIntervalSince(start) < timeout {
                buffer.frameLength = 512
                var flags = AudioUnitRenderActionFlags()
                var ts = AudioTimeStamp()
                ts.mFlags = .sampleTimeValid
                ts.mSampleTime = Double(audio.count)
                let status = au.renderBlock(&flags, &ts, 512, 0, buffer.mutableAudioBufferList, nil)
                if status != noErr {
                    print("INFO render status \(status)")
                    return (audio, first, false)
                }
                let chunk = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: 512))
                if first == nil, chunk.contains(where: { $0 != 0 }) { first = Date().timeIntervalSince(start) }
                if first != nil { audio += chunk }
                if flags.contains(.offlineUnitRenderAction_Complete) { return (audio, first, true) }
                if stop(Date().timeIntervalSince(start), audio) { return (audio, first, false) }
            }
            return (audio, first, false)
        }

        _ = try ExtensionProbe.call(au, ["cmd": "speak", "voice": "af_heart",
                                          "ssml": "<speak>Settings, button. Double tap to open.</speak>"])
        let spoken = pull(until: { _, _ in false }, timeout: 120)
        print(String(format: "OK across processes: %.2f s of audio, first audio %.0f ms after the request, complete=%@, rms %.3f",
                     TestAudio.seconds(spoken.audio), (spoken.firstAudio ?? -1) * 1000,
                     spoken.complete ? "yes" : "no", AudioDSP.rms(spoken.audio)))
        XCTAssertTrue(spoken.complete, "the extension never reported completion")
        XCTAssertGreaterThan(TestAudio.seconds(spoken.audio), 1)
        XCTAssertGreaterThan(AudioDSP.rms(spoken.audio), 0.01)
        TestAudio.saveWAV(spoken.audio, name: "extension_process.wav")

        // Cancel across processes, as VoiceOver does when you swipe on.
        _ = try ExtensionProbe.call(au, ["cmd": "speak", "voice": "am_michael",
                                          "ssml": "<speak>\(KokoroBenchmark.texts[2].text)</speak>"])
        let partial = pull(until: { _, audio in audio.count > 24_000 / 2 }, timeout: 120)
        XCTAssertNotNil(partial.firstAudio, "no audio before cancelling")
        let c0 = Date()
        _ = try ExtensionProbe.call(au, ["cmd": "cancel"])
        let after = pull(until: { t, _ in t > 1 }, timeout: 2)
        let ms = Date().timeIntervalSince(c0) * 1000
        let leaked = after.audio.count
        print(String(format: "OK cancel across processes: completion after %.1f ms, %d samples of audio after the cancel",
                     ms, leaked))
        XCTAssertTrue(after.complete, "render did not complete after cancel")
        XCTAssertEqual(leaked, 0)
        XCTAssertLessThan(ms, 100)
    }
}

final class BenchmarkTests: XCTestCase {
    func testBenchmark() async throws {
        let report = try await KokoroBenchmark.run { print("BENCH progress: \($0)") }
        for line in report.lines { print("BENCH \(line)") }
        XCTAssertEqual(report.cases.count, 3)
        for c in report.cases {
            XCTAssertGreaterThan(c.audioSeconds, 0.3, c.name)
        }
    }
}
