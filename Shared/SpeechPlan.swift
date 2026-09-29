import FluidAudio
import Foundation
import NaturalLanguage

/// Rate, pitch and volume in effect for a piece of speech, as multipliers of
/// the voice's normal values (1 = unchanged).
public struct Prosody: Equatable, Sendable {
    public var rate: Double = 1
    public var pitch: Double = 1
    public var volume: Double = 1
    public init(rate: Double = 1, pitch: Double = 1, volume: Double = 1) {
        self.rate = rate
        self.pitch = pitch
        self.volume = volume
    }
}

/// One unit of work for the synthesizer: a chunk of text small enough to
/// synthesise quickly, or a pause.
public enum SpeechPiece: Equatable, Sendable {
    case text(String, Prosody)
    case pause(Double)  // seconds
}

// MARK: - SSML

/// Turns the SSML the system sends (`AVSpeechSynthesisProviderRequest.ssmlRepresentation`)
/// into plain-text runs with their prosody, plus pauses.
public enum SSMLParser {
    public enum Run: Equatable, Sendable {
        case text(String, Prosody)
        case pause(Double)
        case boundary  // <s>, <p>: force a sentence break
    }

    public static func parse(_ ssml: String) -> [Run] {
        let trimmed = ssml.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("<") else {
            return trimmed.isEmpty ? [] : [.text(trimmed, Prosody())]
        }
        let delegate = Delegate()
        let parser = XMLParser(data: Data(trimmed.utf8))
        parser.delegate = delegate
        if parser.parse() {
            return delegate.finish()
        }
        // Not well-formed XML: strip the tags and speak what is left.
        let stripped = trimmed
            .replacingOccurrences(of: "<[^>]*>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? [] : [.text(stripped, Prosody())]
    }

    // MARK: Attribute values

    /// SSML rate: keyword, `N%` (percent of normal), `+N%`/`-N%` (relative),
    /// or a bare number (multiplier).
    static func rate(_ value: String, base: Double) -> Double {
        let v = value.trimmingCharacters(in: .whitespaces).lowercased()
        let keywords: [String: Double] = [
            "x-slow": 0.5, "slow": 0.75, "medium": 1, "default": 1, "fast": 1.5, "x-fast": 2,
        ]
        if let k = keywords[v] { return base * k }
        if v.hasSuffix("%"), let n = Double(v.dropLast()) {
            if v.hasPrefix("+") || v.hasPrefix("-") { return base * max(0.1, 1 + n / 100) }
            return base * max(0.1, n / 100)
        }
        if let n = Double(v), n > 0 { return base * n }
        return base
    }

    /// SSML pitch: keyword, `+N%`/`-N%`, `N%` (percent of normal), `+Nst`
    /// (semitones), `+NHz` (relative to a ~150 Hz speaking voice).
    static func pitch(_ value: String, base: Double) -> Double {
        let v = value.trimmingCharacters(in: .whitespaces).lowercased()
        let keywords: [String: Double] = [
            "x-low": 0.8, "low": 0.9, "medium": 1, "default": 1, "high": 1.1, "x-high": 1.2,
        ]
        if let k = keywords[v] { return base * k }
        let signed = v.hasPrefix("+") || v.hasPrefix("-")
        if v.hasSuffix("st"), let n = Double(v.dropLast(2)) { return base * pow(2, n / 12) }
        if v.hasSuffix("hz"), let n = Double(v.dropLast(2)) {
            return signed ? base * max(0.5, (150 + n) / 150) : base * max(0.5, n / 150)
        }
        if v.hasSuffix("%"), let n = Double(v.dropLast()) {
            return signed ? base * max(0.5, 1 + n / 100) : base * max(0.5, n / 100)
        }
        if let n = Double(v), n > 0 { return base * n }
        return base
    }

    /// SSML volume: keyword, `N%`, `+NdB`/`-NdB`, or a number 0-100.
    static func volume(_ value: String, base: Double) -> Double {
        let v = value.trimmingCharacters(in: .whitespaces).lowercased()
        let keywords: [String: Double] = [
            "silent": 0, "x-soft": 0.3, "soft": 0.6, "medium": 1, "default": 1, "loud": 1.2, "x-loud": 1.4,
        ]
        if let k = keywords[v] { return base * k }
        if v.hasSuffix("db"), let n = Double(v.dropLast(2)) { return base * pow(10, n / 20) }
        if v.hasSuffix("%"), let n = Double(v.dropLast()) {
            if v.hasPrefix("+") || v.hasPrefix("-") { return base * max(0, 1 + n / 100) }
            return base * max(0, n / 100)
        }
        if let n = Double(v) { return base * max(0, n / 100) }
        return base
    }

    static func breakSeconds(_ attributes: [String: String]) -> Double {
        if let time = attributes["time"]?.lowercased().trimmingCharacters(in: .whitespaces) {
            if time.hasSuffix("ms"), let n = Double(time.dropLast(2)) { return min(n / 1000, 5) }
            if time.hasSuffix("s"), let n = Double(time.dropLast()) { return min(n, 5) }
        }
        switch attributes["strength"]?.lowercased() {
        case "none": return 0
        case "x-weak": return 0.05
        case "weak": return 0.1
        case "strong": return 0.4
        case "x-strong": return 0.7
        default: return 0.25
        }
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        private var prosodyStack: [Prosody] = [Prosody()]
        private var runs: [Run] = []
        private var text = ""
        /// Collecting the contents of <say-as>/<sub>, whose text is replaced.
        private var special: (element: String, attributes: [String: String], content: String)?

        private var current: Prosody { prosodyStack.last ?? Prosody() }

        private func flushText() {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { runs.append(.text(t, current)) }
            text = ""
        }

        func parser(
            _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
            qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
        ) {
            let name = elementName.lowercased()
            switch name {
            case "prosody":
                flushText()
                var p = current
                if let r = attributeDict["rate"] { p.rate = SSMLParser.rate(r, base: p.rate) }
                if let r = attributeDict["pitch"] { p.pitch = SSMLParser.pitch(r, base: p.pitch) }
                if let r = attributeDict["volume"] { p.volume = SSMLParser.volume(r, base: p.volume) }
                prosodyStack.append(p)
            case "break":
                flushText()
                let seconds = SSMLParser.breakSeconds(attributeDict)
                if seconds > 0 { runs.append(.pause(seconds)) }
            case "s", "p":
                flushText()
                runs.append(.boundary)
            case "say-as", "sub":
                special = (name, attributeDict, "")
            default:
                break  // speak, voice, emphasis, mark, phoneme, lang, audio: speak the text inside
            }
        }

        func parser(
            _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            let name = elementName.lowercased()
            switch name {
            case "prosody":
                flushText()
                if prosodyStack.count > 1 { prosodyStack.removeLast() }
            case "s", "p":
                flushText()
                runs.append(.boundary)
            case "say-as", "sub":
                guard let s = special, s.element == name else { break }
                special = nil
                if name == "sub", let alias = s.attributes["alias"] {
                    text += " \(alias) "
                } else if let kind = s.attributes["interpret-as"] {
                    text += " " + SpeechText.sayAs(s.content, interpretAs: kind, format: s.attributes["format"]) + " "
                } else {
                    text += s.content
                }
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if special != nil {
                special?.content += string
            } else {
                text += string
            }
        }

        func finish() -> [Run] {
            flushText()
            return runs
        }
    }
}

// MARK: - Text shaping

public enum SpeechText {
    /// `<say-as>` handling. Spelled-out letters are upper-cased so the lexicon
    /// reads letter names ("a" alone would otherwise be the article "uh").
    static func sayAs(_ content: String, interpretAs kind: String, format: String?) -> String {
        switch kind.lowercased() {
        case "characters", "spell-out", "letters":
            return content.filter { !$0.isWhitespace }.map { spellable($0) }.joined(separator: ", ")
        default:
            return SayAsInterpreter.interpret(content: content, interpretAs: kind, format: format)
        }
    }

    /// One character as something Kokoro will pronounce as its name.
    static func spellable(_ c: Character) -> String {
        if c.isLetter { return String(c).uppercased() }
        if c.isNumber { return String(c) }
        return symbolNames[c] ?? String(c)
    }

    static let symbolNames: [Character: String] = [
        ".": "period", ",": "comma", "?": "question mark", "!": "exclamation mark",
        ":": "colon", ";": "semicolon", "-": "dash", "_": "underscore", "/": "slash",
        "\\": "backslash", "@": "at", "#": "number sign", "$": "dollar", "%": "percent",
        "&": "and", "*": "star", "+": "plus", "=": "equals", "(": "left paren", ")": "right paren",
        "'": "apostrophe", "\"": "quote", "<": "less than", ">": "greater than",
        "[": "left bracket", "]": "right bracket", "{": "left brace", "}": "right brace",
        "|": "vertical bar", "~": "tilde", "^": "caret", "`": "grave",
    ]

    /// VoiceOver often sends one character on its own (moving by character,
    /// typing feedback). Say its name, not a phoneme.
    static func normalizeUtterance(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count == 1, let c = t.first { return spellable(c) }
        return t
    }
}

// MARK: - Chunking

/// Splits the request into pieces the streaming synthesizer works through in
/// order. The first piece is kept short so first-audio latency stays low.
public enum SpeechPlanner {
    /// Sentences longer than this (characters) are split at clause punctuation.
    static let maxChunk = 160
    /// A first sentence longer than this is split at its first clause break.
    static let firstChunkTarget = 90

    public static func plan(ssml: String) -> [SpeechPiece] {
        var pieces: [SpeechPiece] = []
        for run in SSMLParser.parse(ssml) {
            switch run {
            case .pause(let s): pieces.append(.pause(s))
            case .boundary: break
            case .text(let t, let prosody):
                let text = SpeechText.normalizeUtterance(t)
                for chunk in chunks(text, isStart: pieces.isEmpty) {
                    pieces.append(.text(chunk, prosody))
                }
            }
        }
        return pieces
    }

    public static func plan(text: String, prosody: Prosody = Prosody()) -> [SpeechPiece] {
        chunks(SpeechText.normalizeUtterance(text), isStart: true).map { .text($0, prosody) }
    }

    static func sentences(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var out: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let s = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { out.append(s) }
            return true
        }
        return out.isEmpty && !text.isEmpty ? [text] : out
    }

    static func chunks(_ text: String, isStart: Bool) -> [String] {
        var out: [String] = []
        for sentence in sentences(text) {
            let first = isStart && out.isEmpty
            out += split(sentence, limit: first ? firstChunkTarget : maxChunk)
        }
        return out
    }

    /// Split at `, ; : —` near the limit, never leaving a tiny fragment.
    static func split(_ sentence: String, limit: Int) -> [String] {
        guard sentence.count > limit else { return [sentence] }
        let breakers: Set<Character> = [",", ";", ":", "—", "–"]
        var parts: [String] = []
        var current = ""
        let chars = Array(sentence)
        for (i, c) in chars.enumerated() {
            current.append(c)
            let nextIsSpace = i + 1 < chars.count && chars[i + 1] == " "
            if breakers.contains(c), nextIsSpace, current.count >= 25, chars.count - i > 25,
                current.count >= limit / 3
            {
                parts.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
                if parts.count == 1, limit < maxChunk {
                    // First chunk done; the rest may be longer.
                    let rest = String(chars[(i + 1)...]).trimmingCharacters(in: .whitespaces)
                    return parts + split(rest, limit: maxChunk)
                }
            }
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { parts.append(tail) }
        return parts
    }
}
