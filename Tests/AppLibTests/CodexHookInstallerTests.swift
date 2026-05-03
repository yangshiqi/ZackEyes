import Testing
import Foundation
@testable import AppLib

/// Mirror of HookInstallerTests for the Codex variant. Covers the same
/// "user config zero damage" invariants:
///
/// - Skip silently when the parent dir is missing
/// - Append our entries; preserve other tools' existing entries
/// - Back up the file before any modification
/// - Bail without modification on JSON parse failure
/// - Uninstall removes only our entries
/// - Empty doc gets cleaned up entirely (no dangling `{}`)
struct CodexHookInstallerTests {

    private func makeTmpDir() throws -> URL {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        return tmpDir
    }

    // MARK: - Test 1: install creates 6 events when starting fresh

    @Test func installCreatesAllSixEventsOnFreshFile() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let codexDir = tmpDir.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)

        let hooksURL = codexDir.appendingPathComponent("hooks.json")
        let installer = CodexHookInstaller(
            hooksPath: hooksURL.path,
            bridgePath: "/test/bridge"
        )
        try installer.installHooks()

        let data = try Data(contentsOf: hooksURL)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let hooks = json["hooks"] as? [String: Any]
        #expect(hooks != nil)
        for event in [
            "PreToolUse", "PostToolUse", "PermissionRequest",
            "SessionStart", "Stop", "UserPromptSubmit",
        ] {
            let entries = hooks?[event] as? [[String: Any]]
            #expect(entries != nil, "Missing event: \(event)")
            #expect((entries?.count ?? 0) == 1)
            // Command must include `--agent codex` so Bridge tags events correctly.
            let firstHooks = entries?.first?["hooks"] as? [[String: Any]]
            let cmd = firstHooks?.first?["command"] as? String ?? ""
            #expect(cmd.contains("--agent codex"))
            #expect(cmd.contains("--event \(event)"))
        }
    }

    // MARK: - Test 2: skip when ~/.codex doesn't exist

    @Test func skipWhenCodexDirAbsent() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        // Don't create the .codex directory.
        let hooksURL = tmpDir.appendingPathComponent(".codex/hooks.json")

        let installer = CodexHookInstaller(
            hooksPath: hooksURL.path,
            bridgePath: "/test/bridge"
        )
        try installer.installHooks()  // must not throw

        #expect(!FileManager.default.fileExists(atPath: hooksURL.path))
    }

    // MARK: - Test 3: preserve existing user hooks

    @Test func preservesExistingUserHooks() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let codexDir = tmpDir.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)

        let hooksURL = codexDir.appendingPathComponent("hooks.json")
        let initial = """
            {"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"other-tool --check"}]}]}}
            """
        try initial.write(to: hooksURL, atomically: true, encoding: .utf8)

        let installer = CodexHookInstaller(
            hooksPath: hooksURL.path,
            bridgePath: "/test/bridge"
        )
        try installer.installHooks()

        let data = try Data(contentsOf: hooksURL)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let hooks = json["hooks"] as? [String: Any]
        let preToolUseEntries = hooks?["PreToolUse"] as? [[String: Any]]
        #expect((preToolUseEntries?.count ?? 0) == 2)

        // First entry must be the original other-tool, untouched.
        let firstEntry = preToolUseEntries?[0]
        let firstHooks = firstEntry?["hooks"] as? [[String: Any]]
        let firstCommand = firstHooks?.first?["command"] as? String
        #expect(firstCommand == "other-tool --check")
    }

    // MARK: - Test 4: backup written before mutation

    @Test func writesBackupBeforeModifying() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let codexDir = tmpDir.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)

        let hooksURL = codexDir.appendingPathComponent("hooks.json")
        try "{}".write(to: hooksURL, atomically: true, encoding: .utf8)

        let installer = CodexHookInstaller(
            hooksPath: hooksURL.path,
            bridgePath: "/test/bridge"
        )
        try installer.installHooks()

        let contents = try FileManager.default.contentsOfDirectory(atPath: codexDir.path)
        let backups = contents.filter { $0.hasPrefix("hooks.json.backup.") }
        #expect(backups.count >= 1)
    }

    // MARK: - Test 5: parse failure leaves file untouched

    @Test func skipsOnParseFailure() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let codexDir = tmpDir.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)

        let hooksURL = codexDir.appendingPathComponent("hooks.json")
        let badContent = "not valid json {{{"
        try badContent.write(to: hooksURL, atomically: true, encoding: .utf8)

        let installer = CodexHookInstaller(
            hooksPath: hooksURL.path,
            bridgePath: "/test/bridge"
        )
        try installer.installHooks()  // must not throw

        let result = try String(contentsOf: hooksURL, encoding: .utf8)
        #expect(result == badContent)
    }

    // MARK: - Test 6: uninstall removes only our entries

    @Test func uninstallRemovesOnlyOurEntries() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let codexDir = tmpDir.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)

        let hooksURL = codexDir.appendingPathComponent("hooks.json")
        // User has their own hook + we install ours; uninstall should leave
        // theirs intact.
        let initial = """
            {"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"other-tool --check"}]}]}}
            """
        try initial.write(to: hooksURL, atomically: true, encoding: .utf8)

        let installer = CodexHookInstaller(
            hooksPath: hooksURL.path,
            bridgePath: "/test/bridge"
        )
        try installer.installHooks()
        try installer.uninstallHooks()

        let data = try Data(contentsOf: hooksURL)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let hooks = json["hooks"] as? [String: Any]
        let preToolUseEntries = hooks?["PreToolUse"] as? [[String: Any]]
        #expect((preToolUseEntries?.count ?? 0) == 1)
        let firstHooks = preToolUseEntries?.first?["hooks"] as? [[String: Any]]
        let firstCommand = firstHooks?.first?["command"] as? String
        #expect(firstCommand == "other-tool --check")
    }

    // MARK: - Test 7: empty doc gets removed entirely after uninstall

    @Test func uninstallDeletesFileWhenWeOwnedAllOfIt() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let codexDir = tmpDir.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)

        let hooksURL = codexDir.appendingPathComponent("hooks.json")
        // Start with no file; install creates one fully owned by us.
        let installer = CodexHookInstaller(
            hooksPath: hooksURL.path,
            bridgePath: "/test/bridge"
        )
        try installer.installHooks()
        #expect(FileManager.default.fileExists(atPath: hooksURL.path))

        try installer.uninstallHooks()
        // After full uninstall, the doc was empty — file should be gone.
        #expect(!FileManager.default.fileExists(atPath: hooksURL.path))
    }

    // MARK: - Test 8: re-install is idempotent (no duplicate entries)

    @Test func reinstallDoesNotDuplicateOurEntries() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let codexDir = tmpDir.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)

        let hooksURL = codexDir.appendingPathComponent("hooks.json")
        let installer = CodexHookInstaller(
            hooksPath: hooksURL.path,
            bridgePath: "/test/bridge"
        )
        try installer.installHooks()
        try installer.installHooks()
        try installer.installHooks()

        let data = try Data(contentsOf: hooksURL)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let hooks = json["hooks"] as? [String: Any]
        let preToolUseEntries = hooks?["PreToolUse"] as? [[String: Any]]
        #expect((preToolUseEntries?.count ?? 0) == 1)
    }
}
