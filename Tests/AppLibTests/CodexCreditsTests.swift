import Foundation
import Testing
@testable import AppLib

@MainActor
struct CodexCreditsTests {
    @Test func decoderPreservesBalanceAndTreatsCreditsAsAnAccountFallback() throws {
        let observation = UsageTracker.decodeCodexObservation(from: [
            "primary": ["used_percent": 100, "window_minutes": 10080],
            "credits": ["has_credits": true, "unlimited": false, "balance": "12345.6789012345"]
        ])
        #expect(observation.credits?.balance == Decimal(string: "12345.6789012345"))
        #expect(observation.isUsingCredits)
        #expect(!observation.limitReached)
        #expect(observation.credits?.balanceLabel == "12,345.68")
    }

    @Test(arguments: ["0", "-1", "", "NaN", "Infinity", "12oops"])
    func unusableBalanceDoesNotSuppressAnExhaustedWindow(balance: String) {
        let observation = UsageTracker.decodeCodexObservation(from: [
            "primary": ["used_percent": 100],
            "credits": ["has_credits": true, "unlimited": false, "balance": balance]
        ])
        #expect(!observation.isUsingCredits)
        #expect(observation.limitReached)
    }

    @Test func explicitOrModelLimitsStillBlockDespitePositiveCredits() {
        for extra: [String: Any] in [["rate_limit_reached_type": "hard_limit"], ["limit_name": "model-specific"]] {
            var fields: [String: Any] = ["primary": ["used_percent": 100],
                "credits": ["has_credits": true, "unlimited": false, "balance": "12"]]
            fields.merge(extra) { _, new in new }
            let observation = UsageTracker.decodeCodexObservation(from: fields)
            #expect(observation.limitReached)
            #expect(!observation.isUsingCredits)
        }
    }

    @Test func availableBalanceAloneDoesNotMeanCreditsAreInUse() {
        let observation = UsageTracker.decodeCodexObservation(from: [
            "primary": ["used_percent": 30],
            "credits": ["has_credits": true, "balance": 120]
        ])
        #expect(observation.credits?.balance == 120)
        #expect(!observation.isUsingCredits)
    }

