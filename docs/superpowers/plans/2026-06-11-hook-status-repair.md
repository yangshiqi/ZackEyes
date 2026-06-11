# Hook Status + Repair (#38) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a read-only hook-health checker (6 status fields) plus a standalone "Hook Status" window with a Repair button, reachable from both the status-bar context menu and the simulated-notch gear menu (GitHub issue #38).

**Architecture:** A new pure read-only `HookHealth` checker reuses `HookInstaller`/`CodexHookInstaller` internals (event list, entry detection, statusLine classification) so health reporting can never drift from installer behavior. Repair = re-running the existing installers via a shared `HookRepair` helper (also used by AppDelegate startup). Both installers gain a no-op guard: when a re-install changes nothing, skip backup + write (kills backup-file spam on every app launch and every Repair click). UI is a `KeyablePanel` + SwiftUI card cloned from the `AboutWindow` pattern.

**Tech Stack:** Swift 6 strict concurrency, Foundation + AppKit + SwiftUI only (invariant #6: zero third-party deps), Swift Testing (`import Testing` / `@Test` / `#expect`).

**Branch:** `feat/38-hook-status` off `master` (≥ `19bf47a`). Use superpowers:using-git-worktrees at execution start — parallel sessions share this checkout (see memory `concurrent-sessions-shared-checkout`).

**Iron rules in blast radius (CLAUDE.md invariants #1/#5, AGENTS.md checklist):**
- Health check is STRICTLY read-only — it must never create, modify, or delete any file.
- Repair only re-runs existing installers: backup-before-write, only `hooks`/`statusLine` keys, JSON-parse-failure → no modification, never read/write `~/.codex/config.toml`, entries identified by `zackeyes` substring + `--agent` flag.
- The no-op guard only ever *skips* a write — it can never make the installer write more.

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `Sources/AppLib/Hooks/HookHealth.swift` | Create | `HookHealthReport` (6 fields + `isHealthy`) and `HookHealth.check()` — pure read-only probing |
| `Sources/AppLib/Hooks/HookRepair.swift` | Create | Shared best-effort repair = deployLauncherScript + installHooks ×2 (extracted from AppDelegate step 5) |
| `Sources/AppLib/Hooks/HookInstaller.swift` | Modify | `hookEvents`/`isZackEyesEntry` private→internal; add `statusLineMode(of:)`; no-op guard in `installHooks()` |
| `Sources/AppLib/Hooks/CodexHookInstaller.swift` | Modify | `hookEvents`/`isZackEyesEntry` private→internal; no-op guard in `installHooks()` |
| `Sources/AppLib/MenuBar/HookStatusWindow.swift` | Create | KeyablePanel + SwiftUI card: 6 status rows + Repair/Close buttons (AboutWindow pattern) |
| `Sources/AppLib/MenuBar/StatusBarMenu.swift` | Modify | "Hook Status…" item + lazy window (after "Change Hotkey…", ~line 64) |
| `Sources/AppLib/SimulatedNotch/GearMenuTarget.swift` | Modify | `hookStatusClicked` handler + lazy window |
| `Sources/AppLib/SimulatedNotch/SimulatedNotchFullView.swift` | Modify | Gear-menu item (after hotkey item, ~line 375) |
| `Sources/ZackEyes/AppDelegate.swift` | Modify | Step-5 install block → `HookRepair.run(appPath:)` (~lines 215–233) |
| `Tests/AppLibTests/HookHealthTests.swift` | Create | Fixture-driven health checks + statusLine classification |
| `Tests/AppLibTests/HookInstallerTests.swift` | Modify | Append idempotency tests |
| `Tests/AppLibTests/CodexHookInstallerTests.swift` | Modify | Append idempotency tests |
| `ARCHITECTURE.md` | Modify | Module-table rows for HookHealth / HookRepair / HookStatusWindow; HookInstaller idempotency note |

---

### Task 1: HookHealthReport types + agent hooks status checks

**Files:**
- Create: `Sources/AppLib/Hooks/HookHealth.swift`
- Modify: `Sources/AppLib/Hooks/HookInstaller.swift` (2 visibility changes)
- Modify: `Sources/AppLib/Hooks/CodexHookInstaller.swift` (2 visibility changes)
- Test: `Tests/AppLibTests/HookHealthTests.swift`

- [ ] **Step 1.1: Make installer internals reachable from HookHealth (same module)**

In `Sources/AppLib/Hooks/HookInstaller.swift`:
- Line 18: `private static let hookEvents = [` → `static let hookEvents = [`
- Line 401: `private func isZackEyesEntry(` → `func isZackEyesEntry(`

In `Sources/AppLib/Hooks/CodexHookInstaller.swift`:
- Line 36: `private static let hookEvents = [` → `static let hookEvents = [`
- Line 152: `private func isZackEyesEntry(` → `func isZackEyesEntry(`

(Tests use `@testable import`, so this is for cross-file access *within* AppLib, not for tests.)

- [ ] **Step 1.2: Write the failing tests**

Create `Tests/AppLibTests/HookHealthTests.swift`:

```swift
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
```

- [ ] **Step 1.3: Run tests to verify they fail**

Run: `swift test --filter HookHealthTests 2>&1 | tail -20`
Expected: compile FAILURE — `cannot find 'HookHealth' in scope`

- [ ] **Step 1.4: Implement HookHealth (types + agent status + stubs for the rest)**

Create `Sources/AppLib/Hooks/HookHealth.swift`:

```swift
import Foundation

/// Read-only snapshot of the ZackEyes hook installation, one field per
/// status row in the Hook Status window (issue #38).
public struct HookHealthReport: Equatable, Sendable {

    public enum AgentHooksStatus: Equatable, Sendable {
        /// Every hook event has a ZackEyes entry.
        case installed
        /// Some events have our entry, some don't (e.g. partial manual
        /// edit). Associated value lists missing event names, sorted.
        case partial(missing: [String])
        /// Config file exists (or dir exists) but none of our entries do.
        case missing
        /// The agent itself isn't installed (`~/.claude` / `~/.codex` absent).
        case notInstalled
        /// Config file exists but isn't parseable JSON.
        case unreadable
    }

    public enum StatusLineMode: Equatable, Sendable {
        /// Our bridge is the statusLine command.
        case direct
        /// Our mux wraps a preserved third-party command.
        case mux
        /// Our mux feeds the user's `statusline-user` display script.
        case userRenderer
        /// Another tool owns statusLine — our rate-limit feed is dark.
        case thirdParty(command: String)
        /// No statusLine key in settings.json.
        case absent
        /// settings.json unreadable.
        case unreadable
    }

    public let claudeHooks: AgentHooksStatus
    public let codexHooks: AgentHooksStatus
    /// `~/.zackeyes/bin/bridge` launcher script exists and is executable.
    public let bridgeLauncher: Bool
    /// The launcher's lookup order resolves to the currently running bundle.
    public let launcherResolvesApp: Bool
    /// Socket file exists and is of socket type.
    public let socketReachable: Bool
    public let statusLine: StatusLineMode

    public var isHealthy: Bool {
        let claudeOK = claudeHooks == .installed || claudeHooks == .notInstalled
        let codexOK = codexHooks == .installed || codexHooks == .notInstalled
        let statusLineOK: Bool
        switch statusLine {
        case .direct, .mux, .userRenderer: statusLineOK = true
        case .absent: statusLineOK = claudeHooks == .notInstalled
        case .thirdParty, .unreadable: statusLineOK = false
        }
        return claudeOK && codexOK && bridgeLauncher
            && launcherResolvesApp && socketReachable && statusLineOK
    }
}

/// Strictly read-only health checker. MUST NOT create, modify, or delete
/// any file (CLAUDE.md invariant #1 — repair is the installers' job).
public struct HookHealth {

    private let claudeSettingsPath: String
    private let codexHooksPath: String
    private let bridgePath: String
    private let socketPath: String
    private let currentAppPath: String
    private let launcherFallbackAppPaths: [String]

    public init(
        claudeSettingsPath: String = NSHomeDirectory() + "/.claude/settings.json",
        codexHooksPath: String = NSHomeDirectory() + "/.codex/hooks.json",
        bridgePath: String = "$HOME/.zackeyes/bin/bridge",
        socketPath: String = "/tmp/zackeyes.sock",
        currentAppPath: String = Bundle.main.bundlePath,
        launcherFallbackAppPaths: [String] = [
            "/Applications/ZackEyes.app",
            NSHomeDirectory() + "/Applications/ZackEyes.app",
        ]
    ) {
        self.claudeSettingsPath = claudeSettingsPath
        self.codexHooksPath = codexHooksPath
        self.bridgePath = bridgePath
        self.socketPath = socketPath
        self.currentAppPath = currentAppPath
        self.launcherFallbackAppPaths = launcherFallbackAppPaths
    }

    public func check() -> HookHealthReport {
        let claudeFile = load(claudeSettingsPath)
        let claudeInstaller = HookInstaller(
            settingsPath: claudeSettingsPath, bridgePath: bridgePath)
        let codexInstaller = CodexHookInstaller(
            hooksPath: codexHooksPath, bridgePath: bridgePath)

        return HookHealthReport(
            claudeHooks: agentStatus(
                claudeFile,
                events: HookInstaller.hookEvents,
                isOurs: claudeInstaller.isZackEyesEntry),
            codexHooks: agentStatus(
                load(codexHooksPath),
                events: CodexHookInstaller.hookEvents,
                isOurs: codexInstaller.isZackEyesEntry),
            bridgeLauncher: FileManager.default.isExecutableFile(atPath: expandedBridgePath),
            launcherResolvesApp: checkLauncherResolution(),
            socketReachable: checkSocket(),
            statusLine: statusLineMode(claudeFile: claudeFile)
        )
    }

    // MARK: - Config loading

    private enum ConfigFile {
        case dirMissing
        case fileMissing
        case unreadable
        case parsed([String: Any])
    }

    private func load(_ path: String) -> ConfigFile {
        let dir = (path as NSString).deletingLastPathComponent
        guard FileManager.default.fileExists(atPath: dir) else { return .dirMissing }
        guard FileManager.default.fileExists(atPath: path) else { return .fileMissing }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .unreadable }
        return .parsed(parsed)
    }

    private func agentStatus(
        _ file: ConfigFile,
        events: [String],
        isOurs: ([String: Any]) -> Bool
    ) -> HookHealthReport.AgentHooksStatus {
        switch file {
        case .dirMissing: return .notInstalled
        case .fileMissing: return .missing
        case .unreadable: return .unreadable
        case .parsed(let doc):
            let hooks = doc["hooks"] as? [String: Any] ?? [:]
            let missing = events.filter { event in
                let entries = hooks[event] as? [[String: Any]] ?? []
                return !entries.contains(where: isOurs)
            }
            if missing.isEmpty { return .installed }
            if missing.count == events.count { return .missing }
            return .partial(missing: missing.sorted())
        }
    }

    // MARK: - Bridge / launcher / socket  (implemented in Task 2)

    private var expandedBridgePath: String {
        bridgePath.replacingOccurrences(of: "$HOME", with: NSHomeDirectory())
    }

    private var binDir: String {
        (expandedBridgePath as NSString).deletingLastPathComponent
    }

    private var zackDir: String {
        (binDir as NSString).deletingLastPathComponent
    }

    private func checkLauncherResolution() -> Bool {
        false  // Task 2
    }

    private func checkSocket() -> Bool {
        false  // Task 2
    }

    // MARK: - statusLine  (implemented in Task 3)

    private func statusLineMode(claudeFile: ConfigFile) -> HookHealthReport.StatusLineMode {
        switch claudeFile {
        case .unreadable: return .unreadable
        default: return .absent  // Task 3
        }
    }
}
```

- [ ] **Step 1.5: Run tests to verify they pass**

Run: `swift test --filter HookHealthTests 2>&1 | tail -20`
Expected: all 8 HookHealthTests PASS. (`unparseableSettingsReportedAsUnreadable` already passes because the `.unreadable` branch of `statusLineMode` is real.)

Also run the full suite to confirm the visibility changes broke nothing:
Run: `swift test 2>&1 | tail -5`
Expected: PASS

- [ ] **Step 1.6: Commit**

```bash
git add Sources/AppLib/Hooks/HookHealth.swift Sources/AppLib/Hooks/HookInstaller.swift Sources/AppLib/Hooks/CodexHookInstaller.swift Tests/AppLibTests/HookHealthTests.swift
git commit -m "feat(hooks): add read-only HookHealth checker for claude/codex hook entries"
```

---

### Task 2: Bridge launcher, launcher resolution, socket checks

**Files:**
- Modify: `Sources/AppLib/Hooks/HookHealth.swift` (fill the two Task-2 stubs)
- Test: `Tests/AppLibTests/HookHealthTests.swift`

- [ ] **Step 2.1: Write the failing tests**

Append inside `struct HookHealthTests`:

```swift
    // MARK: - Bridge / launcher / socket

    /// Creates a real unix socket at `path` so the file exists with socket
    /// type. IMPORTANT: bind under /tmp directly — sun_path caps at 104
    /// bytes and FileManager.temporaryDirectory paths blow past that.
    private func bindSocket(at path: String) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
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
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, len)
            }
        }
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
        let fd = bindSocket(at: socketPath)
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
```

- [ ] **Step 2.2: Run tests to verify they fail**

Run: `swift test --filter HookHealthTests 2>&1 | tail -20`
Expected: the 6 new tests FAIL (stubs return `false`); `nonExecutableBridgeLauncherIsUnhealthy` passes trivially — fine.

- [ ] **Step 2.3: Implement the two checks**

In `Sources/AppLib/Hooks/HookHealth.swift`, replace the two Task-2 stubs:

```swift
    /// Mirrors the launcher script's lookup order: `.app-path` marker first,
    /// then the fixed install locations. The script additionally tries the
    /// deploy-time path baked into it (== marker content in practice, both
    /// written by deployLauncherScript) and an mdfind lookup (too slow for a
    /// health probe) — both intentionally omitted from this approximation.
    private func checkLauncherResolution() -> Bool {
        var candidates: [String] = []
        let markerPath = zackDir + "/.app-path"
        if let content = try? String(contentsOfFile: markerPath, encoding: .utf8),
           let firstLine = content.split(separator: "\n", maxSplits: 1).first {
            candidates.append(String(firstLine))
        }
        candidates.append(contentsOf: launcherFallbackAppPaths)
        let resolved = candidates.first {
            FileManager.default.isExecutableFile(atPath: $0 + "/Contents/Helpers/bridge")
        }
        return resolved == currentAppPath
    }

    private func checkSocket() -> Bool {
        let attrs = try? FileManager.default.attributesOfItem(atPath: socketPath)
        return (attrs?[.type] as? FileAttributeType) == .typeSocket
    }
```

- [ ] **Step 2.4: Run tests to verify they pass**

Run: `swift test --filter HookHealthTests 2>&1 | tail -20`
Expected: PASS (14 tests)

- [ ] **Step 2.5: Commit**

```bash
git add Sources/AppLib/Hooks/HookHealth.swift Tests/AppLibTests/HookHealthTests.swift
git commit -m "feat(hooks): health checks for bridge launcher, app resolution, socket"
```

---

### Task 3: statusLine ownership classification

**Files:**
- Modify: `Sources/AppLib/Hooks/HookInstaller.swift` (new internal method)
- Modify: `Sources/AppLib/Hooks/HookHealth.swift` (wire it in)
- Test: `Tests/AppLibTests/HookHealthTests.swift`

- [ ] **Step 3.1: Write the failing tests**

Append inside `struct HookHealthTests`:

```swift
    // MARK: - statusLine classification

    /// settings.json with our hooks installed, then statusLine.command
    /// overridden to `command` (nil = remove the key).
    private func writeSettingsWithStatusLine(
        tmpDir: URL, command: String?
    ) throws {
        let claudeDir = tmpDir.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let settingsURL = claudeDir.appendingPathComponent("settings.json")
        let bridgePath = tmpDir.appendingPathComponent(".zackeyes/bin/bridge").path
        try HookInstaller(settingsPath: settingsURL.path, bridgePath: bridgePath).installHooks()

        var doc = try JSONSerialization.jsonObject(
            with: Data(contentsOf: settingsURL)) as! [String: Any]
        if let command {
            doc["statusLine"] = ["type": "command", "command": command]
        } else {
            doc.removeValue(forKey: "statusLine")
        }
        try JSONSerialization.data(withJSONObject: doc).write(to: settingsURL)
    }

    @Test func statusLineDirectAfterInstall() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let claudeDir = tmpDir.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        try HookInstaller(
            settingsPath: claudeDir.appendingPathComponent("settings.json").path,
            bridgePath: tmpDir.appendingPathComponent(".zackeyes/bin/bridge").path
        ).installHooks()

        #expect(makeHealth(tmpDir: tmpDir).check().statusLine == .direct)
    }

    @Test func statusLineThirdPartyDetected() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        try writeSettingsWithStatusLine(tmpDir: tmpDir, command: "/usr/local/bin/claude-hud")

        let report = makeHealth(tmpDir: tmpDir).check()

        #expect(report.statusLine == .thirdParty(command: "/usr/local/bin/claude-hud"))
        #expect(!report.isHealthy)
    }

    @Test func statusLineMissingReportedAsAbsent() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        try writeSettingsWithStatusLine(tmpDir: tmpDir, command: nil)

        #expect(makeHealth(tmpDir: tmpDir).check().statusLine == .absent)
    }

    @Test func statusLineMuxWithOriginalClassifiedAsMux() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let muxPath = tmpDir.appendingPathComponent(".zackeyes/bin/statusline-mux").path
        try writeSettingsWithStatusLine(tmpDir: tmpDir, command: muxPath)
        // Saved original marks "wrapping a third-party command".
        try "/usr/local/bin/claude-hud".write(
            toFile: tmpDir.appendingPathComponent(".zackeyes/.statusline-original").path,
            atomically: true, encoding: .utf8)

        #expect(makeHealth(tmpDir: tmpDir).check().statusLine == .mux)
    }

    @Test func statusLineMuxWithUserScriptClassifiedAsUserRenderer() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let muxPath = tmpDir.appendingPathComponent(".zackeyes/bin/statusline-mux").path
        try writeSettingsWithStatusLine(tmpDir: tmpDir, command: muxPath)
        // No .statusline-original, but an executable statusline-user.
        try writeExecutableScript(
            "#!/bin/sh\ncat\n",
            to: tmpDir.appendingPathComponent(".zackeyes/bin/statusline-user"))

        #expect(makeHealth(tmpDir: tmpDir).check().statusLine == .userRenderer)
    }
```

- [ ] **Step 3.2: Run tests to verify they fail**

Run: `swift test --filter HookHealthTests 2>&1 | tail -20`
Expected: the 4 non-`absent` tests FAIL (stub returns `.absent`); `statusLineMissingReportedAsAbsent` passes trivially.

- [ ] **Step 3.3: Implement classification**

In `Sources/AppLib/Hooks/HookInstaller.swift`, add after `// MARK: - Helpers` (before `isStatusLineMuxCommand`):

```swift
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
```

In `Sources/AppLib/Hooks/HookHealth.swift`, replace the `statusLineMode(claudeFile:)` stub:

```swift
    private func statusLineMode(claudeFile: ConfigFile) -> HookHealthReport.StatusLineMode {
        switch claudeFile {
        case .unreadable:
            return .unreadable
        case .dirMissing, .fileMissing:
            return .none
        case .parsed(let doc):
            let command = (doc["statusLine"] as? [String: Any])?["command"] as? String
            return HookInstaller(settingsPath: claudeSettingsPath, bridgePath: bridgePath)
                .statusLineMode(of: command)
        }
    }
```

- [ ] **Step 3.4: Run tests to verify they pass**

Run: `swift test --filter HookHealthTests 2>&1 | tail -20`
Expected: PASS (19 tests)

- [ ] **Step 3.5: Commit**

```bash
git add Sources/AppLib/Hooks/HookInstaller.swift Sources/AppLib/Hooks/HookHealth.swift Tests/AppLibTests/HookHealthTests.swift
git commit -m "feat(hooks): classify statusLine ownership (direct/mux/user/third-party)"
```

---

### Task 4: Idempotent installs — skip backup + write on no-op

Repair re-runs `installHooks()`; today every run rewrites the file and drops
a new `settings.json.backup.<ts>`. Add a no-op guard to both installers so
unchanged config ⇒ no backup, no write (also kills the backup spam on every
app launch). The guard only ever *skips* a write — never adds one.

**Files:**
- Modify: `Sources/AppLib/Hooks/HookInstaller.swift:52-155` (installHooks)
- Modify: `Sources/AppLib/Hooks/CodexHookInstaller.swift:64-106` (installHooks)
- Test: `Tests/AppLibTests/HookInstallerTests.swift`, `Tests/AppLibTests/CodexHookInstallerTests.swift`

- [ ] **Step 4.1: Write the failing tests**

Append inside `struct HookInstallerTests` (use the existing `makeTmpDir` helper):

```swift
    // MARK: - Idempotent re-install (#38 repair)

    private func backupFiles(in dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("settings.json.backup.") }
    }

    @Test func reinstallWithoutChangesSkipsBackupAndWrite() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let claudeDir = tmpDir.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let settingsURL = claudeDir.appendingPathComponent("settings.json")
        try #"{"permissions":{"allow":["Bash"]}}"#
            .write(to: settingsURL, atomically: true, encoding: .utf8)

        let installer = HookInstaller(
            settingsPath: settingsURL.path,
            bridgePath: tmpDir.appendingPathComponent(".zackeyes/bin/bridge").path
        )
        try installer.installHooks()

        // Drop the backup from the first (real) write, then re-run.
        for name in try backupFiles(in: claudeDir) {
            try FileManager.default.removeItem(at: claudeDir.appendingPathComponent(name))
        }
        let contentAfterFirst = try Data(contentsOf: settingsURL)

        try installer.installHooks()

        #expect(try backupFiles(in: claudeDir).isEmpty)
        #expect(try Data(contentsOf: settingsURL) == contentAfterFirst)
    }

    @Test func reinstallAfterManualDamageBacksUpAndRepairs() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let claudeDir = tmpDir.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let settingsURL = claudeDir.appendingPathComponent("settings.json")
        let bridgePath = tmpDir.appendingPathComponent(".zackeyes/bin/bridge").path
        let installer = HookInstaller(settingsPath: settingsURL.path, bridgePath: bridgePath)
        try installer.installHooks()
        for name in try backupFiles(in: claudeDir) {
            try FileManager.default.removeItem(at: claudeDir.appendingPathComponent(name))
        }

        // User nukes the hooks key entirely (keeps a third-party statusLine).
        var doc = try JSONSerialization.jsonObject(
            with: Data(contentsOf: settingsURL)) as! [String: Any]
        doc.removeValue(forKey: "hooks")
        try JSONSerialization.data(withJSONObject: doc).write(to: settingsURL)

        try installer.installHooks()

        #expect(try backupFiles(in: claudeDir).count == 1)
        let repaired = try JSONSerialization.jsonObject(
            with: Data(contentsOf: settingsURL)) as! [String: Any]
        let hooks = repaired["hooks"] as! [String: Any]
        #expect(hooks.count == 12)
    }
```

Append inside `struct CodexHookInstallerTests`:

```swift
    // MARK: - Idempotent re-install (#38 repair)

    @Test func reinstallWithoutChangesSkipsBackupAndWrite() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let codexDir = tmpDir.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
        let hooksURL = codexDir.appendingPathComponent("hooks.json")

        let installer = CodexHookInstaller(
            hooksPath: hooksURL.path,
            bridgePath: tmpDir.appendingPathComponent(".zackeyes/bin/bridge").path
        )
        try installer.installHooks()

        let backups = {
            try FileManager.default.contentsOfDirectory(atPath: codexDir.path)
                .filter { $0.hasPrefix("hooks.json.backup.") }
        }
        for name in try backups() {
            try FileManager.default.removeItem(at: codexDir.appendingPathComponent(name))
        }
        let contentAfterFirst = try Data(contentsOf: hooksURL)

        try installer.installHooks()

        #expect(try backups().isEmpty)
        #expect(try Data(contentsOf: hooksURL) == contentAfterFirst)
    }
```

- [ ] **Step 4.2: Run tests to verify they fail**

Run: `swift test --filter "reinstall" 2>&1 | tail -20`
Expected: `reinstallWithoutChangesSkipsBackupAndWrite` ×2 FAIL (a fresh backup appears); `reinstallAfterManualDamageBacksUpAndRepairs` PASSES already (rewrite path) — kept as the regression guard that the no-op guard doesn't suppress real repairs.

- [ ] **Step 4.3: Implement the no-op guard — HookInstaller**

In `installHooks()` (`HookInstaller.swift:52`):

a) Replace the parse-and-backup block (lines 59-77) with parse-and-remember (backup moves to write time):

```swift
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
```

b) The hooks-merge and statusLine blocks stay byte-for-byte unchanged.

