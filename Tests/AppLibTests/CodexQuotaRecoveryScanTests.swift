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
