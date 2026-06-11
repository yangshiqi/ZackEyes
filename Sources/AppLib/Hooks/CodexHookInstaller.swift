import Foundation

/// Installs ZackEyes hook entries into `~/.codex/hooks.json` so that the
/// OpenAI Codex CLI fires our bridge alongside Claude Code.
///
/// Mirrors `HookInstaller` (the Claude variant) in spirit — same defensive
/// invariants:
///
/// - Skip silently if `~/.codex/` doesn't exist (Codex isn't installed).
/// - Back up `hooks.json` before writing.
/// - Bail out without modifying the file on JSON parse failure.
/// - Append our entries; never touch other tools' hook entries.
/// - Mark our entries with `zackeyes` in the command so uninstall can match
///   them precisely.
///
/// We do **not** read or write `~/.codex/config.toml`. The `[features].hooks`
/// flag defaults to `true` in current Codex (verified against
/// `openai/codex` `codex-rs/features/src/lib.rs`), so a stand-alone
/// `hooks.json` is sufficient.
public struct CodexHookInstaller {

    private let hooksPath: String
    private let bridgePath: String

    public init(
        hooksPath: String = NSHomeDirectory() + "/.codex/hooks.json",
        bridgePath: String = "$HOME/.zackeyes/bin/bridge"
    ) {
        self.hooksPath = hooksPath
        self.bridgePath = bridgePath
    }

    // Codex defines six lifecycle hooks. There is no SessionEnd, no
    // Notification, and no StatusLine — those are Claude-only. Reference:
    // https://developers.openai.com/codex/hooks
    static let hookEvents = [
        "PreToolUse",
        "PostToolUse",
        "PermissionRequest",
        "SessionStart",
        "Stop",
        "UserPromptSubmit",
    ]

    private var hookConfig: [String: Any] {
        var config: [String: Any] = [:]
        for event in Self.hookEvents {
            config[event] = [
                [
                    "hooks": [
                        [
                            "type": "command",
                            "command": "\(bridgePath) --event \(event) --agent codex",
                        ]
                    ]
                ]
            ]
        }
        return config
    }

    // MARK: - Install

    public func installHooks() throws {
        let codexDir = (hooksPath as NSString).deletingLastPathComponent
        guard FileManager.default.fileExists(atPath: codexDir) else {
            // Codex not installed — skip silently
            return
        }

        let hooksURL = URL(fileURLWithPath: hooksPath)
        var doc: [String: Any] = [:]

        if FileManager.default.fileExists(atPath: hooksPath) {
            guard let data = try? Data(contentsOf: hooksURL),
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                // JSON parse failure — don't touch the file
                return
            }
            doc = parsed

            // Create backup before any modification
            let timestamp = Int(Date().timeIntervalSince1970)
            let backupURL = hooksURL
                .deletingLastPathComponent()
                .appendingPathComponent("hooks.json.backup.\(timestamp)")
            try data.write(to: backupURL)
        }

        // Codex hooks.json wraps under top-level "hooks" key (same shape as
        // Claude's settings.json, so the merge logic is identical).
        var hooks = doc["hooks"] as? [String: Any] ?? [:]

        for (event, newEntries) in hookConfig {
            var existing = hooks[event] as? [[String: Any]] ?? []
            existing.removeAll { isZackEyesEntry($0) }
            let ourEntries = newEntries as! [[String: Any]]
            existing.append(contentsOf: ourEntries)
            hooks[event] = existing
        }

        doc["hooks"] = hooks

        try writeHooks(doc, to: hooksURL)
    }

    // MARK: - Uninstall

    public func uninstallHooks() throws {
        let hooksURL = URL(fileURLWithPath: hooksPath)
        guard FileManager.default.fileExists(atPath: hooksPath),
              let data = try? Data(contentsOf: hooksURL),
              var doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return
        }

        guard var hooks = doc["hooks"] as? [String: Any] else { return }

        for event in Self.hookEvents {
            guard var entries = hooks[event] as? [[String: Any]] else { continue }
            entries.removeAll { isZackEyesEntry($0) }
            if entries.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = entries
            }
        }

        if hooks.isEmpty {
            doc.removeValue(forKey: "hooks")
        } else {
            doc["hooks"] = hooks
        }

        // If the doc is now empty (we owned the entire hooks.json), delete the
        // file rather than leaving an empty `{}` dangling.
        if doc.isEmpty {
            try FileManager.default.removeItem(at: hooksURL)
            return
        }

        try writeHooks(doc, to: hooksURL)
    }

    // MARK: - Helpers

    /// True when any hook command in this entry contains "zackeyes" or matches
    /// the configured bridgePath (so test fixtures using paths without the
    /// "zackeyes" substring still match).
    func isZackEyesEntry(_ entry: [String: Any]) -> Bool {
        guard let hooks = entry["hooks"] as? [[String: Any]] else { return false }
        return hooks.contains { hook in
            guard let command = hook["command"] as? String else { return false }
            return command.lowercased().contains("zackeyes") || command.contains(bridgePath)
        }
    }

    private func writeHooks(_ doc: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(
            withJSONObject: doc,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: url, options: .atomic)
    }
}
