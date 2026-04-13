import Foundation

public struct HookInstaller {

    private let settingsPath: String
    private let bridgePath: String

    public init(
        settingsPath: String = NSHomeDirectory() + "/.claude/settings.json",
        bridgePath: String = "$HOME/.zackeyes/bin/bridge"
    ) {
        self.settingsPath = settingsPath
        self.bridgePath = bridgePath
    }

    // MARK: - Hook Config

    private static let hookEvents = [
        "PreToolUse",
        "PostToolUse",
        "PermissionRequest",
        "SessionStart",
        "SessionEnd",
        "Stop",
        "UserPromptSubmit",
        "Notification",
    ]

    private var hookConfig: [String: Any] {
        var config: [String: Any] = [:]
        for event in Self.hookEvents {
            config[event] = [
                [
                    "hooks": [
                        [
                            "type": "command",
                            "command": "\(bridgePath) --event \(event)",
                        ]
                    ]
                ]
            ]
        }
        return config
    }

    // MARK: - Install

    public func installHooks() throws {
        let claudeDir = (settingsPath as NSString).deletingLastPathComponent
        guard FileManager.default.fileExists(atPath: claudeDir) else {
            // Claude Code not installed — skip silently
            return
        }

        let settingsURL = URL(fileURLWithPath: settingsPath)
        var settings: [String: Any] = [:]

        if FileManager.default.fileExists(atPath: settingsPath) {
            guard let data = try? Data(contentsOf: settingsURL),
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                // JSON parse failure — don't touch the file
                return
            }
            settings = parsed

            // Create backup before any modification
            let timestamp = Int(Date().timeIntervalSince1970)
            let backupURL = settingsURL
                .deletingLastPathComponent()
                .appendingPathComponent("settings.json.backup.\(timestamp)")
            try data.write(to: backupURL)
        }

        // Get or create hooks dict
        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        // For each event: remove existing zackeyes entries, then append ours
        for (event, newEntries) in hookConfig {
            var existing = hooks[event] as? [[String: Any]] ?? []
            existing.removeAll { isZackEyesEntry($0) }
            let ourEntries = newEntries as! [[String: Any]]
            existing.append(contentsOf: ourEntries)
            hooks[event] = existing
        }

        settings["hooks"] = hooks

        // statusLine: Claude Code only supports ONE statusLine command.
        // If another tool (claude-hud, Vibe Island, etc.) already owns it,
        // install a multiplexer script that tees stdin to both our bridge
        // and the original command, passing the original's stdout through
        // so the terminal display is unchanged.
        if let existingStatusLine = settings["statusLine"] as? [String: Any],
           let cmd = existingStatusLine["command"] as? String,
           !cmd.contains("zackeyes") {
            // Another tool owns it — wrap with mux
            try deployStatusLineMux(originalCommand: cmd)
            settings["statusLine"] = [
                "type": "command",
                "command": statusLineMuxPath,
            ]
        } else {
            // No one else — install directly
            settings["statusLine"] = [
                "type": "command",
                "command": "\(bridgePath) --event StatusLine",
            ]
        }

        try writeSettings(settings, to: settingsURL)
    }

    // MARK: - Uninstall

    public func uninstallHooks() throws {
        let settingsURL = URL(fileURLWithPath: settingsPath)
        guard FileManager.default.fileExists(atPath: settingsPath),
              let data = try? Data(contentsOf: settingsURL),
              var settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return
        }

        guard var hooks = settings["hooks"] as? [String: Any] else { return }

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
            settings.removeValue(forKey: "hooks")
        } else {
            settings["hooks"] = hooks
        }

        // Remove statusLine if we own it (direct or mux)
        if let sl = settings["statusLine"] as? [String: Any],
           let cmd = sl["command"] as? String,
           cmd.contains("zackeyes") {
            // If mux was installed, restore the original command
            if let original = readMuxOriginalCommand() {
                settings["statusLine"] = [
                    "type": "command",
                    "command": original,
                ]
            } else {
                settings.removeValue(forKey: "statusLine")
            }
            // Clean up mux files
            try? FileManager.default.removeItem(atPath: statusLineMuxPath)
            try? FileManager.default.removeItem(atPath: statusLineMuxOriginalPath)
        }

        try writeSettings(settings, to: settingsURL)
    }

    // MARK: - Deploy Launcher Script

    public func deployLauncherScript(appPath: String) throws {
        let binDir = NSHomeDirectory() + "/.zackeyes/bin"
        try FileManager.default.createDirectory(
            atPath: binDir,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let bridgeURL = URL(fileURLWithPath: binDir + "/bridge")
        let helpersPath = appPath + "/Contents/Helpers/bridge"
        let script = """
            #!/bin/sh
            exec "\(helpersPath)" "$@"
            """
        try script.write(to: bridgeURL, atomically: true, encoding: .utf8)

        // chmod 755
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: bridgeURL.path
        )

        // Write app path marker
        let appPathFile = NSHomeDirectory() + "/.zackeyes/.app-path"
        try appPath.write(
            toFile: appPathFile,
            atomically: true,
            encoding: .utf8
        )
    }

    // MARK: - StatusLine Multiplexer

    private var statusLineMuxPath: String {
        NSHomeDirectory() + "/.zackeyes/bin/statusline-mux"
    }

    private var statusLineMuxOriginalPath: String {
        NSHomeDirectory() + "/.zackeyes/.statusline-original"
    }

    /// Deploy a mux script that tees stdin to both our bridge and the
    /// original statusLine command. The original's stdout passes through
    /// so the terminal display is unchanged.
    private func deployStatusLineMux(originalCommand: String) throws {
        let binDir = NSHomeDirectory() + "/.zackeyes/bin"
        try FileManager.default.createDirectory(
            atPath: binDir,
            withIntermediateDirectories: true,
            attributes: nil
        )

        // Save the original command so we can restore on uninstall
        try originalCommand.write(
            toFile: statusLineMuxOriginalPath,
            atomically: true,
            encoding: .utf8
        )

        // The mux script: read stdin once, fork to bridge in background,
        // then pipe the same input to the original command whose stdout
        // goes to Claude Code's terminal.
        let script = """
            #!/bin/sh
            INPUT=$(cat)
            echo "$INPUT" | "\(bridgePath)" --event StatusLine 2>/dev/null &
            echo "$INPUT" | \(originalCommand)
            """
        let muxURL = URL(fileURLWithPath: statusLineMuxPath)
        try script.write(to: muxURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: muxURL.path
        )
    }

    /// Read the original statusLine command saved during mux deployment.
    private func readMuxOriginalCommand() -> String? {
        try? String(contentsOfFile: statusLineMuxOriginalPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Helpers

    /// Returns true if any hook command in this entry contains "zackeyes" or
    /// matches the configured bridgePath (to support test paths lacking "zackeyes").
    private func isZackEyesEntry(_ entry: [String: Any]) -> Bool {
        guard let hooks = entry["hooks"] as? [[String: Any]] else { return false }
        return hooks.contains { hook in
            guard let command = hook["command"] as? String else { return false }
            return command.lowercased().contains("zackeyes") || command.contains(bridgePath)
        }
    }

    private func writeSettings(_ settings: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: url, options: .atomic)
    }
}
