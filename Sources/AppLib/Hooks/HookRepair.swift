import Foundation

/// Best-effort hook (re)installation, shared by AppDelegate startup and the
/// Hook Status window's Repair button. Each installer fails independently —
/// a Claude-side error must not block the Codex install (and vice versa).
/// All safety invariants live in the installers themselves: backup before
/// write, only hooks/statusLine keys, parse-failure bail, no-op skip, and
/// never touching ~/.codex/config.toml.
public enum HookRepair {
    /// #129/F-022 — serialize hook-file mutation so a (re)install can't race the
    /// uninstaller's file sweep (both touch ~/.zackeyes and the agent configs).
    static let hookMutationLock = NSLock()

    public static func run(appPath: String) {
        hookMutationLock.lock()
        defer { hookMutationLock.unlock() }
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