c) Replace the final `try writeSettings(settings, to: settingsURL)` (line 154) with:

```swift
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
```

(`originalSettings` keeps the pre-merge value: `settings` is a Swift value-type
copy, so mutations don't alias back. Mux script re-deployment inside the
statusLine block still runs on every call — it rewrites identical content for
our own files under `~/.zackeyes/`, which is harmless and keeps that block
untouched.)

- [ ] **Step 4.4: Implement the no-op guard — CodexHookInstaller**

Same restructure in `CodexHookInstaller.installHooks()` (lines 71-105):

```swift
        let hooksURL = URL(fileURLWithPath: hooksPath)
        var doc: [String: Any] = [:]
        var originalDoc: [String: Any]?
        var originalData: Data?

        if FileManager.default.fileExists(atPath: hooksPath) {
            guard let data = try? Data(contentsOf: hooksURL),
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                // JSON parse failure — don't touch the file
                return
            }
            doc = parsed
            originalDoc = parsed
            originalData = data
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

        // No-op guard — see HookInstaller.installHooks.
        if let originalDoc,
           NSDictionary(dictionary: doc).isEqual(to: originalDoc) {
            return
        }

        if let originalData {
            let timestamp = Int(Date().timeIntervalSince1970)
            let backupURL = hooksURL
                .deletingLastPathComponent()
                .appendingPathComponent("hooks.json.backup.\(timestamp)")
            try originalData.write(to: backupURL)
        }

        try writeHooks(doc, to: hooksURL)
```

