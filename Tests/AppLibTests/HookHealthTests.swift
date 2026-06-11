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

    // MARK: - Bridge / launcher / socket

    /// Creates a real unix socket at `path` so the file exists with socket
    /// type. IMPORTANT: bind under /tmp directly — sun_path caps at 104
    /// bytes and FileManager.temporaryDirectory paths blow past that.
    private func bindSocket(at path: String) throws -> Int32 {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(fd >= 0, "socket() failed")
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        path.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { dst in
                dst.withMemoryRebound(to: CChar.self, capacity: 104) {
                    _ = strncpy($0, src, 103)
                }
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, len)
            }
        }
        try #require(bindResult == 0, "bind() failed for \(path)")
        return fd
    }

    /// Fake .app bundle with an executable Contents/Helpers/bridge.
    private func makeAppBundle(in tmpDir: URL, name: String) throws -> String {
        let bundle = tmpDir.appendingPathComponent(name)
        try writeExecutableScript(
            "#!/bin/sh\nexit 0\n",
            to: bundle.appendingPathComponent("Contents/Helpers/bridge"))
        return bundle.path
    }

    @Test func bridgeLauncherDetectedWhenExecutable() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        try writeExecutableScript(
            "#!/bin/sh\nexit 0\n",
            to: tmpDir.appendingPathComponent(".zackeyes/bin/bridge"))

        #expect(makeHealth(tmpDir: tmpDir).check().bridgeLauncher)
    }

    @Test func nonExecutableBridgeLauncherIsUnhealthy() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let bridge = tmpDir.appendingPathComponent(".zackeyes/bin/bridge")
        try FileManager.default.createDirectory(
            at: bridge.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: bridge, atomically: true, encoding: .utf8)
        // 0o644 — exists but not executable

        #expect(!makeHealth(tmpDir: tmpDir).check().bridgeLauncher)
    }

    @Test func launcherResolvesWhenMarkerPointsAtCurrentBundle() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let appPath = try makeAppBundle(in: tmpDir, name: "ZackEyes.app")
        try FileManager.default.createDirectory(
            at: tmpDir.appendingPathComponent(".zackeyes"), withIntermediateDirectories: true)
        try appPath.write(
            toFile: tmpDir.appendingPathComponent(".zackeyes/.app-path").path,
            atomically: true, encoding: .utf8)

        let report = makeHealth(tmpDir: tmpDir, currentAppPath: appPath).check()

        #expect(report.launcherResolvesApp)
    }

    @Test func launcherResolvingDifferentBundleIsUnhealthy() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let current = try makeAppBundle(in: tmpDir, name: "Current.app")
        let stale = try makeAppBundle(in: tmpDir, name: "Stale.app")
        try FileManager.default.createDirectory(
            at: tmpDir.appendingPathComponent(".zackeyes"), withIntermediateDirectories: true)
        // Marker points at the stale copy — launcher would exec the wrong build.
        try stale.write(
            toFile: tmpDir.appendingPathComponent(".zackeyes/.app-path").path,
            atomically: true, encoding: .utf8)

        let report = makeHealth(tmpDir: tmpDir, currentAppPath: current).check()

        #expect(!report.launcherResolvesApp)
    }

    @Test func launcherFallbackPathsResolveWithoutMarker() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let appPath = try makeAppBundle(in: tmpDir, name: "Installed.app")

        let report = makeHealth(
            tmpDir: tmpDir,
            currentAppPath: appPath,
            launcherFallbackAppPaths: [appPath]
        ).check()

        #expect(report.launcherResolvesApp)
    }

    @Test func socketDetectedOnlyWhenSocketTypeExists() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let socketPath = "/tmp/zackeyes-test-\(UUID().uuidString.prefix(8)).sock"
        let fd = try bindSocket(at: socketPath)
        defer {
            close(fd)
            unlink(socketPath)
        }

        #expect(makeHealth(tmpDir: tmpDir, socketPath: socketPath).check().socketReachable)

        // A regular file at the socket path must NOT count as reachable.
        let plainFile = tmpDir.appendingPathComponent("plain.sock")
        try "x".write(to: plainFile, atomically: true, encoding: .utf8)
        #expect(!makeHealth(tmpDir: tmpDir, socketPath: plainFile.path).check().socketReachable)
    }
}