    @Test func nonBooleanAvailabilityFlagsAreUnknown() throws {
        let fields = try #require(JSONSerialization.jsonObject(with: Data("""
        {"primary":{"used_percent":100},"credits":{"has_credits":1,"unlimited":1,"balance":"120"}}
        """.utf8)) as? [String: Any])
        let observation = UsageTracker.decodeCodexObservation(from: fields)
        #expect(observation.limitReached)
        #expect(!observation.isUsingCredits)
    }

    @Test func unlimitedCreditFallbackHasAnHonestLabel() {
        let observation = UsageTracker.decodeCodexObservation(from: [
            "primary": ["used_percent": 100],
            "credits": ["has_credits": true, "unlimited": true]
        ])
        #expect(observation.isUsingCredits)
        #expect(observation.credits?.balanceLabel == "Unlimited")
    }

    @Test func staleFutureMissingAndRestartedBalancesDoNotShowAsAvailable() throws {
        let now = Date()
        var snapshot = UsageTracker.Snapshot.empty
        snapshot.codexCredits = CodexCredits(hasCredits: true, unlimited: false, balance: 120)
        snapshot.codexCreditsInUse = true
        snapshot.codexCreditsUpdatedAt = now
        snapshot.codexSevenDayUsedPct = 100
        snapshot.codexSevenDayResetsAt = now.addingTimeInterval(3600)
        #expect(snapshot.creditsInUse(at: now) != nil)
        snapshot.codexCreditsUpdatedAt = now.addingTimeInterval(-901)
        #expect(snapshot.creditsInUse(at: now) == nil)
        snapshot.codexCreditsUpdatedAt = now.addingTimeInterval(601)
        #expect(snapshot.creditsInUse(at: now) == nil)
        snapshot.codexCreditsUpdatedAt = nil
        #expect(snapshot.creditsInUse(at: now) == nil)
        snapshot.codexCreditsUpdatedAt = now
        let restored = try JSONDecoder().decode(UsageTracker.Snapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(restored.creditsInUse(at: now) == nil)
    }

    @Test func expiredPlanWindowAndFalseCreditFlagDoNotClaimExtraUsage() {
        let now = Date()
        var snapshot = UsageTracker.Snapshot.empty
        snapshot.codexCredits = CodexCredits(hasCredits: true, unlimited: false, balance: 120)
        snapshot.codexCreditsInUse = true
        snapshot.codexCreditsUpdatedAt = now
        snapshot.codexSevenDayUsedPct = 100
        snapshot.codexSevenDayResetsAt = now.addingTimeInterval(-1)
        #expect(snapshot.creditsInUse(at: now) == nil)
        let observation = UsageTracker.decodeCodexObservation(from: [
            "primary": ["used_percent": 100],
            "credits": ["has_credits": false, "balance": "120"]])
        #expect(observation.limitReached)
        #expect(!observation.isUsingCredits)
        #expect(CodexCredits(hasCredits: true, unlimited: false, balance: Decimal(string: "0.004")).balanceLabel == "<0.01")
    }

    @Test func menuBarUsesCreditStatusWithoutRequiringAFiveHourWindow() {
        var snapshot = UsageTracker.Snapshot.empty
        snapshot.codexSevenDayUsedPct = 100
        snapshot.codexCredits = CodexCredits(hasCredits: true, unlimited: false, balance: 120)
        snapshot.codexCreditsInUse = true
        snapshot.codexCreditsUpdatedAt = Date()
        let icon = MenuBarIconColor.presentation(primaryAgent: .codex, snapshot: snapshot)
        #expect(icon.symbolName == "plus.circle.fill")
        #expect(icon.accessibilityDescription.contains("120"))
        snapshot.codexLimitReached = true
        #expect(MenuBarIconColor.presentation(primaryAgent: .codex, snapshot: snapshot).symbolName != "plus.circle.fill")
    }

    @Test func creditModeExpiresWithItsOwnAccountWindowDespiteOtherSessions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("2026/11/02")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = Date()
        for (name, minutes, reset, timestamp, balance) in [
            ("older", 10080, now.addingTimeInterval(3600), now.addingTimeInterval(-60), "100"),
            ("newest", 300, now.addingTimeInterval(30), now, "120")
        ] {
            let row: [String: Any] = ["type": "event_msg", "timestamp": ISO8601DateFormatter().string(from: timestamp),
                "payload": ["type": "token_count", "rate_limits": [
                    "primary": ["used_percent": 100, "window_minutes": minutes, "resets_at": reset.timeIntervalSince1970],
                    "credits": ["has_credits": true, "balance": balance]]]]
            let file = directory.appendingPathComponent("rollout-\(name).jsonl")
            try JSONSerialization.data(withJSONObject: row).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: file.path)
        }
        let tracker = UsageTracker(projectsDir: root.appendingPathComponent("claude"), codexSessionsDir: root,
                                   cacheURL: root.appendingPathComponent("cache.json"))
        await tracker.refresh()
        #expect(tracker.snapshot.creditsInUse(at: now)?.balance == 120)
        #expect(tracker.snapshot.creditsInUse(at: now.addingTimeInterval(31)) == nil)
    }

    @Test func unrelatedLogWritesDoNotRefreshAnOldCreditObservation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("2026/11/02")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("rollout-old-credits.jsonl")
        let observed = Date().addingTimeInterval(-1800)
        let row: [String: Any] = ["type": "event_msg", "timestamp": ISO8601DateFormatter().string(from: observed),
            "payload": ["type": "token_count", "rate_limits": [
                "primary": ["used_percent": 100, "window_minutes": 10080, "resets_at": Date().addingTimeInterval(3600).timeIntervalSince1970],
                "credits": ["has_credits": true, "balance": "120"]]]]
        try JSONSerialization.data(withJSONObject: row).write(to: file)
        let tracker = UsageTracker(projectsDir: root.appendingPathComponent("claude"), codexSessionsDir: root,
                                   cacheURL: root.appendingPathComponent("cache.json"))
        await tracker.refresh()
        #expect(tracker.snapshot.creditsInUse() == nil)
        #expect(try #require(tracker.snapshot.codexCreditsUpdatedAt).timeIntervalSince(observed) < 1)
    }

    @Test func latestScanPublishesCreditsAndClearsThemWhenLatestReadingOmitsBalance() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("2026/11/02")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("rollout-credit-test.jsonl")
        func write(credits: [String: Any]?) throws {
            var limits: [String: Any] = ["primary": ["used_percent": 100, "window_minutes": 10080, "resets_at": Date().addingTimeInterval(3600).timeIntervalSince1970]]
            limits["credits"] = credits
            let row: [String: Any] = ["type": "event_msg", "timestamp": ISO8601DateFormatter().string(from: Date()),
                "payload": ["type": "token_count", "rate_limits": limits]]
            try JSONSerialization.data(withJSONObject: row).write(to: file)
        }
        try write(credits: ["has_credits": true, "balance": "12345.6789012345"])
        let tracker = UsageTracker(projectsDir: root.appendingPathComponent("claude"), codexSessionsDir: root, cacheURL: root.appendingPathComponent("cache.json"))
        await tracker.refresh()
        #expect(tracker.snapshot.creditsInUse() != nil)
        #expect(!tracker.snapshot.codexLimitReached)
        let older = directory.appendingPathComponent("rollout-older-credit.jsonl")
        try FileManager.default.copyItem(at: file, to: older)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-60)], ofItemAtPath: older.path)
        try write(credits: nil)
        await tracker.refresh()
        #expect(tracker.snapshot.creditsInUse() == nil)
        #expect(tracker.snapshot.codexCredits == nil)
        #expect(tracker.snapshot.codexLimitReached)
    }
}
