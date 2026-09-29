import Foundation
import os

/// Thread-safe FIFO of synthesized samples between the synthesis task and the
/// audio unit's render block.
public final class SpeechBuffer: @unchecked Sendable {
    private let cond = NSCondition()
    private var samples: [Float] = []
    private var readPos = 0
    private var finished = false
    private var cancelled = false
    private(set) var totalAppended = 0
    private let created = Date()
    private var firstAppend: Date?

    public init() {}

    public func append(_ chunk: [Float]) {
        guard !chunk.isEmpty else { return }
        cond.lock()
        if !cancelled {
            if readPos > 96_000 {  // drop what has been played
                samples.removeFirst(readPos)
                readPos = 0
            }
            samples += chunk
            totalAppended += chunk.count
            if firstAppend == nil { firstAppend = Date() }
        }
        cond.broadcast()
        cond.unlock()
    }

    public func finish() {
        cond.lock()
        finished = true
        cond.broadcast()
        cond.unlock()
    }

    public func cancel() {
        cond.lock()
        cancelled = true
        samples = []
        readPos = 0
        cond.broadcast()
        cond.unlock()
    }

    public var isCancelled: Bool {
        cond.lock()
        defer { cond.unlock() }
        return cancelled
    }

    public var isFinished: Bool {
        cond.lock()
        defer { cond.unlock() }
        return finished
    }

    /// Seconds from creation to the first audio being available.
    public var firstAudioLatency: TimeInterval? {
        cond.lock()
        defer { cond.unlock() }
        return firstAppend.map { $0.timeIntervalSince(created) }
    }

    /// Copy up to `max` samples. If nothing is ready yet, wait up to `wait`
    /// seconds for the synthesizer. Returns the count copied and whether the
    /// stream is over (finished and drained, or cancelled).
    public func read(into dst: UnsafeMutablePointer<Float>, max: Int, wait: TimeInterval) -> (count: Int, done: Bool) {
        cond.lock()
        defer { cond.unlock() }
        if samples.count - readPos == 0, !finished, !cancelled, wait > 0 {
            let deadline = Date().addingTimeInterval(wait)
            while samples.count - readPos == 0, !finished, !cancelled {
                if !cond.wait(until: deadline) { break }
            }
        }
        if cancelled { return (0, true) }
        let n = min(max, samples.count - readPos)
        if n > 0 {
            samples.withUnsafeBufferPointer { src in
                dst.update(from: src.baseAddress! + readPos, count: n)
            }
            readPos += n
        }
        return (n, finished && readPos >= samples.count)
    }

    /// Everything appended so far (tests and the benchmark).
    public func drainAll(timeout: TimeInterval) -> [Float] {
        var out: [Float] = []
        var chunk = [Float](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let (n, done) = chunk.withUnsafeMutableBufferPointer { read(into: $0.baseAddress!, max: 4096, wait: 0.2) }
            out += chunk.prefix(n)
            if done { break }
        }
        return out
    }
}

/// Synthesizes a planned request sentence by sentence into a `SpeechBuffer`,
/// so the first sentence can play while the rest are still being made.
public final class KokoroSpeechSession: @unchecked Sendable {
    public let buffer = SpeechBuffer()
    public let pieces: [SpeechPiece]
    public let voice: KokoroVoice
    private let engine: KokoroEngine
    private var task: Task<Void, Never>?
    private let log = Logger(subsystem: "com.conner.kokorovoice", category: "session")

    public init(pieces: [SpeechPiece], voice: KokoroVoice, engine: KokoroEngine = .shared) {
        self.pieces = pieces
        self.voice = voice
        self.engine = engine
    }

    public func start() {
        let pieces = self.pieces
        let voice = self.voice
        let engine = self.engine
        let buffer = self.buffer
        let log = self.log
        task = Task.detached(priority: .userInitiated) {
            let lastText = pieces.lastIndex { if case .text = $0 { return true } else { return false } }
            var producedAudio = false
            for (i, piece) in pieces.enumerated() {
                if Task.isCancelled || buffer.isCancelled { break }
                switch piece {
                case .pause(let seconds):
                    if producedAudio { buffer.append(AudioDSP.silence(seconds: seconds)) }
                case .text(let text, let prosody):
                    let (speed, stretch) = AudioDSP.split(rate: prosody.rate)
                    do {
                        var samples = try await engine.synthesize(text, voice: voice, speed: Float(speed))
                        if Task.isCancelled || buffer.isCancelled { break }
                        samples = AudioDSP.trimSilence(
                            samples, leading: !producedAudio, trailing: i == lastText)
                        samples = AudioDSP.process(
                            samples, tempo: stretch, pitch: prosody.pitch, volume: prosody.volume)
                        buffer.append(samples)
                        producedAudio = true
                    } catch {
                        log.error("synthesis failed for a chunk: \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
            buffer.finish()
        }
    }

    public func cancel() {
        buffer.cancel()
        task?.cancel()
    }

    /// Wait for synthesis to finish (tests, benchmark).
    public func wait() async {
        await task?.value
    }
}
