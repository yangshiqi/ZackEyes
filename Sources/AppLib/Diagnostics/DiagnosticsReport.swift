import Foundation

/// Assembles a privacy-redacted, human-readable diagnostics report (#47).
/// `generate` is pure (all inputs injected) so it's fully testable; `current`
/// is the thin gatherer that reads live state. NEVER emits prompt/assistant/
/// tool-argument text or full config contents — it's a fixed-schema summary
/// of health booleans, versions, and usage timestamps, all run through the
/// `Redactor`.
public enum DiagnosticsReport {

    public static func generate(
        health: HookHealthReport,
        usage: UsageTracker.Snapshot,
        appVersion: String,
        osVersion: String,
        arch: String,
        redactor: Redactor,
        now: Date
    ) -> String {
        var lines: [String] = []
        lines.append("ZackEyes Diagnostics")
        lines.append("====================")
        lines.append("Generated: \(iso8601(now))")
        lines.append("App version: \(appVersion)")
        lines.append("macOS: \(osVersion)")
        lines.append("Architecture: \(arch)")
        lines.append("")
        lines.append("Hooks")
        lines.append("-----")
        lines.append("Claude hooks: \(describe(health.claudeHooks))")
        lines.append("Codex hooks: \(describe(health.codexHooks))")
        lines.append("Bridge launcher: \(health.bridgeLauncher ? "ok" : "MISSING")")
        lines.append("Launcher resolves app: \(health.launcherResolvesApp ? "ok" : "MISMATCH")")
        lines.append("Socket: \(health.socketReachable ? "reachable" : "unreachable")")
        lines.append("statusLine: \(describe(health.statusLine, redactor: redactor))")
        lines.append("Overall: \(health.isHealthy ? "healthy" : "needs attention")")
        lines.append("")
        lines.append("Usage")
        lines.append("-----")
        lines.append("Usage last updated: \(freshness(usage.lastUpdated, now: now))")
        lines.append("Claude usage data: \(usage.hasClaudeData ? "present" : "none")")
        lines.append("Codex usage data: \(usage.hasCodexData ? "present" : "none")")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Live gatherer. Reads HookHealth (real paths) + Bundle/ProcessInfo and
    /// the passed usage snapshot, then redacts. Caller supplies the snapshot
    /// so this stays free of the @MainActor UsageTracker dependency.
    @MainActor
    public static func current(usageSnapshot: UsageTracker.Snapshot) -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return generate(
            health: HookHealth().check(),
            usage: usageSnapshot,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
            osVersion: "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
            arch: currentArch,
            redactor: Redactor(),
            now: Date()
        )
    }

    private static var currentArch: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    private static func describe(_ s: HookHealthReport.AgentHooksStatus) -> String {
        switch s {
        case .installed: return "installed"
        case .partial(let missing): return "missing \(missing.count) event\(missing.count == 1 ? "" : "s")"
        case .missing: return "not installed"
        case .notInstalled: return "not installed"
        case .unreadable: return "config unreadable"
        }
    }

    private static func describe(
        _ m: HookHealthReport.StatusLineMode, redactor: Redactor
    ) -> String {
        switch m {
        case .direct: return "direct"
        case .mux: return "mux"
        case .userRenderer: return "user renderer"
        case .thirdParty(let cmd):
            // Only the executable basename — the full command line can carry
            // tokens, credential URLs, non-home paths, and hostnames the Redactor
            // (home / username only) does not catch (#125/F-007).
            return "third-party: \(redactor.redact(Self.commandBasename(cmd)))"
        case .absent: return "not installed"
        case .unreadable: return "unreadable"
        }
    }

    /// Reduce an arbitrary third-party statusLine command to just its executable
    /// basename so the diagnostics export can't leak args / tokens / paths (#125).
    private static func commandBasename(_ command: String) -> String {
        let firstToken = command
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .first.map(String.init) ?? command
        let base = (firstToken as NSString).lastPathComponent
        return base.isEmpty ? "<command>" : base
    }

    private static func freshness(_ date: Date?, now: Date) -> String {
        guard let date else { return "never" }
        let secs = Int(now.timeIntervalSince(date))
        if secs < 60 { return "\(max(secs, 0))s ago" }
        if secs < 3600 { return "\(secs / 60)m ago" }
        if secs < 86400 { return "\(secs / 3600)h ago" }
        return "\(secs / 86400)d ago"
    }

    /// Absolute report-generation time (UTC ISO8601) so the relative usage
    /// ages above stay interpretable once the report is detached/attached
    /// to an issue. Timestamp only — privacy-safe.
    private static func iso8601(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }
}
