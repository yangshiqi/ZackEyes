import Testing
import Foundation
@testable import AppLib

struct IntegrationUninstallerTests {

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

    /// Build a hermetic IntegrationUninstaller whose paths all live in tmpDir.
    private func makeUninstaller(tmpDir: URL) -> IntegrationUninstaller {
        IntegrationUninstaller(
            claudeSettingsPath: tmpDir.appendingPathComponent(".claude/settings.json").path,
            codexHooksPath: tmpDir.appendingPathComponent(".codex/hooks.json").path,
            bridgePath: tmpDir.appendingPathComponent(".zackeyes/bin/bridge").path
        )
    }

    /// Run the REAL installers inside tmpDir so fixture output exactly matches
    /// what install writes (no drift risk).
    private func fullInstall(tmpDir: URL) throws {
        let claudeDir = tmpDir.appendingPathComponent(".claude")
        let codexDir = tmpDir.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
        let bridgePath = tmpDir.appendingPathComponent(".zackeyes/bin/bridge").path
        let settingsPath = claudeDir.appendingPathComponent("settings.json").path
        let hooksPath = codexDir.appendingPathComponent("hooks.json").path
        try HookInstaller(settingsPath: settingsPath, bridgePath: bridgePath).installHooks()
        try CodexHookInstaller(hooksPath: hooksPath, bridgePath: bridgePath).installHooks()
    }

