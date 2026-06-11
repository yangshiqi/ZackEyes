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
