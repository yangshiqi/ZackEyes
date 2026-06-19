import Foundation

/// Pure, user-config-zero-touch text scrubbing for the diagnostics export
/// (#47). Collapses the home directory to `~` and replaces the macOS
/// username with `<user>` so a report is safe to attach to a public issue.
/// No I/O — values are injected so this is fully testable.
public struct Redactor: Sendable {

    private let homeDirectory: String
    private let username: String
    private let hostName: String

    public init(
        homeDirectory: String = NSHomeDirectory(),
        username: String = NSUserName(),
        hostName: String = ProcessInfo.processInfo.hostName
    ) {
        self.homeDirectory = homeDirectory
        self.username = username
        self.hostName = hostName
    }

    /// Redact a string: home-dir prefix → `~`, then any remaining bare
    /// username occurrences → `<user>`. Order matters — the home collapse
    /// runs first so `/Users/<user>/...` becomes `~/...` rather than
    /// `/Users/<user>/...` with a dangling redaction.
    public func redact(_ text: String) -> String {
        var out = text
        if !homeDirectory.isEmpty {
            out = out.replacingOccurrences(of: homeDirectory, with: "~")
        }
        // Empty username would replace between every character — guard it.
        // A very short real username (e.g. "a") may over-redact unrelated
        // text ("arm64" → "<user>rm64"). That is intentional and SAFE —
        // over-redaction, never under-redaction. Do NOT add a min-length
        // guard to "fix" cosmetics: skipping redaction for a short real
        // username would leak it, the opposite of this feature's promise.
        if !username.isEmpty {
            // Case-insensitive: a report may echo the username in any case
            // (#129/F-016). Over-redaction is safe; never under-redact.
            out = out.replacingOccurrences(
                of: username, with: "<user>", options: .caseInsensitive)
        }
        // Hostname can leak via paths / URLs / identifiers (#129/F-020). Redact it
        // and its `.local` Bonjour form — but only as a WHOLE word (\b…\b), so a
        // short hostname (`mac`) doesn't rewrite substrings of fixed report text
        // (`macOS`, `arm64`) the way the username redaction can (Codex review #142).
        let hostBase = hostName.hasSuffix(".local") ? String(hostName.dropLast(6)) : hostName
        for h in [hostName, hostBase] where !h.isEmpty {
            out = Self.redactWord(h, in: out)
        }
        return out
    }

    /// Replace whole-word, case-insensitive occurrences of `word` with `<host>`.
    private static func redactWord(_ word: String, in text: String) -> String {
        let pattern = "\\b" + NSRegularExpression.escapedPattern(for: word) + "\\b"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return text }
        return re.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "<host>")
    }

    public func redactOptional(_ text: String?) -> String? {
        guard let text else { return nil }
        return redact(text)
    }
}