- [ ] **Step 4.5: Run the full suite**

Run: `swift test 2>&1 | tail -5`
Expected: ALL tests PASS — existing backup tests in both installer test files
still pass because first-time installs DO change the file and therefore still
back up. If an existing test asserted "backup exists after a no-change
re-install", that test encoded the spam bug — update it to assert the new
contract and note it in the commit message.

- [ ] **Step 4.6: Commit**

```bash
git add Sources/AppLib/Hooks/HookInstaller.swift Sources/AppLib/Hooks/CodexHookInstaller.swift Tests/AppLibTests/HookInstallerTests.swift Tests/AppLibTests/CodexHookInstallerTests.swift
git commit -m "feat(hooks): skip backup and write when re-install is a no-op"
```

---

### Task 5: HookRepair helper + HookStatusWindow UI

**Files:**
- Create: `Sources/AppLib/Hooks/HookRepair.swift`
- Create: `Sources/AppLib/MenuBar/HookStatusWindow.swift`

No new unit tests (UI window — same policy as AboutWindow/HotkeyRecorderWindow);
build + manual verification. HookRepair is covered transitively by installer tests.

- [ ] **Step 5.1: Create HookRepair**

Create `Sources/AppLib/Hooks/HookRepair.swift`:

```swift
import Foundation

/// Best-effort hook (re)installation, shared by AppDelegate startup and the
/// Hook Status window's Repair button. Each installer fails independently —
/// a Claude-side error must not block the Codex install (and vice versa).
/// All safety invariants live in the installers themselves: backup before
/// write, only hooks/statusLine keys, parse-failure bail, no-op skip, and
/// never touching ~/.codex/config.toml.
public enum HookRepair {
    public static func run(appPath: String) {
        do {
            let installer = HookInstaller()
            try installer.deployLauncherScript(appPath: appPath)
            try installer.installHooks()
        } catch {
            NSLog("ZackEyes: Hook installation failed: \(error)")
        }
        do {
            try CodexHookInstaller().installHooks()
        } catch {
            NSLog("ZackEyes: Codex hook installation failed: \(error)")
        }
    }
}
```

