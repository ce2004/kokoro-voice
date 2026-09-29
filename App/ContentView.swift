import AVFAudio
import KokoroKit
import SwiftUI
import UIKit

struct ContentView: View {
    @State private var text = "Hello! This is Piper, speaking on your iPhone. It costs $4.99, and it's 3:45 PM."
    @State private var voiceID = VoiceCatalog.defaultVoice.packName
    @State private var rate = 1.0
    @State private var status = ""
    @State private var benchmarkLines: [String] = []
    @State private var benchmarking = false
    @State private var player = StreamPlayer()
    @State private var systemSynth = AVSpeechSynthesizer()

    private var voice: KokoroVoice {
        VoiceCatalog.all.first { $0.packName == voiceID } ?? VoiceCatalog.defaultVoice
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Turn on the Piper voice") {
                    Text("""
                        For VoiceOver: Settings, Accessibility, VoiceOver, Speech, Voice. \
                        Choose English, then pick Piper Lessac, Piper Amy, or eSpeak.
                        """)
                    Text("""
                        For Speak Selection and Speak Screen: Settings, Accessibility, Spoken Content, Voices, English, \
                        then choose Piper Lessac, Piper Amy or eSpeak.
                        """)
                    Text("If the voices are missing, press this button, wait half a minute and look again.")
                    Button("Refresh system voices") {
                        AVSpeechSynthesisProviderVoice.updateSpeechVoices()
                        announce("Asked the system to refresh its voice list.")
                    }
                }

                Section("Try it") {
                    TextField("Text to speak", text: $text, axis: .vertical)
                        .lineLimit(3...8)
                        .accessibilityLabel("Text to speak")
                    Picker("Voice", selection: $voiceID) {
                        ForEach(VoiceCatalog.all) { v in
                            Text(v.displayName)
                                .tag(v.packName)
                        }
                    }
                    VStack(alignment: .leading) {
                        Text(String(format: "Speed: %.2f times", rate))
                        Slider(value: $rate, in: 0.5...4, step: 0.25)
                            .accessibilityLabel("Speed")
                            .accessibilityValue(String(format: "%.2f times", rate))
                    }
                    Button("Speak") { speak() }
                    Button("Stop") {
                        player.stop()
                        systemSynth.stopSpeaking(at: .immediate)
                    }
                    Button("Speak through the system voice") { speakThroughSystem() }
                    if !status.isEmpty {
                        Text(status)
                    }
                }

                Section("Benchmark") {
                    Button(benchmarking ? "Benchmark running…" : "Run benchmark") { runBenchmark() }
                        .disabled(benchmarking)
                    Button("Benchmark inside the voice extension") { runExtensionBenchmark() }
                        .disabled(benchmarking)
                    ForEach(Array(benchmarkLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                    }
                }
            }
            .navigationTitle("Kokoro Voice")
        }
    }

    private func speak() {
        let pieces = SpeechPlanner.plan(text: text, prosody: Prosody(rate: rate))
        let session = KokoroSpeechSession(pieces: pieces, voice: voice)
        status = "Loading the voice…"
        player.play(session)
        Task {
            await session.wait()
            if let latency = session.buffer.firstAudioLatency {
                status = "First audio after \(Int(latency * 1000)) milliseconds."
            } else {
                status = "Nothing was spoken."
            }
        }
    }

    /// Goes through AVSpeechSynthesizer and the extension, like VoiceOver does.
    private func speakThroughSystem() {
        guard let systemVoice = AVSpeechSynthesisVoice(identifier: voice.identifier) else {
            status = "The system doesn't list \(voice.displayName) yet. Press Refresh system voices and try again in half a minute."
            announce(status)
            return
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = systemVoice
        utterance.rate = Float(min(max(AVSpeechUtteranceDefaultSpeechRate * Float(rate), AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate))
        systemSynth.speak(utterance)
        status = "Speaking through the system voice."
    }

    private func runBenchmark() {
        benchmarking = true
        benchmarkLines = ["Running. The first run loads the model, which can take a while."]
        announce("Benchmark started.")
        let v = voice
        Task {
            do {
                let report = try await KokoroBenchmark.run(voice: v) { line in
                    Task { @MainActor in benchmarkLines.append(line) }
                }
                benchmarkLines = report.lines
                speakResult(report.spokenSummary)
            } catch {
                benchmarkLines = ["Benchmark failed: \(error.localizedDescription)"]
                announce(benchmarkLines[0])
            }
            benchmarking = false
        }
    }

    /// Same benchmark, but run by the real extension process: its memory is
    /// what counts against the extension's limit.
    private func runExtensionBenchmark() {
        benchmarking = true
        benchmarkLines = ["Starting the voice extension and running the benchmark inside it."]
        announce("Extension benchmark started.")
        Task {
            do {
                benchmarkLines = try await ExtensionProbe.benchmarkInExtension()
                speakResult(benchmarkLines.filter { $0.contains("first audio") || $0.contains("memory") }.joined(separator: " "))
            } catch {
                benchmarkLines = ["Extension benchmark failed: \(error.localizedDescription)"]
                announce(benchmarkLines[0])
            }
            benchmarking = false
        }
    }

    private func speakResult(_ summary: String) {
        if UIAccessibility.isVoiceOverRunning {
            announce(summary)
        } else {
            systemSynth.speak(AVSpeechUtterance(string: summary))
        }
    }

    private func announce(_ message: String) {
        UIAccessibility.post(notification: .announcement, argument: message)
    }
}
