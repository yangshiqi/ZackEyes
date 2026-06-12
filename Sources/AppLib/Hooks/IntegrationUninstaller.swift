import Foundation

/// #46 — complete integration cleanup. `preview()` is strictly read-only
/// (same probe seam as HookHealth: the installers' own detection internals,
/// so the preview can't drift from what execute() removes). `execute()`
/// composes the existing uninstall primitives — every config write is backed
/// up inside uninstallHooks() — plus removal of ZackEyes-generated files.
///
/// Never touched: user config keys, third-party hook/statusLine entries,
/// `config.json`, `pricing-cache.json`, the user-authored `statusline-user`,
/// and `~/.codex/config.toml` (never read nor written, invariant #1).
public struct IntegrationUninstaller {

    public struct Plan: Equatable, Sendable {
        /// Claude hook events carrying a ZackEyes entry (0–12).
        public let claudeHookEvents: Int
        /// We own the statusLine slot (direct or via mux).
        public let claudeOwnsStatusLine: Bool
        /// Codex hook events carrying a ZackEyes entry (0–6).
        public let codexHookEvents: Int
        /// Absolute paths of ZackEyes-generated files that exist now.
        public let files: [String]

        public var isEmpty: Bool {
            claudeHookEvents == 0 && !claudeOwnsStatusLine
                && codexHookEvents == 0 && files.isEmpty
        }
    }

    private let claudeSettingsPath: String
    private let codexHooksPath: String
    private let bridgePath: String

    public init(
        claudeSettingsPath: String = NSHomeDirectory() + "/.claude/settings.json",
        codexHooksPath: String = NSHomeDirectory() + "/.codex/hooks.json",
        bridgePath: String = "$HOME/.zackeyes/bin/bridge"
    ) {
        self.claudeSettingsPath = claudeSettingsPath
        self.codexHooksPath = codexHooksPath
        self.bridgePath = bridgePath
    }

    private var expandedBridgePath: String {
        bridgePath.replacingOccurrences(of: "$HOME", with: NSHomeDirectory())
    }
    private var binDir: String { (expandedBridgePath as NSString).deletingLastPathComponent }
    private var zackDir: String { (binDir as NSString).deletingLastPathComponent }

    /// ZackEyes-generated artifacts, in display order. `statusline-user` is
    /// deliberately absent — user-authored, never ours to delete.
    private var candidateFiles: [String] {
        [
            expandedBridgePath,
            binDir + "/statusline-mux",
            zackDir + "/.app-path",
            zackDir + "/.statusline-original",
            zackDir + "/pending",
        ]
    }

    // MARK: - Preview (read-only)

    public func preview() -> Plan {
        let claudeInstaller = HookInstaller(
            settingsPath: claudeSettingsPath, bridgePath: bridgePath)
        let codexInstaller = CodexHookInstaller(
            hooksPath: codexHooksPath, bridgePath: bridgePath)

        let claudeDoc = load(claudeSettingsPath)
        let codexDoc = load(codexHooksPath)

        let statusLineCommand =
            (claudeDoc?["statusLine"] as? [String: Any])?["command"] as? String
        let ownsStatusLine: Bool
        switch claudeInstaller.statusLineMode(of: statusLineCommand) {
        case .direct, .mux, .userRenderer: ownsStatusLine = true
        case .thirdParty, .absent, .unreadable: ownsStatusLine = false
        }

        return Plan(
            claudeHookEvents: ownedEventCount(
                in: claudeDoc, events: HookInstaller.hookEvents,
                isOurs: claudeInstaller.isZackEyesEntry),
            claudeOwnsStatusLine: ownsStatusLine,
            codexHookEvents: ownedEventCount(
                in: codexDoc, events: CodexHookInstaller.hookEvents,
                isOurs: codexInstaller.isZackEyesEntry),
            files: candidateFiles.filter { FileManager.default.fileExists(atPath: $0) }
        )
    }

    private func load(_ path: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func ownedEventCount(
        in doc: [String: Any]?, events: [String], isOurs: ([String: Any]) -> Bool
    ) -> Int {
        guard let hooks = doc?["hooks"] as? [String: Any] else { return 0 }
        return events.filter { event in
            ((hooks[event] as? [[String: Any]]) ?? []).contains(where: isOurs)
        }.count
    }

    // MARK: - Execute

    /// Best-effort: each step independent, errors logged not thrown. The
    /// uninstall primitives carry the safety contract (backup-before-write,
    /// third-party preservation, parse-failure bail).
    ///
    /// Returns `true` when cleanup completed fully (configs clean, files
    /// swept). Returns `false` when hook entries could not be removed —
    /// in that case the generated files are deliberately KEPT: deleting
    /// the launcher while configs still reference it would turn every
    /// hook invocation into a user-visible exit-127 error, the exact
    /// terminal pollution invariant #2 exists to prevent (codex review,
    /// PR #111).
    @discardableResult
    public func execute() -> Bool {
        do {
            try HookInstaller(
                settingsPath: claudeSettingsPath, bridgePath: bridgePath
            ).uninstallHooks()
        } catch {
            NSLog("ZackEyes: claude uninstall failed: \(error)")
        }
        do {
            try CodexHookInstaller(
                hooksPath: codexHooksPath, bridgePath: bridgePath
            ).uninstallHooks()
        } catch {
            NSLog("ZackEyes: codex uninstall failed: \(error)")
        }

        // Gate the file sweep on the configs actually being clean. An
        // unreadable config counts as dirty: parse failure means our
        // entries may still be inside, even though preview() can't see
        // them.
        let residue = preview()
        guard residue.claudeHookEvents == 0,
              !residue.claudeOwnsStatusLine,
              residue.codexHookEvents == 0,
              !isUnreadable(claudeSettingsPath),
              !isUnreadable(codexHooksPath)
        else {
            NSLog("ZackEyes: uninstall incomplete — keeping launcher (claude:%d codex:%d statusLine:%d)",
                  residue.claudeHookEvents, residue.codexHookEvents,
                  residue.claudeOwnsStatusLine ? 1 : 0)
            return false
        }

        for path in candidateFiles {
            try? FileManager.default.removeItem(atPath: path)
        }
        return true
    }

    /// File exists but isn't parseable JSON — contents unknown, treat as
    /// possibly still containing our entries.
    private func isUnreadable(_ path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        return load(path) == nil
    }
}
