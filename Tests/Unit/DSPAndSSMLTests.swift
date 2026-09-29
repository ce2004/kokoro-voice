import XCTest

@testable import KokoroKit

/// Fast tests that don't need the model.
final class DSPAndSSMLTests: XCTestCase {
    private func tone(_ f0: Double, seconds: Double) -> [Float] {
        let n = Int(seconds * 24_000)
        return (0..<n).map { i in
            let t = Double(i) / 24_000
            // A few harmonics with a slow amplitude wobble, roughly voice-like.
            let env = 0.6 + 0.3 * sin(2 * .pi * 3 * t)
            let s = sin(2 * .pi * f0 * t) + 0.5 * sin(2 * .pi * 2 * f0 * t) + 0.25 * sin(2 * .pi * 3 * f0 * t)
            return Float(0.3 * env * s)
        }
    }

    func testWSOLAChangesLengthNotPitch() {
        let x = tone(180, seconds: 3)
        let f0In = TestAudio.medianF0(x)
        for tempo in [0.7, 1.5, 2.0, 3.0] {
            let y = AudioDSP.wsola(x, tempo: tempo)
            let expected = Double(x.count) / tempo
            XCTAssertEqual(Double(y.count), expected, accuracy: expected * 0.02, "length at tempo \(tempo)")
            let f0Out = TestAudio.medianF0(y)
            XCTAssertEqual(f0Out, f0In, accuracy: f0In * 0.05, "pitch at tempo \(tempo)")
            XCTAssertLessThan(TestAudio.peak(y), 1.0)
            print("OK wsola tempo \(tempo): \(x.count) -> \(y.count) samples, f0 \(Int(f0In)) -> \(Int(f0Out)) Hz")
        }
    }

    func testPitchShiftKeepsLength() {
        let x = tone(150, seconds: 2)
        let y = AudioDSP.process(x, tempo: 1, pitch: 1.3, volume: 1)
        XCTAssertEqual(Double(y.count), Double(x.count), accuracy: Double(x.count) * 0.03)
        let ratio = TestAudio.medianF0(y) / TestAudio.medianF0(x)
        XCTAssertEqual(ratio, 1.3, accuracy: 0.06)
        print("OK pitch 1.3: f0 ratio \(ratio)")
    }

    func testRateSplit() {
        XCTAssertEqual(AudioDSP.split(rate: 1).modelSpeed, 1)
        XCTAssertEqual(AudioDSP.split(rate: 1).stretch, 1)
        let fast = AudioDSP.split(rate: 3.2)
        XCTAssertEqual(fast.modelSpeed, AudioDSP.maxModelSpeed)
        XCTAssertEqual(fast.modelSpeed * fast.stretch, 3.2, accuracy: 1e-9)
    }

    func testSSMLProsodyAndBreaks() {
        let ssml = """
            <?xml version="1.0"?><speak version="1.1" xmlns="http://www.w3.org/2001/10/synthesis" xml:lang="en-US">\
            <prosody rate="200%" pitch="+10%" volume="50%">Hello &amp; welcome.<break time="300ms"/>Next</prosody>\
            <prosody rate="x-slow">slow</prosody></speak>
            """
        let runs = SSMLParser.parse(ssml)
        XCTAssertEqual(runs.count, 4, "\(runs)")
        guard case .text(let t, let p) = runs[0] else { return XCTFail("\(runs)") }
        XCTAssertEqual(t, "Hello & welcome.")
        XCTAssertEqual(p.rate, 2, accuracy: 1e-9)
        XCTAssertEqual(p.pitch, 1.1, accuracy: 1e-9)
        XCTAssertEqual(p.volume, 0.5, accuracy: 1e-9)
        XCTAssertEqual(runs[1], .pause(0.3))
        guard case .text(_, let slow) = runs[3] else { return XCTFail() }
        XCTAssertEqual(slow.rate, 0.5, accuracy: 1e-9)
    }

    func testSSMLValues() {
        XCTAssertEqual(SSMLParser.rate("+50%", base: 1), 1.5, accuracy: 1e-9)
        XCTAssertEqual(SSMLParser.rate("1.8", base: 1), 1.8, accuracy: 1e-9)
        XCTAssertEqual(SSMLParser.pitch("+12st", base: 1), 2, accuracy: 1e-9)
        XCTAssertEqual(SSMLParser.pitch("x-low", base: 1), 0.8, accuracy: 1e-9)
        XCTAssertEqual(SSMLParser.volume("-6dB", base: 1), 0.501, accuracy: 0.01)
    }

    func testSayAsAndSingleCharacters() {
        let runs = SSMLParser.parse("<speak><say-as interpret-as=\"characters\">ab.</say-as></speak>")
        guard case .text(let t, _) = runs.first else { return XCTFail("\(runs)") }
        XCTAssertEqual(t, "A, B, period")
        XCTAssertEqual(SpeechText.normalizeUtterance("a"), "A")
        XCTAssertEqual(SpeechText.normalizeUtterance(" ? "), "question mark")
        XCTAssertEqual(SpeechText.normalizeUtterance("Settings, button"), "Settings, button")
    }

    func testMalformedSSMLFallsBackToText() {
        let runs = SSMLParser.parse("<speak>Tom & Jerry <b>")
        guard case .text(let t, _) = runs.first else { return XCTFail("\(runs)") }
        XCTAssertEqual(t, "Tom & Jerry")
        XCTAssertEqual(SSMLParser.parse("plain text"), [.text("plain text", Prosody())])
    }

    func testPlannerKeepsFirstChunkShort() {
        let text = "This opening sentence is deliberately rather long, so that the planner has to split it at a comma, and then keep going. Second sentence."
        let pieces = SpeechPlanner.plan(text: text)
        XCTAssertGreaterThanOrEqual(pieces.count, 3, "\(pieces)")
        guard case .text(let first, _) = pieces[0] else { return XCTFail() }
        XCTAssertLessThanOrEqual(first.count, 60, first)
        print("OK plan: \(pieces)")
    }
}