- [ ] **Step 5.2: Create HookStatusWindow**

Create `Sources/AppLib/MenuBar/HookStatusWindow.swift`:

```swift
import AppKit
import SwiftUI

/// Standalone Hook Status card: six health rows + Repair/Close buttons.
/// Shared by the status-bar context menu and the simulated-notch gear menu.
/// Same non-blocking KeyablePanel pattern as `AboutWindow` — a modal alert
/// would starve the @MainActor socket handler.
@MainActor
final class HookStatusWindow: NSObject, NSWindowDelegate {
    private var panel: KeyablePanel?

    func show() {
        if let existing = panel {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let rootView = HookStatusCardView(
            runCheck: { HookHealth().check() },
            runRepair: { HookRepair.run(appPath: Bundle.main.bundlePath) },
            onDismiss: { [weak self] in self?.dismiss() }
        )

        let size = NSSize(width: 360, height: 320)
        let screenFrame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        let origin = NSPoint(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.midY - size.height / 2
        )
        let hosting = NSHostingView(rootView: rootView)
        hosting.frame = NSRect(origin: .zero, size: size)

        let p = KeyablePanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        p.contentView = hosting
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .floating
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.delegate = self
        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        panel = p
    }

    private func dismiss() {
        // close() (not orderOut()) so NSApp releases the window — see
        // AboutWindow.dismiss for the leak rationale.
        panel?.close()
        panel = nil
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor [weak self] in
            self?.panel = nil
        }
    }
}

private struct HookStatusCardView: View {
    let runCheck: () -> HookHealthReport
    let runRepair: () -> Void
    let onDismiss: () -> Void

    @State private var report: HookHealthReport?

    private static let accent = Color(red: 0.31, green: 0.80, blue: 0.77)

    var body: some View {
        ZStack {
            Color.black.opacity(0.6)
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Hook Status")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                    Spacer()
                    if let report {
                        Circle()
                            .fill(report.isHealthy ? Color.green : Color.orange)
                            .frame(width: 8, height: 8)
                    }
                }
                .padding(.bottom, 4)

                if let report {
                    row(agentRow(title: "Claude hooks", status: report.claudeHooks,
                                 agentName: "Claude Code"))
                    row(agentRow(title: "Codex hooks", status: report.codexHooks,
                                 agentName: "Codex"))
                    row((report.bridgeLauncher ? .ok : .bad,
                         "Bridge launcher",
                         report.bridgeLauncher ? "executable" : "missing"))
                    row((report.launcherResolvesApp ? .ok : .bad,
                         "Launcher target",
                         report.launcherResolvesApp ? "this app bundle" : "not this bundle"))
                    row((report.socketReachable ? .ok : .bad,
                         "Socket",
                         report.socketReachable ? "reachable" : "unreachable"))
                    row(statusLineRow(report.statusLine))
                }

                HStack(spacing: 10) {
                    Spacer()
                    Button {
                        runRepair()
                        report = runCheck()
                    } label: {
                        Text("Repair Hooks")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Self.accent)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .background(Self.accent.opacity(0.15))
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)

                    Button(action: onDismiss) {
                        Text("Close")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.7))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .background(Color.white.opacity(0.08))
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                }
                .padding(.top, 8)
            }
            .padding(20)
            .frame(width: 330)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(white: 0.12))
            )
            .contentShape(Rectangle())
            .onTapGesture { /* swallow tap so backdrop doesn't dismiss */ }
        }
        .onAppear { report = runCheck() }
    }

    // MARK: - Rows

    private enum RowState {
        case ok, bad, neutral
    }

    private func row(_ model: (RowState, String, String)) -> some View {
        HStack(spacing: 8) {
            switch model.0 {
            case .ok:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.green)
            case .bad:
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.orange)
            case .neutral:
                Image(systemName: "minus.circle")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.35))
            }
            Text(model.1)
                .font(.system(size: 12))
                .foregroundColor(.white)
            Spacer()
            Text(model.2)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.55))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func agentRow(
        title: String,
        status: HookHealthReport.AgentHooksStatus,
        agentName: String
    ) -> (RowState, String, String) {
        switch status {
        case .installed:
            return (.ok, title, "installed")
        case .partial(let missing):
            return (.bad, title, "missing \(missing.count) event\(missing.count == 1 ? "" : "s")")
        case .missing:
            return (.bad, title, "not installed")
        case .notInstalled:
            return (.neutral, title, "\(agentName) not found")
        case .unreadable:
            return (.bad, title, "config unreadable")
        }
    }

    private func statusLineRow(
        _ mode: HookHealthReport.StatusLineMode
    ) -> (RowState, String, String) {
        switch mode {
        case .direct:
            return (.ok, "statusLine", "direct")
        case .mux:
            return (.ok, "statusLine", "mux (third-party preserved)")
        case .userRenderer:
            return (.ok, "statusLine", "user renderer")
        case .thirdParty(let command):
            return (.bad, "statusLine", "third-party: \(command)")
        case .absent:
            return (.neutral, "statusLine", "not installed")
        case .unreadable:
            return (.bad, "statusLine", "unreadable")
        }
    }
}
```

