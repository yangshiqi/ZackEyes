import Foundation

/// The journal's only safety boundary (#214).
///
/// The design deliberately has **no human review gate** before publishing, so
/// everything a model wrote passes through here and nowhere else. That is also
/// why this is a pure function with no I/O: it has to be exhaustively testable
/// without an agent CLI, without a network, and without a filesystem.
///
/// ## Discard, never repair
///
/// Every rule below rejects the **whole item**. Nothing is truncated and
/// nothing is substituted:
///
/// - Truncating can leave half a secret.
/// - Substituting (the `Redactor` approach, which rewrites a home path to `~`)
///   is right for a diagnostics dump the user reads themselves, but wrong here:
///   a sentence with `<user>` wedged into it reads like an incident, and the
///   sentence was never worth that much. `Redactor`'s *rules* are reused; its
///   *semantics* are not.
///
/// The cost of discarding is one fewer lesson, not a broken feature, which is
/// what licenses tuning it this aggressively.
///
/// ## Why a whitelist
///
/// A blocklist of "things that look like secrets" always loses — there is
/// always one more format. So the primary rule is what is *allowed*: CJK,
/// Latin letters, digits, and a small punctuation set. That single rule
/// removes paths, shell, code, templates and URLs wholesale, and it fails
/// closed on anything nobody thought of.
public enum JournalSanitizer {

    /// Names that are allowed to look like code because they are products,
    /// not identifiers. Extended at runtime with the user's project aliases —
    /// an alias is chosen by the user precisely so it can appear in the
    /// journal, so it must survive the camel-case rule.
    public static let defaultProperNouns: Set<String> = [
        "ZackEyes", "GitHub", "GitLab", "MacBook", "JavaScript", "TypeScript",
        "macOS", "iOS", "iPadOS", "PostgreSQL", "MySQL", "GraphQL", "OpenAI",
        "SwiftUI", "AppKit", "XcodeCloud", "CocoaPods", "PyTorch", "TensorFlow",
    ]

    /// Prefixes that are never anything but a credential. Redundant with the
    /// character-set rule for most real keys (they carry `_`, `-` or base64
    /// padding), and kept precisely because redundancy is cheap here.
    static let secretPrefixes = [
        "ghp_", "gho_", "ghu_", "ghs_", "ghr_", "github_pat_",
        "sk-", "sk-ant-", "AKIA", "ASIA", "xox", "eyJ", "-----BEGIN",
        "AIza", "ya29.", "glpat-", "npm_", "dop_v1_", "shpat_",
    ]

    public struct Policy: Sendable {
        public let maxScalars: Int
        public let properNouns: Set<String>
        /// Rejected when found anywhere in the item. Supplied by the caller
        /// from `Redactor`'s inputs (home directory, username, hostname).
        public let forbiddenLiterals: [String]

        public init(
            maxScalars: Int,
            properNouns: Set<String> = JournalSanitizer.defaultProperNouns,
            forbiddenLiterals: [String] = []
        ) {
            self.maxScalars = maxScalars
            self.properNouns = properNouns
            self.forbiddenLiterals = forbiddenLiterals
        }
    }

    /// Why an item was rejected. Surfaced only in the run record — a rejection
    /// is never shown to the model or retried, because a second attempt at the
    /// same content would just produce the same leak in different words.
    public enum Rejection: String, Sendable, Equatable, Error {
        case empty
        case tooLong
        case disallowedCharacter
        case dottedIdentifier
        case ipAddress
        case codeIdentifier
        case secretPrefix
        case highEntropy
        case forbiddenLiteral
        case strayHash
    }

    // MARK: - Entry points

    /// Accept an item unchanged, or reject it with a reason.
    ///
    /// Returns the trimmed original on success — the text is never rewritten,
    /// so a caller can rely on "what came back is what the model wrote".
    public static func check(_ raw: String, policy: Policy) -> Result<String, Rejection> {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(.empty) }

        // Credential and identity checks run FIRST, ahead of the character
        // whitelist. Most real tokens (`ghp_…`) would also trip the character
        // rule, but reporting `disallowedCharacter` for a leaked key makes the
        // run record useless for the one case anyone would want to grep for.
        if firstSecretPrefix(in: text) != nil { return .failure(.secretPrefix) }
        for literal in policy.forbiddenLiterals where !literal.isEmpty {
            if text.range(of: literal, options: .caseInsensitive) != nil {
                return .failure(.forbiddenLiteral)
            }
        }

