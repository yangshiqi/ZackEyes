import Foundation

/// Decides whether a hook command in the user's config belongs to us.
///
/// This lives in one place on purpose. The rule was fixed on the Claude side
/// (#129/F-018: match the `~/.zackeyes/` path COMPONENT, not a bare "zackeyes"
/// substring an unrelated command could also contain) but the Codex installer
/// kept its own copy and never got the fix, so uninstall claimed a third-party
/// hook that merely lived under a similarly-named directory — and, once it
/// believed it owned every entry, deleted the whole file (#203).
///
/// Only the executable matters. Searching the whole command string keeps the
/// same bug in a narrower shape: `backup-tool "$HOME/.zackeyes/config.json"`
/// mentions our directory as an *argument* and is not ours. We always emit the
/// launcher as the first token, so that is the only place worth looking.
///
/// Wrong in the safe direction is a leftover entry; wrong in the unsafe
/// direction destroys the user's config, which invariant #1 forbids. When in
/// doubt, do not claim it.
enum HookOwnership {

    static func isOurs(command: String, bridgePath: String) -> Bool {
        guard let program = executableToken(of: command) else { return false }
        return program.contains("/.zackeyes/")
            || program == bridgePath
    }

    /// First real token of a shell command: leading `KEY=value` assignments
    /// skipped, surrounding quotes stripped.
    ///
    /// Deliberately not a shell parser — it recognises the shapes we emit and
    /// the ordinary ways a user might rewrite them (adding an env prefix,
    /// changing the quoting). Anything more exotic falls out as "not ours",
    /// which is the safe direction.
    static func executableToken(of command: String) -> String? {
        var rest = Substring(command)
        while true {
            rest = rest.drop(while: { $0 == " " || $0 == "\t" })
            guard let token = nextToken(&rest) else { return nil }
            // `FOO=bar cmd …` — an assignment, not the program.
            if let eq = token.firstIndex(of: "="),
               eq != token.startIndex,
               !token.prefix(upTo: eq).contains("/") {
                continue
            }
            return token
        }
    }

    private static func nextToken(_ rest: inout Substring) -> String? {
        guard let first = rest.first else { return nil }
        if first == "\"" || first == "'" {
            rest = rest.dropFirst()
            guard let end = rest.firstIndex(of: first) else { return nil }
            let token = String(rest[rest.startIndex..<end])
            rest = rest[rest.index(after: end)...]
            return token
        }
        let end = rest.firstIndex(where: { $0 == " " || $0 == "\t" }) ?? rest.endIndex
        let token = String(rest[rest.startIndex..<end])
        rest = rest[end...]
        return token.isEmpty ? nil : token
    }
}
