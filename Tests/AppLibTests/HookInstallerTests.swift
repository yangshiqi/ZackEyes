import Testing
import Foundation
@testable import AppLib

struct HookInstallerTests {

    private func makeTmpDir() throws -> URL {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        return tmpDir
    }

    private func writeExecutableScript(_ content: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try content.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path
        )
    }

    // MARK: - Test 1: mergeIntoEmptySettings

    @Test func mergeIntoEmptySettings() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let settingsURL = tmpDir.appendingPathComponent("settings.json")
        let initial = """
            {"permissions":{"allow":["Bash"]},"defaultMode":"default"}
            """
        try initial.write(to: settingsURL, atomically: true, encoding: .utf8)

        let installer = HookInstaller(
            settingsPath: settingsURL.path,
            bridgePath: "/test/bridge"
        )
        try installer.installHooks()

        let data = try Data(contentsOf: settingsURL)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        // Other keys must be preserved
        let permissions = json["permissions"] as? [String: Any]
        #expect(permissions != nil)
        let allow = permissions?["allow"] as? [String]
        #expect(allow == ["Bash"])
        #expect((json["defaultMode"] as? String) == "default")

        // hooks key must exist with the Claude lifecycle events we observe.
        let hooks = json["hooks"] as? [String: Any]
        #expect(hooks != nil)
        for event in ["PermissionRequest", "SessionStart", "PreToolUse",
                      "PostToolUse", "SessionEnd", "Stop",
                      "PreCompact", "PostCompact",
                      "SubagentStart", "SubagentStop"] {
            let entries = hooks?[event] as? [[String: Any]]
            #expect(entries != nil, "Missing event: \(event)")
            #expect((entries?.count ?? 0) >= 1)
        }
    }

    // MARK: - Test 2: preservesExistingHooks

    @Test func preservesExistingHooks() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let settingsURL = tmpDir.appendingPathComponent("settings.json")
        let initial = """
            {"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"other-tool --check"}]}]}}
            """
        try initial.write(to: settingsURL, atomically: true, encoding: .utf8)

        let installer = HookInstaller(
            settingsPath: settingsURL.path,
            bridgePath: "/test/bridge"
        )
        try installer.installHooks()

        let data = try Data(contentsOf: settingsURL)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        let hooks = json["hooks"] as? [String: Any]
        let preToolUseEntries = hooks?["PreToolUse"] as? [[String: Any]]
        #expect((preToolUseEntries?.count ?? 0) == 2)

        // First entry must be the original other-tool
        let firstEntry = preToolUseEntries?[0]
        let firstHooks = firstEntry?["hooks"] as? [[String: Any]]
        let firstCommand = firstHooks?.first?["command"] as? String
        #expect(firstCommand == "other-tool --check")
    }

    // MARK: - Test 3: createsBackup

    @Test func createsBackup() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let settingsURL = tmpDir.appendingPathComponent("settings.json")
        try "{}".write(to: settingsURL, atomically: true, encoding: .utf8)

        let installer = HookInstaller(
            settingsPath: settingsURL.path,
            bridgePath: "/test/bridge"
        )
        try installer.installHooks()

        let contents = try FileManager.default.contentsOfDirectory(atPath: tmpDir.path)
        let backupFiles = contents.filter { $0.hasPrefix("settings.json.backup.") }
        #expect(backupFiles.count >= 1)
    }

    // MARK: - Test 4: skipOnParseFailure

    @Test func skipOnParseFailure() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let settingsURL = tmpDir.appendingPathComponent("settings.json")
        let badContent = "not valid json {{{"
        try badContent.write(to: settingsURL, atomically: true, encoding: .utf8)

        let installer = HookInstaller(
            settingsPath: settingsURL.path,
            bridgePath: "/test/bridge"
        )

        // Must NOT throw
        try installer.installHooks()

        // File must be unchanged
        let result = try String(contentsOf: settingsURL, encoding: .utf8)
        #expect(result == badContent)
    }

    // MARK: - Test 5: mux installed when another statusLine exists

    @Test func installDeploysMuxWhenOtherStatusLineExists() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Pretend ~/.zackeyes lives inside tmpDir so mux files land there
        let zackDir = tmpDir.appendingPathComponent(".zackeyes")
        try FileManager.default.createDirectory(
            at: zackDir.appendingPathComponent("bin"),
            withIntermediateDirectories: true
        )

        let settingsURL = tmpDir.appendingPathComponent("settings.json")
        // Another tool already owns statusLine
        let initial = """
            {"statusLine":{"type":"command","command":"claude-hud --render"}}
            """
        try initial.write(to: settingsURL, atomically: true, encoding: .utf8)

        let installer = HookInstaller(
            settingsPath: settingsURL.path,
            bridgePath: zackDir.appendingPathComponent("bin/bridge").path
        )
        try installer.installHooks()

        // statusLine should now point to the mux script
        let data = try Data(contentsOf: settingsURL)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let sl = json["statusLine"] as? [String: Any]
        let cmd = sl?["command"] as? String ?? ""
        #expect(cmd.contains("statusline-mux"))

        // Mux script should exist and contain both commands
        let muxPath = zackDir.appendingPathComponent("bin/statusline-mux").path
        let muxContent = try String(contentsOfFile: muxPath, encoding: .utf8)
        #expect(muxContent.contains("bridge"))
        #expect(muxContent.contains("claude-hud --render"))

        // Original command should be saved
        let originalPath = zackDir.appendingPathComponent(".statusline-original").path
        let saved = try String(contentsOfFile: originalPath, encoding: .utf8)
        #expect(saved == "claude-hud --render")
    }

    @Test func installUsesUserStatusLineScriptWhenNoOtherStatusLineExists() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let zackDir = tmpDir.appendingPathComponent(".zackeyes")
        let bridgeURL = zackDir.appendingPathComponent("bin/bridge")
        let userStatusLineURL = zackDir.appendingPathComponent("bin/statusline-user")
        try writeExecutableScript(
            """
            #!/bin/sh
            cat >/dev/null
            exit 0
            """,
            to: bridgeURL
        )
        try writeExecutableScript(
            """
            #!/bin/sh
            INPUT=$(cat)
            printf 'user:%s\\n' "$INPUT"
            """,
            to: userStatusLineURL
        )

        let settingsURL = tmpDir.appendingPathComponent("settings.json")
        try "{}".write(to: settingsURL, atomically: true, encoding: .utf8)

        let installer = HookInstaller(
            settingsPath: settingsURL.path,
            bridgePath: bridgeURL.path
        )
        try installer.installHooks()

        let data = try Data(contentsOf: settingsURL)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let sl = json["statusLine"] as? [String: Any]
        let cmd = sl?["command"] as? String ?? ""
        let muxPath = zackDir.appendingPathComponent("bin/statusline-mux").path
        #expect(cmd == muxPath)

        let originalPath = zackDir.appendingPathComponent(".statusline-original").path
        #expect(!FileManager.default.fileExists(atPath: originalPath))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: muxPath)
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        try process.run()
        stdin.fileHandleForWriting.write(Data("payload".utf8))
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()

        let output = String(
            data: stdout.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )
        #expect(process.terminationStatus == 0)
        #expect(output == "user:payload\n")
    }

    @Test func reinstallSwitchesDirectBridgeStatusLineToUserMux() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let zackDir = tmpDir.appendingPathComponent(".zackeyes")
        let bridgeURL = zackDir.appendingPathComponent("bin/bridge")
        try writeExecutableScript(
            """
            #!/bin/sh
            cat >/dev/null
            exit 0
            """,
            to: bridgeURL
        )
        try writeExecutableScript(
            """
            #!/bin/sh
            printf 'custom\\n'
            """,
            to: zackDir.appendingPathComponent("bin/statusline-user")
        )

        let settingsURL = tmpDir.appendingPathComponent("settings.json")
        let initial = """
            {"statusLine":{"type":"command","command":"\(bridgeURL.path) --event StatusLine --agent claude"}}
            """
        try initial.write(to: settingsURL, atomically: true, encoding: .utf8)

        let installer = HookInstaller(
            settingsPath: settingsURL.path,
            bridgePath: bridgeURL.path
        )
        try installer.installHooks()

        let data = try Data(contentsOf: settingsURL)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let sl = json["statusLine"] as? [String: Any]
        let cmd = sl?["command"] as? String ?? ""
        #expect(cmd == zackDir.appendingPathComponent("bin/statusline-mux").path)
    }

    @Test func reinstallSwitchesUserMuxBackToDirectBridgeWhenUserScriptRemoved() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let zackDir = tmpDir.appendingPathComponent(".zackeyes")
        try FileManager.default.createDirectory(
            at: zackDir.appendingPathComponent("bin"),
            withIntermediateDirectories: true
        )

        let bridgePath = zackDir.appendingPathComponent("bin/bridge").path
        let muxPath = zackDir.appendingPathComponent("bin/statusline-mux").path
        let settingsURL = tmpDir.appendingPathComponent("settings.json")
        let initial = """
            {"statusLine":{"type":"command","command":"\(muxPath)"}}
            """
        try initial.write(to: settingsURL, atomically: true, encoding: .utf8)
        try "#!/bin/sh\nexit 0\n".write(
            toFile: muxPath,
            atomically: true,
            encoding: .utf8
        )

        let installer = HookInstaller(
            settingsPath: settingsURL.path,
            bridgePath: bridgePath
        )
        try installer.installHooks()

        let data = try Data(contentsOf: settingsURL)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let sl = json["statusLine"] as? [String: Any]
        let cmd = sl?["command"] as? String ?? ""
        #expect(cmd == "\(bridgePath) --event StatusLine --agent claude")
        #expect(!FileManager.default.fileExists(atPath: muxPath))
    }

    // MARK: - Test 6: uninstall restores original statusLine from mux

    @Test func uninstallRestoresOriginalStatusLine() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let zackDir = tmpDir.appendingPathComponent(".zackeyes")
        try FileManager.default.createDirectory(
            at: zackDir.appendingPathComponent("bin"),
            withIntermediateDirectories: true
        )

        let settingsURL = tmpDir.appendingPathComponent("settings.json")
        let initial = """
            {"statusLine":{"type":"command","command":"claude-hud --render"}}
            """
        try initial.write(to: settingsURL, atomically: true, encoding: .utf8)

        let installer = HookInstaller(
            settingsPath: settingsURL.path,
            bridgePath: zackDir.appendingPathComponent("bin/bridge").path
        )
        // Install (creates mux)
        try installer.installHooks()
        // Uninstall (should restore original)
        try installer.uninstallHooks()

        let data = try Data(contentsOf: settingsURL)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let sl = json["statusLine"] as? [String: Any]
        let cmd = sl?["command"] as? String
        #expect(cmd == "claude-hud --render")

        // Mux files should be cleaned up
        let muxExists = FileManager.default.fileExists(
            atPath: zackDir.appendingPathComponent("bin/statusline-mux").path
        )
        let origExists = FileManager.default.fileExists(
            atPath: zackDir.appendingPathComponent(".statusline-original").path
        )
        #expect(!muxExists)
        #expect(!origExists)
    }

    // MARK: - Test 6.5: command embeds `--agent claude` (codex-compat migration)

    /// After Codex compat lands, every hook command we install must embed
    /// `--agent claude`. The Bridge defaults to claude when the flag is
    /// missing (legacy compat), but explicit is better — and lets us
    /// distinguish events from co-installed agents at the top of Bridge.
    @Test func claudeCommandsEmbedAgentFlag() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let settingsURL = tmpDir.appendingPathComponent("settings.json")
        try "{}".write(to: settingsURL, atomically: true, encoding: .utf8)

        let installer = HookInstaller(
            settingsPath: settingsURL.path,
            bridgePath: "/test/bridge"
        )
        try installer.installHooks()

        let data = try Data(contentsOf: settingsURL)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let hooks = json["hooks"] as! [String: Any]

        for (event, raw) in hooks {
            let entries = raw as! [[String: Any]]
            for entry in entries {
                let inner = entry["hooks"] as! [[String: Any]]
                for hook in inner {
                    let cmd = hook["command"] as? String ?? ""
                    #expect(cmd.contains("--agent claude"),
                            "event=\(event) cmd=\(cmd) missing --agent claude")
                }
            }
        }

        // statusLine command must also embed it (direct install path).
        let sl = json["statusLine"] as? [String: Any]
        let slCmd = sl?["command"] as? String ?? ""
        #expect(slCmd.contains("--agent claude"))
    }

    // MARK: - Test 7: uninstall_removesOnlyOurEntries

    @Test func uninstall_removesOnlyOurEntries() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let settingsURL = tmpDir.appendingPathComponent("settings.json")
        try "{}".write(to: settingsURL, atomically: true, encoding: .utf8)

        let installer = HookInstaller(
            settingsPath: settingsURL.path,
            bridgePath: "/test/bridge"
        )
        try installer.installHooks()
        try installer.uninstallHooks()

        let data = try Data(contentsOf: settingsURL)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        // hooks key should be absent (was empty after removing our entries)
        #expect(json["hooks"] == nil)
    }

    // MARK: - Test 8: launcher resolves moved app via marker

    @Test func launcherUsesAppPathMarkerWhenInstalledAppMoved() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let zackDir = tmpDir.appendingPathComponent(".zackeyes")
        let originalApp = tmpDir.appendingPathComponent("Original.app")
        let movedApp = tmpDir.appendingPathComponent("Moved.app")
        let movedBridge = movedApp.appendingPathComponent("Contents/Helpers/bridge")
        try writeExecutableScript(
            """
            #!/bin/sh
            printf 'moved:%s:%s\\n' "$1" "$2"
            """,
            to: movedBridge
        )

        let installer = HookInstaller(
            settingsPath: tmpDir.appendingPathComponent("settings.json").path,
            bridgePath: zackDir.appendingPathComponent("bin/bridge").path
        )
        try installer.deployLauncherScript(appPath: originalApp.path)

        try movedApp.path.write(
            to: zackDir.appendingPathComponent(".app-path"),
            atomically: true,
            encoding: .utf8
        )

        let process = Process()
        process.executableURL = zackDir.appendingPathComponent("bin/bridge")
        process.arguments = ["--event", "SessionStart"]
        let stdout = Pipe()
        process.standardOutput = stdout
        try process.run()
        process.waitUntilExit()

        let output = String(
            data: stdout.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )
        #expect(process.terminationStatus == 0)
        #expect(output == "moved:--event:SessionStart\n")
    }

    // MARK: - Test 9: launcher has silent missing-app fallback

    @Test func launcherScriptFallsBackSilentlyWhenAppCannotBeFound() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let zackDir = tmpDir.appendingPathComponent(".zackeyes")
        let installer = HookInstaller(
            settingsPath: tmpDir.appendingPathComponent("settings.json").path,
            bridgePath: zackDir.appendingPathComponent("bin/bridge").path
        )
        try installer.deployLauncherScript(appPath: "/missing/ZackEyes.app")

        let launcher = try String(
            contentsOf: zackDir.appendingPathComponent("bin/bridge"),
            encoding: .utf8
        )
        #expect(launcher.contains("exit 0"))
        #expect(!launcher.contains("app not found"))
        #expect(!launcher.contains("exec \"/missing/ZackEyes.app/Contents/Helpers/bridge\" \"$@\""))
    }

    // MARK: - Test 10: reinstall preserves statusLine mux

    @Test func reinstallPreservesStatusLineMux() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let zackDir = tmpDir.appendingPathComponent(".zackeyes")
        try FileManager.default.createDirectory(
            at: zackDir.appendingPathComponent("bin"),
            withIntermediateDirectories: true
        )

        let settingsURL = tmpDir.appendingPathComponent("settings.json")
        let initial = """
            {"statusLine":{"type":"command","command":"claude-hud --render"}}
            """
        try initial.write(to: settingsURL, atomically: true, encoding: .utf8)

        let installer = HookInstaller(
            settingsPath: settingsURL.path,
            bridgePath: zackDir.appendingPathComponent("bin/bridge").path
        )
        try installer.installHooks()
        try installer.installHooks()

        let data = try Data(contentsOf: settingsURL)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let sl = json["statusLine"] as? [String: Any]
        let cmd = sl?["command"] as? String ?? ""
        #expect(cmd == zackDir.appendingPathComponent("bin/statusline-mux").path)

        let originalPath = zackDir.appendingPathComponent(".statusline-original").path
        let saved = try String(contentsOfFile: originalPath, encoding: .utf8)
        #expect(saved == "claude-hud --render")
    }

    // MARK: - Test 11: installs observation-only Claude lifecycle events

    @Test func installsObservationOnlyClaudeLifecycleEvents() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let settingsURL = tmpDir.appendingPathComponent("settings.json")
        try "{}".write(to: settingsURL, atomically: true, encoding: .utf8)

        let installer = HookInstaller(
            settingsPath: settingsURL.path,
            bridgePath: "/test/bridge"
        )
        try installer.installHooks()

        let data = try Data(contentsOf: settingsURL)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let hooks = json["hooks"] as? [String: Any]

        for event in ["PreCompact", "PostCompact", "SubagentStart", "SubagentStop"] {
            let entries = hooks?[event] as? [[String: Any]]
            #expect((entries?.count ?? 0) == 1, "Missing \(event)")
            let inner = entries?.first?["hooks"] as? [[String: Any]]
            let cmd = inner?.first?["command"] as? String ?? ""
            #expect(cmd == "/test/bridge --event \(event) --agent claude")
        }
    }
}
