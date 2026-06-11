import Testing
import Foundation
@testable import AppLib

struct HookHealthTests {

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

    /// Hermetic checker: every path points into tmpDir, no default-path
    /// leakage onto the dev machine (where /Applications/ZackEyes.app and
    /// /tmp/zackeyes.sock may genuinely exist).
    private func makeHealth(
        tmpDir: URL,
        currentAppPath: String? = nil,
        socketPath: String? = nil,
        launcherFallbackAppPaths: [String] = []
    ) -> HookHealth {
        HookHealth(
            claudeSettingsPath: tmpDir.appendingPathComponent(".claude/settings.json").path,
            codexHooksPath: tmpDir.appendingPathComponent(".codex/hooks.json").path,
            bridgePath: tmpDir.appendingPathComponent(".zackeyes/bin/bridge").path,
            socketPath: socketPath ?? tmpDir.appendingPathComponent("no.sock").path,
            currentAppPath: currentAppPath ?? tmpDir.appendingPathComponent("ZackEyes.app").path,
            launcherFallbackAppPaths: launcherFallbackAppPaths
        )
    }

    // MARK: - Agent hooks status

    @Test func freshSystemReportsNotInstalled() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let report = makeHealth(tmpDir: tmpDir).check()

        #expect(report.claudeHooks == .notInstalled)
        #expect(report.codexHooks == .notInstalled)
        #expect(!report.isHealthy)  // bridge launcher is missing
    }

    @Test func installerOutputIsDetectedAsInstalled() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let claudeDir = tmpDir.appendingPathComponent(".claude")
        let codexDir = tmpDir.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
        let bridgePath = tmpDir.appendingPathComponent(".zackeyes/bin/bridge").path

        // Build the fixture with the REAL installers so detection can never
        // drift from what install actually writes.
        try HookInstaller(
            settingsPath: claudeDir.appendingPathComponent("settings.json").path,
            bridgePath: bridgePath
        ).installHooks()
        try CodexHookInstaller(
            hooksPath: codexDir.appendingPathComponent("hooks.json").path,
            bridgePath: bridgePath
        ).installHooks()

        let report = makeHealth(tmpDir: tmpDir).check()

        #expect(report.claudeHooks == .installed)
        #expect(report.codexHooks == .installed)
    }

    @Test func dirWithoutConfigFileReportsMissing() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        try FileManager.default.createDirectory(
            at: tmpDir.appendingPathComponent(".claude"), withIntermediateDirectories: true)

        let report = makeHealth(tmpDir: tmpDir).check()

        #expect(report.claudeHooks == .missing)
    }

    @Test func partiallyRemovedEventsReportedAsPartial() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let claudeDir = tmpDir.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let settingsURL = claudeDir.appendingPathComponent("settings.json")
        let bridgePath = tmpDir.appendingPathComponent(".zackeyes/bin/bridge").path
        try HookInstaller(settingsPath: settingsURL.path, bridgePath: bridgePath).installHooks()

        // User manually deleted two events.
        var doc = try JSONSerialization.jsonObject(
            with: Data(contentsOf: settingsURL)) as! [String: Any]
        var hooks = doc["hooks"] as! [String: Any]
        hooks.removeValue(forKey: "Stop")
        hooks.removeValue(forKey: "SessionEnd")
        doc["hooks"] = hooks
        try JSONSerialization.data(withJSONObject: doc).write(to: settingsURL)

        let report = makeHealth(tmpDir: tmpDir).check()

        #expect(report.claudeHooks == .partial(missing: ["SessionEnd", "Stop"]))
    }

    @Test func thirdPartyEntriesAloneAreNotOurs() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let claudeDir = tmpDir.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let settingsURL = claudeDir.appendingPathComponent("settings.json")

        var hooks: [String: Any] = [:]
        for event in HookInstaller.hookEvents {
            hooks[event] = [
                ["hooks": [["type": "command", "command": "/usr/local/bin/other-tool --on \(event)"]]]
            ]
        }
        try JSONSerialization.data(withJSONObject: ["hooks": hooks]).write(to: settingsURL)

        let report = makeHealth(tmpDir: tmpDir).check()

        #expect(report.claudeHooks == .missing)
    }

    @Test func mixedThirdPartyAndOursIsInstalled() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let claudeDir = tmpDir.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let settingsURL = claudeDir.appendingPathComponent("settings.json")
        let bridgePath = tmpDir.appendingPathComponent(".zackeyes/bin/bridge").path

        var hooks: [String: Any] = [:]
        for event in HookInstaller.hookEvents {
            hooks[event] = [
                ["hooks": [["type": "command", "command": "/usr/local/bin/other-tool"]]],
                ["hooks": [["type": "command", "command": "\"\(bridgePath)\" --event \(event) --agent claude"]]],
            ]
        }
        try JSONSerialization.data(withJSONObject: ["hooks": hooks]).write(to: settingsURL)

        let report = makeHealth(tmpDir: tmpDir).check()

        #expect(report.claudeHooks == .installed)
    }

    @Test func unparseableSettingsReportedAsUnreadable() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let claudeDir = tmpDir.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        try "{not json".write(
            to: claudeDir.appendingPathComponent("settings.json"),
            atomically: true, encoding: .utf8)

        let report = makeHealth(tmpDir: tmpDir).check()

        #expect(report.claudeHooks == .unreadable)
        #expect(report.statusLine == .unreadable)
        #expect(!report.isHealthy)
    }

    @Test func codexThirdPartyOnlyReportsMissing() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let codexDir = tmpDir.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
        var hooks: [String: Any] = [:]
        for event in CodexHookInstaller.hookEvents {
            hooks[event] = [
                ["hooks": [["type": "command", "command": "/opt/other/hook"]]]
            ]
        }
        try JSONSerialization.data(withJSONObject: ["hooks": hooks])
            .write(to: codexDir.appendingPathComponent("hooks.json"))

        let report = makeHealth(tmpDir: tmpDir).check()

        #expect(report.codexHooks == .missing)
    }
}