    private func backupFiles(in dir: URL, prefix: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix(prefix) }
    }

    // MARK: - Test 1: previewListsOwnedEntriesAndFiles

    @Test func previewListsOwnedEntriesAndFiles() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Full install
        try fullInstall(tmpDir: tmpDir)

        let bridgePath = tmpDir.appendingPathComponent(".zackeyes/bin/bridge").path
        let settingsPath = tmpDir.appendingPathComponent(".claude/settings.json").path
        let zackDir = tmpDir.appendingPathComponent(".zackeyes")
        let appPath = tmpDir.appendingPathComponent("ZackEyes.app").path

        // Deploy launcher script (creates bridge + .app-path)
        try HookInstaller(settingsPath: settingsPath, bridgePath: bridgePath)
            .deployLauncherScript(appPath: appPath)

        // Create a pending/ directory with one file inside
        let pendingDir = zackDir.appendingPathComponent("pending")
        try FileManager.default.createDirectory(at: pendingDir, withIntermediateDirectories: true)
        try "data".write(
            to: pendingDir.appendingPathComponent("item.json"),
            atomically: true, encoding: .utf8)

        // Create statusline-user (user-authored, must NOT appear in files)
        try writeExecutableScript(
            "#!/bin/sh\ncat\n",
            to: zackDir.appendingPathComponent("bin/statusline-user"))

        let plan = makeUninstaller(tmpDir: tmpDir).preview()

        #expect(plan.claudeHookEvents == 12)
        #expect(plan.claudeOwnsStatusLine == true)
        #expect(plan.codexHookEvents == 6)

        // bridge and .app-path must appear
        #expect(plan.files.contains(bridgePath))
        #expect(plan.files.contains(zackDir.appendingPathComponent(".app-path").path))
        // pending directory must appear
        #expect(plan.files.contains(pendingDir.path))

        // statusline-user must NOT appear
        let userScript = zackDir.appendingPathComponent("bin/statusline-user").path
        #expect(!plan.files.contains(userScript))
    }

    // MARK: - Test 2: previewOnCleanMachineIsEmpty

    @Test func previewOnCleanMachineIsEmpty() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Empty tmp — no .claude / .codex / .zackeyes dirs
        let plan = makeUninstaller(tmpDir: tmpDir).preview()

        #expect(plan.isEmpty)
    }

    // MARK: - Test 3: executeRemovesOursPreservesThirdParty

    @Test func executeRemovesOursPreservesThirdParty() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let claudeDir = tmpDir.appendingPathComponent(".claude")
        let codexDir = tmpDir.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)

        let bridgePath = tmpDir.appendingPathComponent(".zackeyes/bin/bridge").path
        let settingsURL = claudeDir.appendingPathComponent("settings.json")
        let hooksURL = codexDir.appendingPathComponent("hooks.json")
        let zackDir = tmpDir.appendingPathComponent(".zackeyes")

        // Pre-seed a third-party hook entry on every claude event
        var claudeHooks: [String: Any] = [:]
        for event in HookInstaller.hookEvents {
            claudeHooks[event] = [
                ["hooks": [["type": "command", "command": "/opt/othertool --on-\(event)"]]]
            ]
        }
        // Pre-seed a third-party statusLine (so install will wrap it in mux)
        let thirdPartyStatusLine = "/usr/local/bin/claude-hud --render"
        var claudeDoc: [String: Any] = [
            "hooks": claudeHooks,
            "statusLine": ["type": "command", "command": thirdPartyStatusLine],
        ]
        try JSONSerialization.data(withJSONObject: claudeDoc, options: .prettyPrinted)
            .write(to: settingsURL)

        // Pre-seed third-party hook entries on every codex event
        var codexHooks: [String: Any] = [:]
        for event in CodexHookInstaller.hookEvents {
            codexHooks[event] = [
                ["hooks": [["type": "command", "command": "/opt/othertool --codex-\(event)"]]]
            ]
        }
        try JSONSerialization.data(withJSONObject: ["hooks": codexHooks], options: .prettyPrinted)
            .write(to: hooksURL)

        // Real install on top: adds our entries to each event, wraps statusLine in mux
        try HookInstaller(settingsPath: settingsURL.path, bridgePath: bridgePath).installHooks()
        try CodexHookInstaller(hooksPath: hooksURL.path, bridgePath: bridgePath).installHooks()

        // Create user-authored artifacts that must survive execute()
        try writeExecutableScript(
            "#!/bin/sh\ncat\n",
            to: zackDir.appendingPathComponent("bin/statusline-user"))
        try "{}".write(
            to: zackDir.appendingPathComponent("config.json"),
            atomically: true, encoding: .utf8)

        // Deploy launcher script so .app-path and bridge launcher exist
        let settingsPath = settingsURL.path
        try HookInstaller(settingsPath: settingsPath, bridgePath: bridgePath)
            .deployLauncherScript(appPath: tmpDir.appendingPathComponent("ZackEyes.app").path)

        // Execute uninstall
        makeUninstaller(tmpDir: tmpDir).execute()

        // --- Verify Claude settings ---
        let claudeData = try Data(contentsOf: settingsURL)
        let claudeResult = try JSONSerialization.jsonObject(with: claudeData) as! [String: Any]
        let hooks = claudeResult["hooks"] as! [String: Any]

        // Every event still has the third-party entry
        for event in HookInstaller.hookEvents {
            let entries = hooks[event] as! [[String: Any]]
            let cmds = entries.flatMap { ($0["hooks"] as? [[String: Any]] ?? []) }
                .compactMap { $0["command"] as? String }
            #expect(cmds.contains("/opt/othertool --on-\(event)"),
                    "third-party entry missing for \(event)")
            // None of ours remain
            #expect(!cmds.contains(where: { $0.contains(bridgePath) || $0.lowercased().contains("zackeyes") }),
                    "our entry not removed for \(event)")
        }

        // statusLine restored to original third-party command (mux unwound)
        let slCmd = (claudeResult["statusLine"] as? [String: Any])?["command"] as? String
        #expect(slCmd == thirdPartyStatusLine)

        // --- Verify Codex hooks ---
        let codexData = try Data(contentsOf: hooksURL)
        let codexResult = try JSONSerialization.jsonObject(with: codexData) as! [String: Any]
        let codexHooksResult = codexResult["hooks"] as! [String: Any]
        for event in CodexHookInstaller.hookEvents {
            let entries = codexHooksResult[event] as! [[String: Any]]
            let cmds = entries.flatMap { ($0["hooks"] as? [[String: Any]] ?? []) }
                .compactMap { $0["command"] as? String }
            #expect(cmds.contains("/opt/othertool --codex-\(event)"),
                    "third-party codex entry missing for \(event)")
            #expect(!cmds.contains(where: { $0.contains(bridgePath) || $0.lowercased().contains("zackeyes") }),
                    "our codex entry not removed for \(event)")
        }

        // --- Verify generated files gone ---
        // bridge launcher removed
        #expect(!FileManager.default.fileExists(atPath: bridgePath))
        // .app-path removed
        #expect(!FileManager.default.fileExists(
            atPath: zackDir.appendingPathComponent(".app-path").path))
        // mux files removed
        #expect(!FileManager.default.fileExists(
            atPath: zackDir.appendingPathComponent("bin/statusline-mux").path))
        #expect(!FileManager.default.fileExists(
            atPath: zackDir.appendingPathComponent(".statusline-original").path))

        // --- User-authored files survive ---
        #expect(FileManager.default.fileExists(
            atPath: zackDir.appendingPathComponent("bin/statusline-user").path))
        #expect(FileManager.default.fileExists(
            atPath: zackDir.appendingPathComponent("config.json").path))
    }

    // MARK: - Test 4: executeIsIdempotent

    @Test func executeIsIdempotent() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try fullInstall(tmpDir: tmpDir)

        let claudeDir = tmpDir.appendingPathComponent(".claude")
        let codexDir = tmpDir.appendingPathComponent(".codex")
        let uninstaller = makeUninstaller(tmpDir: tmpDir)

        // First execute
        uninstaller.execute()

        // Collect backup counts after first run
        let claudeBackups1 = try backupFiles(in: claudeDir, prefix: "settings.json.backup.")
        // Codex dir still exists (only hooks.json was removed, not the dir itself)
        let codexBackups1: [String]
        if FileManager.default.fileExists(atPath: codexDir.path) {
            codexBackups1 = try backupFiles(in: codexDir, prefix: "hooks.json.backup.")
        } else {
            codexBackups1 = []
        }

        // Second execute — must not crash, must not create additional backups
        uninstaller.execute()

        let claudeBackups2 = try backupFiles(in: claudeDir, prefix: "settings.json.backup.")
        let codexBackups2: [String]
        if FileManager.default.fileExists(atPath: codexDir.path) {
            codexBackups2 = try backupFiles(in: codexDir, prefix: "hooks.json.backup.")
        } else {
            codexBackups2 = []
        }

        #expect(claudeBackups2.count == claudeBackups1.count)
        #expect(codexBackups2.count == codexBackups1.count)
    }

    // MARK: - Test 5: executeBacksUpConfigs

    @Test func executeBacksUpConfigs() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try fullInstall(tmpDir: tmpDir)

        let claudeDir = tmpDir.appendingPathComponent(".claude")
        let codexDir = tmpDir.appendingPathComponent(".codex")

        // Clear all install-time backups so the assertion isolates execute().
        for name in try backupFiles(in: claudeDir, prefix: "settings.json.backup.") {
            try FileManager.default.removeItem(at: claudeDir.appendingPathComponent(name))
        }
        for name in try backupFiles(in: codexDir, prefix: "hooks.json.backup.") {
            try FileManager.default.removeItem(at: codexDir.appendingPathComponent(name))
        }

        makeUninstaller(tmpDir: tmpDir).execute()

        let claudeBackups = try backupFiles(in: claudeDir, prefix: "settings.json.backup.")
        #expect(claudeBackups.count == 1)

        // Codex backup lives in codexDir even if hooks.json was deleted
        let codexBackups = try backupFiles(in: codexDir, prefix: "hooks.json.backup.")
        #expect(codexBackups.count == 1)
    }

    // MARK: - Test 6: previewMatchesExecuteScope

    @Test func previewMatchesExecuteScope() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try fullInstall(tmpDir: tmpDir)

        let bridgePath = tmpDir.appendingPathComponent(".zackeyes/bin/bridge").path
        let settingsPath = tmpDir.appendingPathComponent(".claude/settings.json").path
        try HookInstaller(settingsPath: settingsPath, bridgePath: bridgePath)
            .deployLauncherScript(
                appPath: tmpDir.appendingPathComponent("ZackEyes.app").path)

        let uninstaller = makeUninstaller(tmpDir: tmpDir)

        // preview must not be empty before execute
        #expect(!uninstaller.preview().isEmpty)

        uninstaller.execute()

        // After execute, preview must report empty
        #expect(uninstaller.preview().isEmpty)
    }

    // MARK: - Test 7: executeKeepsLauncherWhenConfigCleanupFails (codex review, PR #111)

    @Test func executeKeepsLauncherWhenConfigCleanupFails() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try fullInstall(tmpDir: tmpDir)
        let bridgePath = tmpDir.appendingPathComponent(".zackeyes/bin/bridge").path
        let settingsPath = tmpDir.appendingPathComponent(".claude/settings.json").path
        try HookInstaller(settingsPath: settingsPath, bridgePath: bridgePath)
            .deployLauncherScript(
                appPath: tmpDir.appendingPathComponent("ZackEyes.app").path)

        // Corrupt settings.json: uninstallHooks parse-fail-bails, so our hook
        // entries may still be inside. The file sweep must NOT delete the
        // launcher those (unremovable) entries point at — that would turn
        // every hook invocation into a visible exit-127 terminal error.
        try "{not json".write(
            toFile: settingsPath, atomically: true, encoding: .utf8)

        let result = makeUninstaller(tmpDir: tmpDir).execute()

        #expect(result == false)
        #expect(FileManager.default.fileExists(atPath: bridgePath),
                "launcher must survive while configs may still reference it")
        // Codex side WAS clean — its entries are gone — but the shared
        // launcher stays until the claude side can actually be cleaned.
    }
}
