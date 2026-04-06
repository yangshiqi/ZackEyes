import Testing
import Foundation
@testable import AppLib

struct HookInstallerTests {

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

        // hooks key must exist with all 6 events
        let hooks = json["hooks"] as? [String: Any]
        #expect(hooks != nil)
        for event in ["PermissionRequest", "SessionStart", "PreToolUse",
                      "PostToolUse", "SessionEnd", "Stop"] {
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

    // MARK: - Test 5: uninstall_removesOnlyOurEntries

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
}