        guard text.unicodeScalars.count <= policy.maxScalars else { return .failure(.tooLong) }
        for scalar in text.unicodeScalars where !isAllowed(scalar) {
            return .failure(.disallowedCharacter)
        }
        if let failure = structuralFailure(in: text, policy: policy) {
            return .failure(failure)
        }
        return .success(text)
    }

    /// Convenience: the accepted text, or nil.
    public static func sanitize(_ raw: String, policy: Policy) -> String? {
        try? check(raw, policy: policy).get()
    }

    /// Filter a list, dropping every item that fails. Order is preserved.
    public static func sanitize(_ items: [String], policy: Policy) -> [String] {
        items.compactMap { sanitize($0, policy: policy) }
    }

    // MARK: - Rule 1: character-set whitelist

    /// CJK, kana, Latin letters, digits, space, and a deliberately small
    /// punctuation set. Everything else — `` / \ ` ~ $ { } < > | ^ * = @ + & ``
    /// and every symbol nobody enumerated — fails closed.
    ///
    /// `( ) [ ]` are allowed here because they are ordinary prose punctuation,
    /// and are neutralised for Markdown separately at render time. Character
    /// admission and structural escaping are different questions; answering
    /// them in one layer either kills normal sentences or misses injection.
    static func isAllowed(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x20:                     return true   // space
        case 0x30...0x39:              return true   // 0-9
        case 0x41...0x5A, 0x61...0x7A: return true   // A-Z a-z
        // ASCII punctuation subset: . , ; : ! ? ' " ( ) [ ] - #  %
        case 0x21, 0x22, 0x23, 0x25, 0x27, 0x28, 0x29,
             0x2C, 0x2D, 0x2E, 0x3A, 0x3B, 0x3F,
             0x5B, 0x5D:
            return true
        case 0x3000...0x303F:          return true   // CJK punctuation
        case 0x3040...0x30FF:          return true   // kana
        case 0x3400...0x4DBF:          return true   // CJK ext A
        case 0x4E00...0x9FFF:          return true   // CJK unified
        case 0xF900...0xFAFF:          return true   // CJK compatibility
        case 0xFF01...0xFF5E:          return true   // fullwidth forms
        case 0x2018, 0x2019, 0x201C, 0x201D,
             0x2013, 0x2014, 0x2026:
            return true                              // curly quotes, dashes, ellipsis
        default:                       return false
        }
    }

    // MARK: - Rules 2-4: structure

    private static func structuralFailure(in text: String, policy: Policy) -> Rejection? {
        if containsIPv4(text) { return .ipAddress }
        if containsDottedIdentifier(text) { return .dottedIdentifier }
        if hasStrayHash(text) { return .strayHash }
        if let bad = firstCodeIdentifier(in: text, properNouns: policy.properNouns) {
            _ = bad
            return .codeIdentifier
        }
        if containsHighEntropyRun(text) { return .highEntropy }
        return nil
    }

    /// Case-**sensitive** on purpose. Real credentials have fixed casing
    /// (`ghp_`, `AKIA`, `eyJ`), and matching case-insensitively would let a
    /// three-letter prefix like `xox` swallow ordinary words.
    static func firstSecretPrefix(in text: String) -> String? {
        secretPrefixes.first { text.contains($0) }
    }

    /// `10.0.0.1`. Checked before the dotted-identifier rule so the rejection
    /// reason is the specific one.
    static func containsIPv4(_ text: String) -> Bool {
        matches(text, #"\b\d{1,3}(\.\d{1,3}){3}\b"#)
    }

    /// A dot with a letter touching it — `foo.swift`, `api.example.com`, `a.b`.
    ///
    /// Requiring a *letter* rather than any word character is what keeps
    /// `2.5 小时` alive. Prose only ever puts a dot at the end of a sentence,
    /// where the next character is a space or nothing; decimals are the one
    /// legitimate mid-word dot and they are digits on both sides.
    static func containsDottedIdentifier(_ text: String) -> Bool {
        matches(text, #"[A-Za-z0-9]\.[A-Za-z]|[A-Za-z]\.[A-Za-z0-9]"#)
    }

    /// `#` survives only as an issue reference. It is the design's single
    /// documented exception channel because an issue number is the strongest
    /// anchor a reader has and is nothing but an integer.
    static func hasStrayHash(_ text: String) -> Bool {
        guard text.contains("#") else { return false }
        let stripped = replacing(text, #"#\d+"#, with: "")
        return stripped.contains("#")
    }

    /// camelCase or snake_case — the direct expression of "no code entity
    /// names". `_` cannot reach here (the character rule already rejected it),
    /// so this is the camel boundary plus digit-suffixed identifiers.
    static func firstCodeIdentifier(in text: String, properNouns: Set<String>) -> String? {
        let words = splitWords(text)
        for word in words where !properNouns.contains(word) {
            if matches(word, #"[a-z][A-Z]"#) { return word }
        }
        return nil
    }

    /// A long opaque run with mixed classes. English words do not look like
    /// this; base64 and hex secrets do.
    static func containsHighEntropyRun(_ text: String) -> Bool {
        for word in splitWords(text) where word.count >= 20 {
            let hasDigit = word.contains { $0.isNumber }
            let hasLetter = word.contains { $0.isLetter }
            if hasDigit && hasLetter { return true }
        }
        return false
    }

    // MARK: - Helpers

    static func splitWords(_ text: String) -> [String] {
        text.split { !($0.isLetter || $0.isNumber) }.map(String.init)
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return false }
        return re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func replacing(_ text: String, _ pattern: String, with template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        return re.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
}
