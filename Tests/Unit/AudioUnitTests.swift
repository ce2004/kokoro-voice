import AVFAudio
import AudioToolbox
import XCTest

@testable import KokoroKit

/// Drives the provider audio unit the way the speech system does:
/// synthesizeSpeechRequest, then pull audio through the render block.
final class AudioUnitTests: XCTestCase {
    private func makeUnit() throws -> KokoroSynthAudioUnit {
        let unit = try KokoroSynthAudioUnit(componentDescription: KokoroSynthAudioUnit.componentDescription, options: [])
        try unit.allocateRenderResources()
        return unit
    }

    private func request(_ ssml: String, voice: String = "af_heart") -> AVSpeechSynthesisProviderRequest {
        AVSpeechSynthesisProviderRequest(
            ssmlRepresentation: ssml, language: "en-US",
            voice: VoiceCatalog.voice(forIdentifier: voice).providerVoice)
    }

    /// One render call; returns the frames produced and whether the unit said it's complete.
    private func render(_ unit: KokoroSynthAudioUnit, frames: AVAudioFrameCount = 512) -> (samples: [Float], complete: Bool) {
        let buffer = AVAudioPCMBuffer(pcmFormat: KokoroSynthAudioUnit.outputFormat, frameCapacity: frames)!
        buffer.frameLength = frames
        var flags = AudioUnitRenderActionFlags()
        var ts = AudioTimeStamp()
        let status = unit.renderBlock(&flags, &ts, frames, 0, buffer.mutableAudioBufferList, nil)
        XCTAssertEqual(status, noErr)
        let bytes = Int(buffer.audioBufferList.pointee.mBuffers.mDataByteSize)
        let n = bytes / MemoryLayout<Float>.size
        let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: n))
        return (samples, flags.contains(.offlineUnitRenderAction_Complete))
    }

    func testFormatAndVoices() throws {
        let unit = try makeUnit()
        let format = unit.outputBusses[0].format
        XCTAssertEqual(format.sampleRate, 24_000)
        XCTAssertEqual(format.channelCount, 1)
        XCTAssertEqual(format.commonFormat, .pcmFormatFloat32)
        let voices = unit.speechVoices
        XCTAssertEqual(voices.count, VoiceCatalog.all.count)
        XCTAssertTrue(voices.allSatisfy { $0.name.hasPrefix("Kokoro ") })
        print("OK voices: " + voices.map { "\($0.name) [\($0.primaryLanguages.joined())]" }.joined(separator: ", "))
    }

    func testRenderSSMLRequest() throws {
        let unit = try makeUnit()
        let ssml = """
            <?xml version="1.0" encoding="UTF-8"?><speak version="1.1" xmlns="http://www.w3.org/2001/10/synthesis" \
            xml:lang="en-US"><prosody rate="100%">Settings, button. <break time="200ms"/>Wi-Fi, on.</prosody></speak>
            """
        let start = Date()
        unit.synthesizeSpeechRequest(request(ssml))
        var audio: [Float] = []
        var firstAudio: TimeInterval?
        var complete = false
        while !complete, Date().timeIntervalSince(start) < 120 {
            let r = render(unit)
            if !r.samples.isEmpty, firstAudio == nil { firstAudio = Date().timeIntervalSince(start) }
            audio += r.samples
            complete = r.complete
        }
        XCTAssertTrue(complete, "render never completed")
        let seconds = TestAudio.seconds(audio)
        print(String(format: "OK audio unit: first audio %.0f ms, %.2f s of audio, rms %.3f",
                     (firstAudio ?? -1) * 1000, seconds, AudioDSP.rms(audio)))
        XCTAssertGreaterThan(seconds, 1.0)
        XCTAssertGreaterThan(AudioDSP.rms(audio), 0.01)
        TestAudio.saveWAV(audio, name: "audiounit_ssml.wav")
        // Nothing more after completion.
        XCTAssertTrue(render(unit).complete)
    }

    func testCancelStopsOutputPromptly() throws {
        let unit = try makeUnit()
        let paragraph = KokoroBenchmark.texts[2].text + " " + KokoroBenchmark.texts[2].text
        unit.synthesizeSpeechRequest(request("<speak>\(paragraph)</speak>"))
        let start = Date()
        var got = 0
        while got < 24_000 / 5, Date().timeIntervalSince(start) < 120 {  // 0.2 s of audio
            got += render(unit).samples.count
        }
        XCTAssertGreaterThan(got, 0, "no audio before cancelling")

        let t0 = Date()
        unit.cancelSpeechRequest()
        let after = render(unit)
        let ms = Date().timeIntervalSince(t0) * 1000
        print(String(format: "OK cancel: next render returned %d samples, complete=%@, in %.2f ms",
                     after.samples.count, after.complete ? "yes" : "no", ms))
        XCTAssertTrue(after.complete, "render should report completion right after cancel")
        XCTAssertEqual(after.samples.count, 0)
        XCTAssertLessThan(ms, 50)

        // A new request right after a cancel works (VoiceOver does this constantly).
        unit.synthesizeSpeechRequest(request("<speak>Next item.</speak>"))
        var audio: [Float] = []
        var complete = false
        let s2 = Date()
        while !complete, Date().timeIntervalSince(s2) < 60 {
            let r = render(unit)
            audio += r.samples
            complete = r.complete
        }
        print(String(format: "OK after cancel: new request gave %.2f s", TestAudio.seconds(audio)))
        XCTAssertGreaterThan(TestAudio.seconds(audio), 0.3)
        XCTAssertLessThan(TestAudio.seconds(audio), 3, "old audio leaked into the new request")
    }
}
