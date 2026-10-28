import Foundation
import Testing
@testable import AppLib

@MainActor
struct CodexQuotaRecoveryTests {
    private let now = Date(timeIntervalSince1970: 1_792_736_000)

    private func reading(_ used: Double?, at: Date, source: String = "local-rollout",
                         reset: Date? = nil, sevenDay: Bool = false) -> CodexQuotaReading {
        var quota = UsageTracker.CodexRateLimitObservation()
        if sevenDay {
            quota.sevenDayUsedPct = used
            quota.sevenDayResetsAt = reset ?? now.addingTimeInterval(86400)
        } else {
            quota.fiveHourUsedPct = used
            quota.fiveHourResetsAt = reset ?? now.addingTimeInterval(3600)
        }
        return CodexQuotaReading(sourceID: source, observedAt: at, quota: quota)
    }

    @Test func detectsEarlyRecoveryOnEitherAccountWindow() {
        for sevenDay in [false, true] {
            let before = reading(75, at: now.addingTimeInterval(-60), sevenDay: sevenDay)
            let after = reading(2, at: now, sevenDay: sevenDay)
            #expect(CodexQuotaRecovery.occurred(from: before, to: after))
        }
    }

    @Test func ignoresOrdinaryExpiryMissingDataNoiseAndUnrelatedSources() {
        let before = reading(75, at: now.addingTimeInterval(-60))
        #expect(!CodexQuotaRecovery.occurred(from: before, to: reading(nil, at: now)))
        #expect(!CodexQuotaRecovery.occurred(from: before, to: reading(74, at: now)))
        #expect(!CodexQuotaRecovery.occurred(from: before, to: reading(20, at: now)))
        #expect(!CodexQuotaRecovery.occurred(from: reading(8, at: now.addingTimeInterval(-60)), to: reading(0, at: now)))
        #expect(!CodexQuotaRecovery.occurred(from: before, to: reading(2, at: now, source: "other-account-rollout")))
        #expect(!CodexQuotaRecovery.occurred(from: before, to: reading(2, at: before.observedAt)))
        let expired = reading(75, at: now.addingTimeInterval(-120), reset: now.addingTimeInterval(-10))
        #expect(!CodexQuotaRecovery.occurred(from: expired, to: reading(2, at: now)))
        let stale = reading(75, at: now.addingTimeInterval(-1800))
        #expect(!CodexQuotaRecovery.occurred(from: stale, to: reading(2, at: now)))
    }

    @Test func localRecoveryHidesNoticeAcrossPollsAndRestartButNotNewAnnouncements() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = ConfigStore(directory: directory.path)
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var clock = now
        var posted = now.addingTimeInterval(-120)
        let iso = ISO8601DateFormatter()
        let fetch: @MainActor () async throws -> Data = {
            Data("""
            {"schema_version":1,"generated_at":"\(iso.string(from: clock))","scheduled":null,"events":[{"kind":"regular","scope":"all","url":"https://x.com/example/status/123","announced_at":"\(iso.string(from: posted))","delivered_at":null}]}
            """.utf8)
        }
        let tracker = CodexResetTracker(config: config, defaults: defaults, now: { clock }, fetch: fetch)
        await tracker.refresh(activeCodex: true)
        #expect(tracker.announcement != nil)
        tracker.recordQuotaReadings([reading(75, at: now.addingTimeInterval(-60))])
        tracker.recordQuotaReadings([reading(2, at: now)])
        #expect(tracker.announcement == nil)
        clock = now.addingTimeInterval(301)
        await tracker.refresh(activeCodex: true)
        #expect(tracker.announcement == nil)
        let restarted = CodexResetTracker(config: config, defaults: defaults, now: { clock }, fetch: fetch)
        var notifications = 0
        restarted.onNotify = { _ in notifications += 1 }
        await restarted.refresh(activeCodex: true)
        #expect(restarted.announcement == nil)
        #expect(notifications == 0)
        clock = now.addingTimeInterval(602)
        posted = now.addingTimeInterval(400)
        await restarted.refresh(activeCodex: true)
        #expect(restarted.announcement != nil)
        #expect(notifications == 1)
    }

    @Test(arguments: ["stale", "future", "ordinary", "already-full", "banked"])
    func unrelatedObservationsKeepAnnouncement(scenario: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = ConfigStore(directory: directory.path)
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let iso = ISO8601DateFormatter()
        let kind = scenario == "banked" ? "banked" : "regular"
        let tracker = CodexResetTracker(config: config, defaults: defaults, now: { now }, fetch: {
            Data("""
            {"schema_version":1,"generated_at":"\(iso.string(from: now))","scheduled":null,"events":[{"kind":"\(kind)","url":"https://x.com/example/status/123","announced_at":"\(iso.string(from: now.addingTimeInterval(-3600)))"}]}
            """.utf8)
        })
        await tracker.refresh(activeCodex: true)
        let after = scenario == "stale" ? now.addingTimeInterval(-1800)
            : scenario == "future" ? now.addingTimeInterval(60) : now
        let reset = scenario == "ordinary" ? after.addingTimeInterval(-10) : now.addingTimeInterval(3600)
        tracker.recordQuotaReadings([reading(scenario == "already-full" ? 1 : 80,
                                             at: after.addingTimeInterval(-60), reset: reset)])
        tracker.recordQuotaReadings([reading(1, at: after)])
        #expect(tracker.announcement != nil)
    }

    @Test func recoveryCanRetireAFutureScheduledNoticeEarly() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = ConfigStore(directory: directory.path)
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let iso = ISO8601DateFormatter()
        let day = String(iso.string(from: now).prefix(10))
        let tracker = CodexResetTracker(config: config, defaults: defaults, now: { now }, fetch: {
            Data("""
            {"schema_version":1,"generated_at":"\(iso.string(from: now))","scheduled":{"certainty":"announced","day":"\(day)","scheduled_for":"\(iso.string(from: now.addingTimeInterval(1800)))","url":"https://x.com/example/status/123","announced_at":"\(iso.string(from: now.addingTimeInterval(-120)))"},"events":[]}
            """.utf8)
        })
        await tracker.refresh(activeCodex: true)
        #expect(tracker.announcement?.phase == .scheduled)
        tracker.recordQuotaReadings([reading(80, at: now.addingTimeInterval(-60)), reading(0, at: now)])
        #expect(tracker.announcement == nil)
    }

    @Test func recoveryBeforeFeedResponseAndProviderCompletionDoesNotResurrectNotice() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = ConfigStore(directory: directory.path)
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let iso = ISO8601DateFormatter()
        let tracker = CodexResetTracker(config: config, defaults: defaults, now: { now }, fetch: {
            Data("""
            {"schema_version":1,"generated_at":"\(iso.string(from: now))","scheduled":null,"events":[{"kind":"regular","url":"https://x.com/example/status/123","announced_at":"\(iso.string(from: now.addingTimeInterval(-120)))","delivered_at":"\(iso.string(from: now.addingTimeInterval(-10)))"}]}
            """.utf8)
        })
        tracker.recordQuotaReadings([reading(75, at: now.addingTimeInterval(-60)), reading(2, at: now)])
        await tracker.refresh(activeCodex: true)
        #expect(tracker.announcement == nil)
    }
}