- [ ] **Step 5.3: Build**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`

- [ ] **Step 5.4: Commit**

```bash
git add Sources/AppLib/Hooks/HookRepair.swift Sources/AppLib/MenuBar/HookStatusWindow.swift
git commit -m "feat(menubar): add Hook Status window with repair button"
```

---

### Task 6: Wire into both menu surfaces + AppDelegate

**Files:**
- Modify: `Sources/AppLib/MenuBar/StatusBarMenu.swift`
- Modify: `Sources/AppLib/SimulatedNotch/GearMenuTarget.swift`
- Modify: `Sources/AppLib/SimulatedNotch/SimulatedNotchFullView.swift`
- Modify: `Sources/ZackEyes/AppDelegate.swift`

- [ ] **Step 6.1: StatusBarMenu — item + handler**

In `StatusBarMenu.swift` add a stored property next to `aboutWindow` (line 19):

```swift
    private var hookStatusWindow: HookStatusWindow?
```

In `build()`, after the `menu.addItem(hotkey)` line (line 64), insert:

```swift
        let hookStatus = NSMenuItem(
            title: "Hook Status…",
            action: #selector(hookStatusClicked(_:)),
            keyEquivalent: ""
        )
        hookStatus.target = self
        menu.addItem(hookStatus)
```

In the `// MARK: - Actions` section, after `hotkeyClicked`:

