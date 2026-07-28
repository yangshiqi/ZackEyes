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
        events: [EventTraceEntry],
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
        lines.append("")
        lines.append("Recent events")
        lines.append("-------------")
        lines.append(contentsOf: eventLines(events, redactor: redactor))
        return lines.joined(separator: "\n") + "\n"
    }

    /// Renders the event ring buffer (#205 item 3) — the section that answers
    /// "why didn't my notification pop?". Oldest first, so it reads like a log.
    private static func eventLines(
        _ events: [EventTraceEntry], redactor: Redactor
    ) -> [String] {
        guard !events.isEmpty else { return ["No events recorded yet."] }
        var out = ["(oldest first, times UTC; `replayed` = arrived while ZackEyes was closed)"]
        for e in events {
            var parts = [
                clockTime(e.at),
                pad(field(e.agent, redactor: redactor), 6),
                pad(field(e.event, redactor: redactor), 20)
            ]
            if let tool = e.tool { parts.append("tool=\(toolField(tool, redactor: redactor))") }
            if let sid = e.session { parts.append("sid=\(field(sid, redactor: redactor))") }
            if e.replayed { parts.append("[replayed]") }
            parts.append("→ \(describe(e.disposition, redactor: redactor))")
            out.append(parts.joined(separator: "  "))
        }
        return out
    }

    private static func describe(
        _ d: EventDisposition, redactor: Redactor
    ) -> String {
        switch d {
        case .received: return "received (unclassified)"
        case .probe: return "self-test probe"
        case .applied: return "applied"
        case .prompted: return "prompted"
        case .autoAllowed: return "auto-allowed"
        // Deliberately not "notified": the banner is handed to
        // UNUserNotificationCenter, which reports failure asynchronously and
        // can silently drop it (authorization revoked, Focus). Claiming
        // delivery here would produce the exact false reassurance this
        // section exists to prevent.
        case .notified(let kind): return "notification requested (\(field(kind, redactor: redactor)))"
        case .suppressed(let why): return "suppressed (\(field(why, redactor: redactor)))"
        case .dropped(let why): return "dropped (\(field(why, redactor: redactor)))"
        }
    }

    /// Every free-text field in the trace originates in bridge JSON, so it is
    /// attacker-shaped in the same way a third-party statusLine command is:
    /// redact, then cap. An MCP tool name can carry a private server name, and
    /// nothing here is worth an unbounded line in a shareable report.
    private static func field(_ raw: String, redactor: Redactor, max: Int = 40) -> String {
        // Drop control and format scalars outright. They buy nothing in a
        // report and they can smuggle CR, ANSI escapes, zero-width joiners,
        // and bidi overrides into text destined for a GitHub issue.
        let scalars = redactor.redact(raw).unicodeScalars.filter {
            let category = $0.properties.generalCategory
            return category != .control && category != .format
        }
        // Cap by scalar, not by Character: a single Character can be an
        // arbitrarily long combining cluster, so a Character count is not a
        // length bound at all.
        guard scalars.count > max else { return String(String.UnicodeScalarView(scalars)) }
        return String(String.UnicodeScalarView(scalars.prefix(max - 1))) + "…"
    }

    /// MCP tool names carry the user's own server and tool identity
    /// (`mcp__acme-production__customer_lookup`). Keep the diagnostically
    /// useful half — that this was an MCP call at all — and drop the rest;
    /// built-in tool names are a fixed vocabulary and safe to show.
    private static func toolField(_ raw: String, redactor: Redactor) -> String {
        guard raw.hasPrefix("mcp__") else { return field(raw, redactor: redactor) }
        return "mcp__<redacted>"
    }

    private static func pad(_ s: String, _ width: Int) -> String {
        s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
    }

    /// Wall-clock time only (UTC, matching the ISO `Generated:` header). The
    /// report already carries an absolute timestamp, so this stays readable
    /// without adding a second date to every line.
    private static func clockTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
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
            events: EventTrace.shared.entries,
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
    /// basename so the diagnostics export can't leak args, tokens, paths, or
    /// hostnames (#125/F-007). Skips leading `NAME=value` env-assignment prefixes
    /// (which would otherwise surface a secret as the "basename" — Codex review,
    /// PR #140) and honors simple quotes; anything that isn't a clean filename
    /// is replaced with `<custom>` rather than risk leaking a fragment.
    private static func commandBasename(_ command: String) -> String {
        let exe = firstExecutableToken(command)
        let base = (exe as NSString).lastPathComponent
        let isCleanSlug = !base.isEmpty && base.allSatisfy { c in
            c.isASCII && (c.isLetter || c.isNumber || c == "-" || c == "_" || c == ".")
        }
        return isCleanSlug ? base : "<custom>"
    }

    /// First non-env-assignment token of a shell-ish command, honoring simple
    /// single/double quotes so a quoted path with spaces stays one token.
    private static func firstExecutableToken(_ command: String) -> String {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        for ch in command {
            if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }
            } else if ch == "\"" || ch == "'" {
                quote = ch
            } else if ch == " " || ch == "\t" {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens.first(where: { !isEnvAssignment($0) }) ?? ""
    }

    private static func isEnvAssignment(_ token: String) -> Bool {
        guard let eq = token.firstIndex(of: "="), eq != token.startIndex else { return false }
        return token[..<eq].allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
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
