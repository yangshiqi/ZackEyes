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
            redactor: redactor, now: Date(timeIntervalSince1970: 1_700_000_060)
        )
        #expect(text.contains("~/.local/bin/hud --user <user>"))
        #expect(!text.contains("/Users/alice"))
        #expect(!text.contains("alice"))
    }

    @Test func reportNeverContainsSensitiveLabels() {
        let text = DiagnosticsReport.generate(
            health: sampleHealth(),
            usage: sampleUsage(lastUpdated: Date(timeIntervalSince1970: 1_700_000_000)),
            appVersion: "0.7.0", osVersion: "15.3.2", arch: "arm64",
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
            redactor: redactor, now: Date(timeIntervalSince1970: 1_700_000_060)
        )
        #expect(text.contains("Usage last updated: never"))
    }

    @Test func unreadableHookConfigSurfacedNotCrashed() {
        let text = DiagnosticsReport.generate(
            health: sampleHealth(),  // tweak below
            usage: sampleUsage(lastUpdated: nil),
            appVersion: "0.7.0", osVersion: "15.3.2", arch: "arm64",
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
            redactor: redactor, now: Date(timeIntervalSince1970: 1_700_000_060))
        #expect(unreadable.contains("Claude hooks: config unreadable"))
        #expect(unreadable.contains("Codex hooks: missing 1 event"))
        #expect(unreadable.contains("Bridge launcher: MISSING"))
        #expect(unreadable.contains("statusLine: unreadable"))
    }
}