```swift
    @objc private func hookStatusClicked(_ sender: Any?) {
        // Lazily create once and reuse — same pattern as aboutWindow.
        if hookStatusWindow == nil {
            hookStatusWindow = HookStatusWindow()
        }
        hookStatusWindow?.show()
    }
```

- [ ] **Step 6.2: GearMenuTarget — handler**

In `GearMenuTarget.swift` add a stored property after `private var previewSound: NSSound?` (line 19):

```swift
    private var hookStatusWindow: HookStatusWindow?
```

Add after `hotkeyClicked` (line 29):

```swift
    @objc func hookStatusClicked(_ sender: Any?) {
        // Standalone window (not an in-panel overlay): the status card needs
        // to outlive the notch's hover-collapse, and one implementation can
        // then serve both menu surfaces.
        modeStore?.isMenuOpen = false
        if hookStatusWindow == nil {
            hookStatusWindow = HookStatusWindow()
        }
        hookStatusWindow?.show()
    }
```

- [ ] **Step 6.3: SimulatedNotchFullView — gear-menu item**

In `popGearMenu()`, after `menu.addItem(hotkey)` (line 375), insert:

```swift
        let hookStatus = NSMenuItem(
            title: "Hook Status…",
            action: #selector(GearMenuTarget.hookStatusClicked(_:)),
            keyEquivalent: ""
        )
        hookStatus.target = GearMenuTarget.shared
        menu.addItem(hookStatus)
```

