import Foundation
import Testing
@testable import AppLib

@MainActor
struct CodexQuotaRecoveryScanTests {
    @Test(arguments: ["early", "expired", "model", "untimestamped", "separate-rollouts"])
    func scanUsesTimestampedAccountReadingsFromOneRollout(scenario: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let day = root.appendingPathComponent("2026/10/28")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let now = Date().addingTimeInterval(-1)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func event(used: Double, at date: Date, reset: Date) throws -> String {
            var limits: [String: Any] = ["limit_id": "codex", "primary": [
                "used_percent": used, "window_minutes": 300, "resets_at": reset.timeIntervalSince1970]]
            if scenario == "model" { limits["limit_name"] = "GPT-only" }
            var event: [String: Any] = ["type": "event_msg", "payload": ["type": "token_count", "rate_limits": limits]]
            if scenario != "untimestamped" { event["timestamp"] = formatter.string(from: date) }
            return String(decoding: try JSONSerialization.data(withJSONObject: event), as: UTF8.self) + "\n"
        }
        let before = try event(used: 80, at: now.addingTimeInterval(-120),
                               reset: now.addingTimeInterval(scenario == "expired" ? -60 : 3600))
        let after = try event(used: 1, at: now.addingTimeInterval(-30), reset: now.addingTimeInterval(3600))
        let file = day.appendingPathComponent("rollout-one.jsonl")
        if scenario == "separate-rollouts" {
            try before.write(to: file, atomically: true, encoding: .utf8)
            try after.write(to: day.appendingPathComponent("rollout-two.jsonl"), atomically: true, encoding: .utf8)
        } else {
            // Additional post-recovery usage must preserve the observed recovery.
            let final = try event(used: 2, at: now, reset: now.addingTimeInterval(3600))
            try (before + after + final).write(to: file, atomically: true, encoding: .utf8)
        }
        let state = try #require(UsageTracker.scanLatestCodexState(rootDir: root))
        let recoveries = state.accountReadings.compactMap(\.recoveredAt)
        #expect(recoveries.isEmpty == (scenario != "early"))
        if scenario == "early" {
            let sample = try #require(state.accountReadings.first)
            #expect(abs(sample.observedAt.timeIntervalSince(now)) < 0.01)
            #expect(sample.quota.fiveHourUsedPct == 2)
        }
        if scenario == "model" || scenario == "untimestamped" {
            #expect(state.accountReadings.isEmpty)
        }
    }

    @Test(arguments: [true, false])
    func tailKeepsOriginalDeadlineThroughRevisions(revisedLater: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let day = root.appendingPathComponent("2026/10/28")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let now = Date().addingTimeInterval(-1)
        let iso = ISO8601DateFormatter()
        let values = [(80, -180.0, revisedLater ? -60.0 : 3600.0),
                      (81, -120.0, revisedLater ? 7200.0 : -60.0), (1, 0.0, 10800.0)]
        let lines = values.map { used, offset, resetOffset in
            """
            {"timestamp":"\(iso.string(from: now.addingTimeInterval(offset)))","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"window_minutes":300,"used_percent":\(used),"resets_at":\(Int(now.addingTimeInterval(resetOffset).timeIntervalSince1970))}}}}
            """
        }.joined(separator: "\n")
        try lines.write(to: day.appendingPathComponent("rollout-test.jsonl"), atomically: true, encoding: .utf8)
        let state = try #require(UsageTracker.scanLatestCodexState(rootDir: root))
        #expect((state.accountReadings.first?.recoveredAt != nil) == !revisedLater)
    }

    @Test func restartedTrackerDoesNotTrustRecoveryInTruncatedHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let day = root.appendingPathComponent("2026/10/28")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let now = Date().addingTimeInterval(-1)
        let iso = ISO8601DateFormatter()
        func event(_ used: Int, _ offset: Double, _ resetOffset: Double) -> String {
            """
            {"timestamp":"\(iso.string(from: now.addingTimeInterval(offset)))","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"window_minutes":300,"used_percent":\(used),"resets_at":\(Int(now.addingTimeInterval(resetOffset).timeIntervalSince1970))}}}}
            """ + "\n"
        }
        // The tail loses the original deadline, retaining only a revised high
        // reading followed by the ordinary reset after the original deadline.
        let contents = event(80, -180, -60) + String(repeating: "x", count: 1_048_576) + "\n"
            + event(81, -120, 7200) + event(1, 0, 10800)
        try contents.write(to: day.appendingPathComponent("rollout-test.jsonl"), atomically: true, encoding: .utf8)
        let state = try #require(UsageTracker.scanLatestCodexState(rootDir: root))
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let tracker = CodexResetTracker(config: ConfigStore(directory: root.appendingPathComponent("config").path),
            defaults: defaults, now: { now }, fetch: {
                Data("""
                {"schema_version":1,"generated_at":"\(iso.string(from: now))","scheduled":null,"events":[{"kind":"regular","url":"https://x.com/example/status/123","announced_at":"\(iso.string(from: now.addingTimeInterval(-240)))"}]}
                """.utf8)
            })
        await tracker.refresh(activeCodex: true)
        tracker.recordQuotaReadings(state.accountReadings)
        #expect(tracker.announcement != nil)
        // Re-polling the same truncated tail must not turn its previously
        // rejected historical inference into trusted in-memory evidence.
        tracker.recordQuotaReadings(state.accountReadings)
        #expect(tracker.announcement != nil)
    }

    @Test func refreshPublishesAccountEvidenceFromExistingLocalScan() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let day = root.appendingPathComponent("2026/10/28")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let now = Date().addingTimeInterval(-1)
        let iso = ISO8601DateFormatter()
        let reset = Int(now.addingTimeInterval(3600).timeIntervalSince1970)
        let lines = [(80, now.addingTimeInterval(-60)), (1, now)].map { used, at in
            """
            {"timestamp":"\(iso.string(from: at))","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"window_minutes":300,"used_percent":\(used),"resets_at":\(reset)}}}}
            """
        }.joined(separator: "\n")
        try lines.write(to: day.appendingPathComponent("rollout-test.jsonl"), atomically: true, encoding: .utf8)
        let tracker = UsageTracker(projectsDir: root.appendingPathComponent("no-claude"), codexSessionsDir: root)
        var readings: [CodexQuotaReading] = []
        tracker.onCodexQuotaReadings = { readings = $0 }
        await tracker.refresh()
        #expect(readings.count == 1)
        #expect(readings.first?.recoveredAt != nil)
    }
}
