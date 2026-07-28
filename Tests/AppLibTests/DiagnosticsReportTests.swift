import Testing
import Foundation
@testable import AppLib

struct DiagnosticsReportTests {

    private func sampleHealth(statusLine: HookHealthReport.StatusLineMode = .direct)
        -> HookHealthReport {
        HookHealthReport(
            claudeHooks: .installed,
            codexHooks: .notInstalled,
            bridgeLauncher: true,
            launcherResolvesApp: true,
            socketReachable: true,
            statusLine: statusLine
        )
    }

    private func sampleUsage(lastUpdated: Date?) -> UsageTracker.Snapshot {
        var s = UsageTracker.Snapshot.empty
        s.fiveHourUsedPct = 34
        s.lastUpdated = lastUpdated
        return s
    }

    private let redactor = Redactor(homeDirectory: "/Users/alice", username: "alice")

    @Test func reportContainsCoreSections() {
        let text = DiagnosticsReport.generate(
            health: sampleHealth(),
            usage: sampleUsage(lastUpdated: Date(timeIntervalSince1970: 1_700_000_000)),
            appVersion: "0.7.0",
            osVersion: "15.3.2",
            arch: "arm64",
            events: [],
            redactor: redactor,
            now: Date(timeIntervalSince1970: 1_700_000_060)
        )
        // Human-readable headers present
        #expect(text.contains("ZackEyes Diagnostics"))
        // Absolute generation timestamp (UTC ISO8601) from the injected `now`.
        #expect(text.contains("Generated: 2023-11-14T22:14:20Z"))
        #expect(text.contains("App version: 0.7.0"))
        #expect(text.contains("macOS: 15.3.2"))
        #expect(text.contains("Architecture: arm64"))
        #expect(text.contains("Claude hooks: installed"))
        #expect(text.contains("Codex hooks: not installed"))
        #expect(text.contains("Bridge launcher: ok"))
        #expect(text.contains("Launcher resolves app: ok"))
        #expect(text.contains("Socket: reachable"))
        #expect(text.contains("statusLine: direct"))
        // usage freshness present (age, not raw prompt content)
        #expect(text.contains("Usage last updated:"))
    }

    @Test func reportRedactsThirdPartyStatusLinePath() {
        let text = DiagnosticsReport.generate(
            health: sampleHealth(statusLine: .thirdParty(
                command: "/Users/alice/.local/bin/hud --user alice")),
            usage: sampleUsage(lastUpdated: nil),
            appVersion: "0.7.0", osVersion: "15.3.2", arch: "arm64",
            events: [],
            redactor: redactor, now: Date(timeIntervalSince1970: 1_700_000_060)
        )
        // #125/F-007: only the executable basename is exported — the full command
        // (paths, args, the `--user alice` token) is dropped, not just redacted.
        #expect(text.contains("statusLine: third-party: hud"))
        #expect(!text.contains("/Users/alice"))
        #expect(!text.contains("alice"))
        #expect(!text.contains("--user"))
    }

    @Test func reportDropsEnvPrefixedStatusLineSecret() {
        // #125 / Codex review (PR #140): `VAR=secret cmd` must not surface the
        // env assignment as the "basename".
        let text = DiagnosticsReport.generate(
            health: sampleHealth(statusLine: .thirdParty(
                command: "API_KEY=supersecret /usr/local/bin/hud --flag")),
            usage: sampleUsage(lastUpdated: nil),
            appVersion: "0.7.0", osVersion: "15.3.2", arch: "arm64",
            events: [],
            redactor: redactor, now: Date(timeIntervalSince1970: 1_700_000_060)
        )
        #expect(text.contains("statusLine: third-party: hud"))
        #expect(!text.contains("API_KEY"))
        #expect(!text.contains("supersecret"))
    }

    @Test func reportNeverContainsSensitiveLabels() {
        let text = DiagnosticsReport.generate(
            health: sampleHealth(),
            usage: sampleUsage(lastUpdated: Date(timeIntervalSince1970: 1_700_000_000)),
            appVersion: "0.7.0", osVersion: "15.3.2", arch: "arm64",
            events: [],
            redactor: redactor, now: Date(timeIntervalSince1970: 1_700_000_060)
        )
        // Sanity: report is a fixed-schema summary, so it must not carry
        // free-form prompt/assistant/tool-arg fields. These keys must be absent.
        #expect(!text.lowercased().contains("prompt"))
        #expect(!text.lowercased().contains("assistant"))
        #expect(!text.lowercased().contains("tool_input"))
    }

    @Test func usageMissingReportedAsNeverUpdated() {
        let text = DiagnosticsReport.generate(
            health: sampleHealth(),
            usage: sampleUsage(lastUpdated: nil),
            appVersion: "0.7.0", osVersion: "15.3.2", arch: "arm64",
            events: [],
            redactor: redactor, now: Date(timeIntervalSince1970: 1_700_000_060)
        )
        #expect(text.contains("Usage last updated: never"))
    }