- [ ] **Step 6.4: AppDelegate — reuse HookRepair**

Replace the step-5 block (`AppDelegate.swift` lines 215-233):

```swift
        // 5. Hook Installer (silent, best-effort) — same path as the Hook
        //    Status window's Repair button.
        Task {
            HookRepair.run(appPath: Bundle.main.bundlePath)
        }
```

- [ ] **Step 6.5: Build + full test suite**

Run: `swift build 2>&1 | tail -3 && swift test 2>&1 | tail -5`
Expected: build complete, all tests PASS

- [ ] **Step 6.6: Manual verification**

```bash
make run
```
Then verify by hand:
1. Status-bar icon right-click → "Hook Status…" opens the card; all six rows render; with the app running, Socket row shows ✓ reachable.
2. Simulated-notch gear menu → "Hook Status…" opens the same card (notchless Mac).
3. `cp ~/.claude/settings.json /tmp/settings.json.pretest` (AGENTS.md rule), edit `~/.claude/settings.json` to delete one of our hook events → reopen card → Claude row shows "missing 1 event" → click **Repair Hooks** → row flips to ✓ installed → `diff <(jq -S . ~/.claude/settings.json) <(jq -S . /tmp/settings.json.pretest)` shows only the hooks restoration, and exactly one new backup file appeared.
4. Click Repair again with everything healthy → `ls ~/.claude/settings.json.backup.*` count unchanged (no-op guard).
5. Backdrop click and Esc both dismiss; panel doesn't steal focus from the frontmost app beyond the keyable panel itself.

