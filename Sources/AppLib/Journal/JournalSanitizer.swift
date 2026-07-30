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
        // Mixed-case product names the acronym rule would otherwise eat.
        // Each one verified to actually trip a rule — `IPv6` was in this list
        // briefly and did not need to be, because `v6` is one lowercase letter
        // and the acronym rule requires two.
        "OAuth", "OAuth2", "OpenAPI", "OpenSSL", "OpenTelemetry",
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

        /// Policy terms are normalized on the way in so they live in the same
        /// compatibility-mapped domain as the text they are matched against.
        /// Otherwise the normalization that closed the fullwidth bypass opens
        /// two new ones in the other direction: a fullwidth username stops
        /// matching (a leak), and a fullwidth project alias stops being
        /// recognised as a proper noun (a silent false positive — and a CJK
        /// IME produces fullwidth Latin by accident all the time).
        public init(
            maxScalars: Int,
            properNouns: Set<String> = JournalSanitizer.defaultProperNouns,
            forbiddenLiterals: [String] = []
        ) {
            self.maxScalars = maxScalars
            self.properNouns = Set(properNouns.map(\.precomposedStringWithCompatibilityMapping))
            self.forbiddenLiterals =
                forbiddenLiterals.map(\.precomposedStringWithCompatibilityMapping)
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
        case percentEncoded
        case phoneNumber
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

        // Inspect a compatibility-normalized copy, return the original.
        //
        // Without this the whitelist has a hole the size of a path: the
        // fullwidth block admitted for CJK punctuation (`（），`) also contains
        // fullwidth ASCII — `／` `．` `＄` `｛` `｜` and the entire Latin
        // alphabet `ａ-ｚＡ-Ｚ`. `／Users／alice`, `测试．swift` and `ｇｅｔＵｓｅｒ`
        // all sailed through every structural rule, because those rules match
        // ASCII. NFKC folds the confusables back so one set of rules covers
        // both forms.
        //
        // The original is what gets returned and written, so callers still get
        // exactly what the model wrote — normalization is for judging, not for
        // rewriting.
        let probe = text.precomposedStringWithCompatibilityMapping

        // Credential and identity checks run FIRST, ahead of the character
        // whitelist. Most real tokens (`ghp_…`) would also trip the character
        // rule, but reporting `disallowedCharacter` for a leaked key makes the
        // run record useless for the one case anyone would want to grep for.
        if firstSecretPrefix(in: probe) != nil { return .failure(.secretPrefix) }
        for literal in policy.forbiddenLiterals where !literal.isEmpty {
            if probe.range(of: literal, options: .caseInsensitive) != nil {
                return .failure(.forbiddenLiteral)
            }
        }

        // Both lengths: the original is what lands in the file, but NFKC can
        // expand (`㍿` → `株式会社`), so a short-looking item must not be able
        // to smuggle a long one past the budget either.
        guard text.unicodeScalars.count <= policy.maxScalars,
              probe.unicodeScalars.count <= policy.maxScalars
        else { return .failure(.tooLong) }

        for scalar in probe.unicodeScalars where !isAllowed(scalar) {
            return .failure(.disallowedCharacter)
        }
        if let failure = structuralFailure(in: probe, policy: policy) {
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
        if containsPercentEncoding(text) { return .percentEncoded }
        if containsIPv4(text) || containsIPv6(text) { return .ipAddress }
        if containsPhoneNumber(text) { return .phoneNumber }
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

    /// Percent-encoding is never prose. It is also the cheapest way to smuggle
    /// a credential past every other rule — `%67%68%70%5F…` is `ghp_…` with
    /// each character hidden behind a `%`, short enough that no run looks
    /// opaque and containing no dot, no camel boundary and no known prefix.
    ///
    /// `%` itself stays legal so `提升了 30%` survives; it is the `%XX` shape
    /// that is rejected.
    static func containsPercentEncoding(_ text: String) -> Bool {
        matches(text, #"%[0-9A-Fa-f]{2}"#)
    }

    /// `10.0.0.1`. Checked before the dotted-identifier rule so the rejection
    /// reason is the specific one.
    static func containsIPv4(_ text: String) -> Bool {
        matches(text, #"\b\d{1,3}(\.\d{1,3}){3}\b"#)
    }

    /// `2001:0db8:85a3::7334`. The design names IP addresses as a threat and
    /// only v4 was implemented; a v6 literal has no dots at all, so every
    /// dot-based rule misses it by construction.
    ///
    /// Scanned as whole tokens rather than by regex, because NFKC folds the
    /// fullwidth colon `：` — which is ordinary Chinese punctuation — into
    /// `:`. A colon-counting pattern would therefore reject any Chinese
    /// sentence with two clauses.
    ///
    /// Two colons alone are not enough either: `12:30:45` is a time. The
    /// qualifier is a compressed `::`, a hex letter, or four or more colons,
    /// none of which a clock produces.
    static func containsIPv6(_ text: String) -> Bool {
        // Maximal runs, not whitespace tokens. Splitting on spaces made a
        // trailing comma (`2001:db8::1,`) or a zone suffix (`fe80::1%en0`)
        // enough to hide the whole address, because the token then held a
        // character outside the allowed set and was skipped entirely.
        for run in maximalRuns(in: text, where: { $0.isHexDigit || $0 == ":" }) {
            guard run.contains(":"), run.contains(where: \.isHexDigit) else { continue }
            let colons = run.filter { $0 == ":" }.count
            guard colons >= 2 else { continue }
            if run.contains("::") || run.contains(where: \.isLetter) || colons >= 4 {
                return true
            }
        }
        return false
    }

    /// A phone number is the one piece of personal data a character rule can
    /// actually recognise. A person's *name* is not — "Jane Smith" is
    /// indistinguishable from any other two capitalised words, which is why
    /// the design puts customer identity behind the project alias/exclusion
    /// table rather than pretending this layer can catch it.
    ///
    /// Matches the *shape* — grouped digits separated by spaces, dashes or
    /// parentheses — and deliberately **not** a bare run of digits. A bare run
    /// was the first attempt and it rejected `Processed 1000000000 rows`,
    /// which is fatal for a journal whose whole subject is token counts. A
    /// large number is not a leak; a grouped one is a phone number.
    static func containsPhoneNumber(_ text: String) -> Bool {
        matches(text, #"\(?\d{3}\)?[ -]\d{3}[ -]\d{4}\b"#)
    }

    /// A dot with a letter touching it — `foo.swift`, `api.example.com`,
    /// `测试.swift`.
    ///
    /// Letters are matched by Unicode property, not by `A-Za-z`: an ASCII-only
    /// class misses `测试.swift`, which is a filename in exactly the codebase
    /// this journal is written about.
    ///
    /// The rule is "a letter on one side, a letter or digit on the other", so
    /// the one legitimate mid-word dot — a decimal, digits on both sides —
    /// survives. Prose otherwise only puts a dot at the end of a sentence,
    /// where the next character is a space or nothing.
    /// Requires a run of **two or more** letters on one side, so the ordinary
    /// English abbreviations `e.g.` and `i.e.` survive. Single letters either
    /// side of a dot are an abbreviation; a name has a real word in it.
    static func containsDottedIdentifier(_ text: String) -> Bool {
        matches(text, #"\p{L}{2,}\.[\p{L}\p{N}]|[\p{L}\p{N}]\.\p{L}{2,}"#)
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
    /// Two shapes, because `[a-z][A-Z]` alone misses the commonest naming
    /// style in this very codebase:
    ///
    /// - `sessionStore` — lower-to-upper, the classic camel boundary.
    /// - `APIClient` — an acronym prefix, where the boundary is upper-to-upper.
    ///   `URLSession`, `JSONDecoder`, `HTTPServer` all have this shape and all
    ///   walked straight through the first rule.
    ///
    /// The acronym rule demands **two or more** trailing lowercase letters so
    /// that `APIs` and `IDs` survive — those are ordinary English plurals a
    /// developer's journal will contain, and killing them is the silent
    /// false-positive failure this sanitizer is most at risk of.
    static func firstCodeIdentifier(in text: String, properNouns: Set<String>) -> String? {
        for word in splitWords(text) where !properNouns.contains(word) {
            if matches(word, #"[a-z][A-Z]"#) { return word }
            if matches(word, #"[A-Z]{2,}[a-z]{2,}"#) { return word }
        }
        return nil
    }

    /// A long opaque run with mixed classes. English words do not look like
    /// this; base64 and hex secrets do.
    ///
    /// Checked over whitespace-delimited tokens as well as word characters,
    /// because `-` is legal punctuation and splitting on it turns a UUID into
    /// five short, innocent-looking pieces.
    /// Restricted to **ASCII** tokens, which is not a tuning choice — it is the
    /// difference between working and eating the journal.
    ///
    /// Chinese has no word separators, so `splitWords` returns an entire
    /// sentence as one "word"; and Swift's `isNumber` is true for CJK numerals
    /// (`三`, `十`, `百` all carry a Unicode numeric type). Together those made
    /// every Chinese sentence of sixteen or more characters containing a
    /// numeral look like a mixed-class opaque run — which is most real Chinese
    /// work notes, in a feature whose primary language is Chinese.
    ///
    /// Nothing is lost by the restriction: base64 and hex are ASCII by
    /// definition, so a CJK run was never a secret.
    static func containsHighEntropyRun(_ text: String) -> Bool {
        for word in splitWords(text)
        where word.count >= 16 && word.allSatisfy(\.isASCII) {
            if isMixedClass(word) { return true }
        }
        return containsHyphenatedHexRun(text)
    }

    /// A UUID survives every other rule: `-` is legal punctuation, so word
    /// splitting turns it into five short innocent pieces before the opaque-run
    /// check ever sees it.
    ///
    /// Every segment must be hex, which is what separates `123e4567-e89b-…`
    /// from `2026-07-30-release-candidate` — a hyphenated label that a first
    /// attempt at this rule rejected. A release name is words; a UUID is not.
    static func containsHyphenatedHexRun(_ text: String) -> Bool {
        for run in maximalRuns(in: text, where: { $0.isHexDigit || $0 == "-" }) {
            guard run.count >= 20 else { continue }
            let segments = run.split(separator: "-")
            guard segments.count >= 3,
                  segments.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isHexDigit) })
            else { continue }
            return true
        }
        return false
    }

    private static func isMixedClass(_ s: String) -> Bool {
        s.contains { $0.isNumber } && s.contains { $0.isLetter }
    }

    /// Longest stretches satisfying `predicate`, ignoring what surrounds them.
    static func maximalRuns(in text: String, where predicate: (Character) -> Bool) -> [String] {
        var runs: [String] = []
        var current = ""
        for ch in text {
            if predicate(ch) {
                current.append(ch)
            } else if !current.isEmpty {
                runs.append(current)
                current = ""
            }
        }
        if !current.isEmpty { runs.append(current) }
        return runs
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
