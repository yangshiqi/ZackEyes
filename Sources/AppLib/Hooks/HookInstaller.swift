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

    static let hookEvents = [
        "PreToolUse",
        "PostToolUse",
        "PermissionRequest",
        "SessionStart",
        "SessionEnd",
        "Stop",
        "UserPromptSubmit",
        "Notification",
        "PreCompact",
        "PostCompact",
        "SubagentStart",
        "SubagentStop",
    ]

    private var hookConfig: [String: Any] {
        var config: [String: Any] = [:]
        for event in Self.hookEvents {
            config[event] = [
                [
                    "hooks": [
                        [
                            "type": "command",
                            "command": bridgeCommand(event: event),
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
        var originalSettings: [String: Any]?
        var originalData: Data?

        if FileManager.default.fileExists(atPath: settingsPath) {
            guard let data = try? Data(contentsOf: settingsURL),
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                // JSON parse failure — don't touch the file
                return
            }
            settings = parsed
            originalSettings = parsed
            originalData = data
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
           let cmd = existingStatusLine["command"] as? String {
            if isStatusLineMuxCommand(cmd) {
                if let original = readMuxOriginalCommand() {
                    try deployStatusLineMux(originalCommand: original)
                    settings["statusLine"] = [
                        "type": "command",
                        "command": statusLineMuxCommand,
                    ]
                } else if hasUserStatusLineScript {
                    try deployStatusLineMux(originalCommand: nil)
                    settings["statusLine"] = [
                        "type": "command",
                        "command": statusLineMuxCommand,
                    ]
                } else {
                    cleanupStatusLineMuxFiles()
                    settings["statusLine"] = [
                        "type": "command",
                        "command": bridgeCommand(event: "StatusLine"),
                    ]
                }
            } else if !isZackEyesCommand(cmd) {
                // Another tool owns it — wrap with mux
                try deployStatusLineMux(originalCommand: cmd)
                settings["statusLine"] = [
                    "type": "command",
                    "command": statusLineMuxCommand,
                ]
            } else if hasUserStatusLineScript {
                try deployStatusLineMux(originalCommand: nil)
                settings["statusLine"] = [
                    "type": "command",
                    "command": statusLineMuxCommand,
                ]
            } else {
                // No one else — install directly
                settings["statusLine"] = [
                    "type": "command",
                    "command": bridgeCommand(event: "StatusLine"),
                ]
            }
        } else if hasUserStatusLineScript {
            try deployStatusLineMux(originalCommand: nil)
            settings["statusLine"] = [
                "type": "command",
                "command": statusLineMuxCommand,
            ]
        } else {
            // No one else — install directly
            settings["statusLine"] = [
                "type": "command",
                "command": bridgeCommand(event: "StatusLine"),
            ]
        }

        // No-op guard: a re-install that changes nothing must not spawn a
        // backup file or rewrite settings.json (Repair button + every app
        // launch would otherwise pile up identical backups).
        if let originalSettings,
           NSDictionary(dictionary: settings).isEqual(to: originalSettings) {
            return
        }

        if let originalData {
            let timestamp = Int(Date().timeIntervalSince1970)
            let backupURL = settingsURL
                .deletingLastPathComponent()
                .appendingPathComponent("settings.json.backup.\(timestamp)")
            try originalData.write(to: backupURL)
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

        let originalSettings = settings

        if var hooks = settings["hooks"] as? [String: Any] {
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
            cleanupStatusLineMuxFiles()
        }

        // No-op guard: if removing our entries changed nothing, skip backup and write.
        if NSDictionary(dictionary: settings).isEqual(to: originalSettings) {
            return
        }

        try data.write(to: settingsURL
            .deletingLastPathComponent()
            .appendingPathComponent(
                "settings.json.backup.\(Int(Date().timeIntervalSince1970))"
            ))

        try writeSettings(settings, to: settingsURL)
    }

    // MARK: - Deploy Launcher Script

    public func deployLauncherScript(appPath: String) throws {
        // Create ~/.zackeyes and ~/.zackeyes/bin owner-only (0700). Default
        // (umask) mode leaves them group/other-readable, yet the launcher here is
        // exec'd on every agent hook fire and the .app-path marker steers that
        // exec. Locking the subtree to the owner closes the cross-uid surface
        // (T-1 / T-7). NOTE: this does NOT stop a same-uid attacker, who owns
        // these files — the same-uid close needs Developer-ID + notarization (#135).
        let fm = FileManager.default
        try fm.createDirectory(
            atPath: zackDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fm.createDirectory(
            atPath: binDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: zackDir)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binDir)

        let escapedAppPath = shellDoubleQuoted(appPath)
        let escapedMarkerPath = shellDoubleQuoted(zackDir + "/.app-path")
        let script = """
            #!/bin/sh
            # auto-generated by ZackEyes; do not edit
            H="/Contents/Helpers/bridge"
            C="\(escapedMarkerPath)"

            try_app() {
              P="$1"
              shift
              [ -n "$P" ] || return 1
              B="${P}${H}"
              [ -x "$B" ] || return 1
              printf '%s\\n' "$P" > "$C" 2>/dev/null
              exec "$B" "$@" 2>/dev/null || exit 0
            }

            if [ -f "$C" ]; then
              IFS= read -r P < "$C"
              try_app "$P" "$@"
            fi

            for P in "\(escapedAppPath)" "/Applications/ZackEyes.app" "$HOME/Applications/ZackEyes.app"; do
              try_app "$P" "$@"
            done

            if [ -x /usr/bin/mdfind ]; then
              P="$(/usr/bin/mdfind 'kMDItemCFBundleIdentifier == "app.zackeyes.macos"' 2>/dev/null | /usr/bin/head -n 1)"
              try_app "$P" "$@"
            fi

            exit 0
            """
        try deployScript(content: script, to: binDir + "/bridge", permissions: 0o700)

        // Write app path marker owner-only (0600) — mirrors the deliberate 0600
        // lock on the socket node; default write leaves it world-readable (0644).
        let markerPath = zackDir + "/.app-path"
        try appPath.write(toFile: markerPath, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: markerPath)
    }

    // MARK: - StatusLine Multiplexer

    /// bridgePath with `$HOME` expanded so FileManager can use it.
    /// The default bridgePath is `$HOME/.zackeyes/bin/bridge` — fine
    /// for shell scripts in settings.json (the shell expands `$HOME`),
    /// but FileManager needs a real absolute path.
    private var expandedBridgePath: String {
        bridgePath.replacingOccurrences(of: "$HOME", with: NSHomeDirectory())
    }

    /// Derived from expandedBridgePath so tests can point to a tmpDir.
    private var binDir: String {
        (expandedBridgePath as NSString).deletingLastPathComponent
    }

    private var zackDir: String {
        (binDir as NSString).deletingLastPathComponent
    }

    private var statusLineMuxPath: String {
        binDir + "/statusline-mux"
    }

    private var statusLineMuxCommand: String {
        quotedShellPath(statusLineMuxPath)
    }

    private var statusLineMuxOriginalPath: String {
        zackDir + "/.statusline-original"
    }

    private var statusLineUserPath: String {
        binDir + "/statusline-user"
    }

    private var hasUserStatusLineScript: Bool {
        FileManager.default.isExecutableFile(atPath: statusLineUserPath)
    }

    /// Deploy a mux script that tees stdin to both our bridge and the
    /// original statusLine command. The original's stdout passes through
    /// so the terminal display is unchanged. Forks bridge per tick
    /// (~5ms overhead on macOS, acceptable for a ~2-5s interval).
    private func deployStatusLineMux(originalCommand: String?) throws {
        try FileManager.default.createDirectory(
            atPath: binDir,
            withIntermediateDirectories: true,
            attributes: nil
        )

        if let originalCommand {
            // Save the original command so we can restore on uninstall
            try originalCommand.write(
                toFile: statusLineMuxOriginalPath,
                atomically: true,
                encoding: .utf8
            )
        } else {
            try? FileManager.default.removeItem(atPath: statusLineMuxOriginalPath)
        }

        // originalCommand is interpolated raw (not quoted) when present —
        // it's a full shell command string, evaluated the same way Claude
        // Code does. Without an original command, an executable
        // statusline-user script becomes the visible statusLine renderer.
        let displayCommand: String
        if let originalCommand {
            displayCommand = """
                printf '%s\\n' "$INPUT" | \(originalCommand)
                """
        } else {
            let userCommand = quotedShellPath(statusLineUserPath)
            displayCommand = """
                if [ -x \(userCommand) ]; then
                  printf '%s\\n' "$INPUT" | \(userCommand)
                fi
                """
        }
        let script = """
            #!/bin/sh
            INPUT=$(cat)
            printf '%s\\n' "$INPUT" | \(quotedShellPath(bridgePath)) --event StatusLine --agent claude 2>/dev/null &
            \(displayCommand)
            """
        try deployScript(content: script, to: statusLineMuxPath)
    }

    private func cleanupStatusLineMuxFiles() {
        try? FileManager.default.removeItem(atPath: statusLineMuxPath)
        try? FileManager.default.removeItem(atPath: statusLineMuxOriginalPath)
    }

    /// Write a shell script to disk and set its mode (default 0o755).
    /// The hook launcher passes 0o700 so the file directly exec'd on every hook
    /// fire is not group/other readable or writable (T-1).
    private func deployScript(content: String, to path: String, permissions: Int = 0o755) throws {
        let url = URL(fileURLWithPath: path)
        try content.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: permissions], ofItemAtPath: url.path
        )
    }

    /// Read the original statusLine command saved during mux deployment.
    private func readMuxOriginalCommand() -> String? {
        try? String(contentsOfFile: statusLineMuxOriginalPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Helpers

    /// Read-only classification of a settings.json statusLine command.
    /// Mirrors the ownership branching in installHooks() so the Hook Status
    /// surface reports exactly the state the installer would act on.
    func statusLineMode(of command: String?) -> HookHealthReport.StatusLineMode {
        guard let command else { return .absent }
        if isStatusLineMuxCommand(command) {
            if readMuxOriginalCommand() != nil { return .mux }
            if hasUserStatusLineScript { return .userRenderer }
            // Degenerate mux (no original, no user script) — installHooks
            // would normalize this to direct; report the wrapper as mux.
            return .mux
        }
        if isZackEyesCommand(command) { return .direct }
        return .thirdParty(command: command)
    }

    private func isStatusLineMuxCommand(_ command: String) -> Bool {
        command == statusLineMuxPath || command == statusLineMuxCommand
    }

    private func isZackEyesCommand(_ command: String) -> Bool {
        command.lowercased().contains("zackeyes")
            || command.contains(bridgePath)
            || command.contains(quotedShellPath(bridgePath))
    }

    private func bridgeCommand(event: String) -> String {
        "\(quotedShellPath(bridgePath)) --event \(event) --agent claude"
    }

    private func quotedShellPath(_ value: String) -> String {
        let homePrefix = "$HOME/"
        if value.hasPrefix(homePrefix) {
            let suffix = String(value.dropFirst(homePrefix.count))
            return "\"$HOME/\(shellDoubleQuoted(suffix))\""
        }
        return "\"\(shellDoubleQuoted(value))\""
    }

    private func shellDoubleQuoted(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "`", with: "\\`")
    }

    /// Returns true if any hook command in this entry contains "zackeyes" or
    /// matches the configured bridgePath (to support test paths lacking "zackeyes").
    func isZackEyesEntry(_ entry: [String: Any]) -> Bool {
        guard let hooks = entry["hooks"] as? [[String: Any]] else { return false }
        return hooks.contains { hook in
            guard let command = hook["command"] as? String else { return false }
            return isZackEyesCommand(command)
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