    @Test func unreadableHookConfigSurfacedNotCrashed() {
        let text = DiagnosticsReport.generate(
            health: sampleHealth(),  // tweak below
            usage: sampleUsage(lastUpdated: nil),
            appVersion: "0.7.0", osVersion: "15.3.2", arch: "arm64",
            events: [],
            redactor: redactor, now: Date(timeIntervalSince1970: 1_700_000_060)
        )
        _ = text  // smoke: generate must not throw/crash on any health state
        let unreadable = DiagnosticsReport.generate(
            health: HookHealthReport(
                claudeHooks: .unreadable, codexHooks: .partial(missing: ["Stop"]),
                bridgeLauncher: false, launcherResolvesApp: false,
                socketReachable: false, statusLine: .unreadable),
            usage: sampleUsage(lastUpdated: nil),
            appVersion: "0.7.0", osVersion: "15.3.2", arch: "arm64",
            events: [],
            redactor: redactor, now: Date(timeIntervalSince1970: 1_700_000_060))
        #expect(unreadable.contains("Claude hooks: config unreadable"))
        #expect(unreadable.contains("Codex hooks: missing 1 event"))
        #expect(unreadable.contains("Bridge launcher: MISSING"))
        #expect(unreadable.contains("statusLine: unreadable"))
    }

    // MARK: - Recent events (#205 item 3)

    private func entry(
        event: String,
        tool: String? = nil,
        replayed: Bool = false,
        disposition: EventDisposition,
        offset: Double = 0
    ) -> EventTraceEntry {
        EventTraceEntry(
            at: Date(timeIntervalSince1970: 1_700_000_000 + offset),
            agent: "claude", event: event, tool: tool, session: "a1b2c3d4",
            replayed: replayed, disposition: disposition
        )
    }

    private func report(events: [EventTraceEntry]) -> String {
        DiagnosticsReport.generate(
            health: sampleHealth(),
            usage: sampleUsage(lastUpdated: nil),
            appVersion: "0.7.0", osVersion: "15.3.2", arch: "arm64",
            events: events,
            redactor: redactor, now: Date(timeIntervalSince1970: 1_700_000_060)
        )
    }

    @Test func eventSectionExplainsWhyANotificationDidNotFire() {
        let text = report(events: [
            entry(event: "PermissionRequest", tool: "Bash", disposition: .prompted),
            entry(event: "PermissionRequest", tool: "Bash",
                  disposition: .suppressed("waiting alert: cooldown"), offset: 3)
        ])
        #expect(text.contains("Recent events"))
        // Absolute UTC clock time, so it can be matched against "I pressed it at…".
        #expect(text.contains("22:13:20"))
        #expect(text.contains("PermissionRequest"))
        #expect(text.contains("tool=Bash"))
        #expect(text.contains("sid=a1b2c3d4"))
        #expect(text.contains("→ prompted"))
        #expect(text.contains("→ suppressed (waiting alert: cooldown)"))
    }

    /// The other dimension: an event the bridge spooled while the app was
    /// closed never notifies, and that has to be visible on the line.
    @Test func replayedEventsAreMarked() {
        let text = report(events: [
            entry(event: "Stop", replayed: true, disposition: .applied)
        ])
        #expect(text.contains("[replayed]"))
    }

    /// An entry no branch claimed says so rather than looking like a normal
    /// applied event — a visible gap beats a silent one.
    @Test func unclassifiedEventsSaySo() {
        let text = report(events: [entry(event: "Notification", disposition: .received)])
        #expect(text.contains("→ received (unclassified)"))
    }

    @Test func emptyTraceSaysSoInsteadOfPrintingAnEmptySection() {
        #expect(report(events: []).contains("No events recorded yet."))
    }

    /// Every free-text field originates in bridge JSON. An MCP tool name can
    /// carry a private server name, and the report is meant to be attachable
    /// to a public issue.
    @Test func eventFieldsAreRedacted() {
        let text = report(events: [
            entry(event: "PreToolUse", tool: "mcp__alice__query", disposition: .applied)
        ])
        #expect(!text.contains("alice"))
        #expect(text.contains("mcp__<user>__query"))
    }

    @Test func overlongEventFieldsAreCapped() {
        let long = String(repeating: "z", count: 200)
        let text = report(events: [entry(event: "PreToolUse", tool: long, disposition: .applied)])
        #expect(!text.contains(long))
        #expect(text.contains("…"))
        // Nothing in the section may run away with the report's width.
        let widest = text.split(separator: "\n").map(\.count).max() ?? 0
        #expect(widest < 140)
    }
}
