import Foundation

/// Pure, user-config-zero-touch text scrubbing for the diagnostics export
/// (#47). Collapses the home directory to `~` and replaces the macOS
/// username with `<user>` so a report is safe to attach to a public issue.
/// No I/O — values are injected so this is fully testable.
public struct Redactor: Sendable {

    private let homeDirectory: String
    private let username: String

    public init(
        homeDirectory: String = NSHomeDirectory(),
        username: String = NSUserName()
    ) {
        self.homeDirectory = homeDirectory
        self.username = username
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
        if !username.isEmpty {
            out = out.replacingOccurrences(of: username, with: "<user>")
        }
        return out
    }

    public func redactOptional(_ text: String?) -> String? {
        guard let text else { return nil }
        return redact(text)
    }
}