- [ ] **Step 6.7: Commit**

```bash
git add Sources/AppLib/MenuBar/StatusBarMenu.swift Sources/AppLib/SimulatedNotch/GearMenuTarget.swift Sources/AppLib/SimulatedNotch/SimulatedNotchFullView.swift Sources/ZackEyes/AppDelegate.swift
git commit -m "feat: wire Hook Status into status-bar and gear menus"
```

---

### Task 7: Docs + final sweep

**Files:**
- Modify: `ARCHITECTURE.md` (module tables)

- [ ] **Step 7.1: ARCHITECTURE.md updates**

In the **Hook 安装** module table, update the `HookInstaller` row's 职责 cell — append: `；重装为 no-op 时跳过备份与写入（幂等，防 backup 刷屏）`. Same for `CodexHookInstaller`. Add two rows:

```markdown
| `HookHealth` | `Sources/AppLib/Hooks/HookHealth.swift` | 只读健康检查（#38）：claude/codex hook 条目完整性、bridge launcher 可执行、launcher 解析是否指向当前 bundle、socket 存在性、statusLine 归属四态分类。复用 installer 的事件表与条目识别，绝不写任何文件。 |
| `HookRepair` | `Sources/AppLib/Hooks/HookRepair.swift` | 共享修复入口 = deployLauncherScript + 双 installer 重装；AppDelegate 启动与 Hook Status 窗口 Repair 按钮共用。 |
```

In the **菜单栏 fallback** module table, add:

```markdown
| `HookStatusWindow` | `Sources/AppLib/MenuBar/HookStatusWindow.swift` | Hook Status 卡片（KeyablePanel + SwiftUI，仿 AboutWindow）：6 行健康状态 + Repair Hooks 按钮；状态栏右键菜单与齿轮菜单共用同一实现。 |
```

- [ ] **Step 7.2: Full suite + change checklist**

Run: `swift build 2>&1 | tail -3 && swift test 2>&1 | tail -5 && make app 2>&1 | tail -3`
Expected: all green.

Walk the AGENTS.md HookInstaller checklist: backup-before-write ✓ (kept, now only on real change), only hooks/statusLine keys ✓, parse-failure bail ✓, `zackeyes` + `--agent` markers ✓ (unchanged), uninstall untouched ✓, config.toml never read/written ✓ (health check reads only `hooks.json`).

- [ ] **Step 7.3: Commit**

```bash
git add ARCHITECTURE.md
git commit -m "docs: document HookHealth/HookRepair/HookStatusWindow modules"
```

---

### Task 8: Ship

Follow the flow precedent from #100–#105 (memory `issue-38-hook-health`):

- [ ] Push branch, open PR titled `feat(hooks): add Hook Status and Repair Hooks surface (#38)` with body covering: 6 status fields, repair = idempotent re-install, no-op backup guard, both menu surfaces, test coverage (third-party preservation + statusLine ownership per acceptance criteria). Use superpowers:finishing-a-development-branch.
- [ ] Evaluate bot review → fix valid points → reply dispositions → squash-merge.
- [ ] After merge: tick #38 in roadmap issue **#92** (v0.7.0 section) in the same turn (memory `roadmap-92-keep-synced`); close issue #38; update memory `issue-38-hook-health` → DONE.

---

## Self-Review Notes

- **Spec coverage:** 6 status fields → `HookHealthReport` fields 1:1 (claudeHooks, codexHooks, bridgeLauncher, launcherResolvesApp, socketReachable, statusLine). Repair behavior → existing installers via `HookRepair` (reinstall own entries / preserve third-party / backup-before-write / no config.toml). Acceptance: health visible without opening config files → window; safe repair → installer invariants + no-op guard; tests for third-party preservation (`thirdPartyEntriesAloneAreNotOurs`, `mixedThirdPartyAndOursIsInstalled`, existing installer tests) and statusLine ownership (5 classification tests).
- **Known approximation:** launcher resolution skips the script's baked-in deploy path and mdfind fallback (documented in code comment).
- **Test hermeticity traps:** always inject `socketPath`/`currentAppPath`/`launcherFallbackAppPaths` (dev machine has the real app installed); bind test sockets under `/tmp` directly (104-byte `sun_path` cap).
- **`.none` shadowing (resolved in Task 1 review):** the "no statusLine key" case is named `.absent`, not `.none` — a case named `none` silently collides with `Optional.none` once optionals of the type appear (quality-review finding, fixed by rename before any consumers existed).
