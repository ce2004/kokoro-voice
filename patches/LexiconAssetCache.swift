import Foundation

// Kokoro Voice patch (replaces FluidAudio's LexiconAssetCache.swift).
//
// The upstream cache decodes the Misaki lexicon into [String: [String]],
// one heap-allocated array of one-character strings per word: about 60 MB
// for ~190k words, too much for a speech synthesis extension. LexiconMap
// keeps one String per word (usually stored inline, no allocation) and
// splits it into scalar tokens on lookup. The loader also reads a compact
// TSV form ("L|C <TAB> word <TAB> phonemes") so loading never builds the
// big JSON object graph at all.

/// Word -> Misaki phoneme tokens (each token one Unicode scalar).
public struct LexiconMap: Sendable, ExpressibleByDictionaryLiteral {
    var storage: [String: String]

    public init(_ storage: [String: String] = [:]) {
        self.storage = storage
    }

    public init(dictionaryLiteral elements: (String, [String])...) {
        var s: [String: String] = [:]
        for (k, v) in elements where s[k] == nil { s[k] = v.joined() }
        storage = s
    }

    public subscript(key: String) -> [String]? {
        guard let joined = storage[key] else { return nil }
        return joined.unicodeScalars.map { String($0) }
    }

    public var isEmpty: Bool { storage.isEmpty }
    public var count: Int { storage.count }
}

public actor LexiconAssetCache {

    private static let logger = AppLogger(category: "LexiconAssetCache")

    private var wordToPhonemes = LexiconMap()
    private var caseSensitiveWordToPhonemes = LexiconMap()
    private var isLoaded = false

    private struct CachePayload: Codable {
        let lower: [String: [String]]
        let caseSensitive: [String: [String]]
    }

    public init() {}

    public func ensureLoaded(
        kokoroDirectory: URL, allowedTokens: Set<String>
    ) async throws {
        if isLoaded && !caseSensitiveWordToPhonemes.isEmpty { return }

        let cacheURL = kokoroDirectory.appendingPathComponent("us_lexicon_cache.json")
        guard FileManager.default.fileExists(atPath: cacheURL.path) else {
            throw TTSError.processingFailed(
                "Missing lexicon cache (expected us_lexicon_cache.json)")
        }

        do {
            let data = try Data(contentsOf: cacheURL, options: .mappedIfSafe)
            var lower: [String: String] = [:]
            var caseSensitive: [String: String] = [:]
            let allowedScalars = Set(allowedTokens.compactMap { $0.unicodeScalars.count == 1 ? $0.unicodeScalars.first : nil })
            func keep(_ phonemes: Substring) -> String {
                var s = String.UnicodeScalarView()
                for u in phonemes.unicodeScalars where allowedScalars.contains(u) { s.append(u) }
                return String(s)
            }

            if data.first == UInt8(ascii: "{") {
                let payload = try JSONDecoder().decode(CachePayload.self, from: data)
                lower.reserveCapacity(payload.lower.count)
                for (k, v) in payload.lower { lower[k] = keep(Substring(v.filter { allowedTokens.contains($0) }.joined())) }
                for (k, v) in payload.caseSensitive { caseSensitive[k] = keep(Substring(v.filter { allowedTokens.contains($0) }.joined())) }
            } else {
                guard let text = String(data: data, encoding: .utf8) else {
                    throw TTSError.processingFailed("lexicon TSV is not UTF-8")
                }
                lower.reserveCapacity(200_000)
                for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                    let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
                    guard parts.count == 3 else { continue }
                    let phonemes = keep(parts[2])
                    if parts[0] == "C" {
                        caseSensitive[String(parts[1])] = phonemes
                    } else {
                        lower[String(parts[1])] = phonemes
                    }
                }
            }

            guard !lower.isEmpty else {
                throw TTSError.processingFailed(
                    "us_lexicon_cache.json had no entries within the allowed token set")
            }

            wordToPhonemes = LexiconMap(lower)
            caseSensitiveWordToPhonemes = LexiconMap(caseSensitive)
            isLoaded = true
            Self.logger.info("Loaded lexicon cache: \(lower.count) entries")
        } catch let error as TTSError {
            throw error
        } catch {
            wordToPhonemes = LexiconMap()
            caseSensitiveWordToPhonemes = LexiconMap()
            isLoaded = false
            throw TTSError.processingFailed(
                "Failed to load lexicon cache: \(error.localizedDescription)")
        }
    }

    public func lexicons() -> (word: LexiconMap, caseSensitive: LexiconMap) {
        (wordToPhonemes, caseSensitiveWordToPhonemes)
    }
}
