import Foundation
import Testing
import Shared
@testable import AppLib

@MainActor
struct CodexResetTrackerTests {
    @Test func onlyActiveLocalCodexQualifies() {
        var remote = SessionInfo(id: "remote", cwd: nil, agent: .codex, state: .working)
        remote.source = .remote
        let claude = SessionInfo(id: "claude", cwd: nil, agent: .claude, state: .working)
        let idle = SessionInfo(id: "idle", cwd: nil, agent: .codex, state: .idle)
        let active = SessionInfo(id: "active", cwd: nil, agent: .codex, state: .waiting)
        #expect(!CodexResetActivity.hasActiveLocalCodex([remote, claude, idle]))
        #expect(CodexResetActivity.hasActiveLocalCodex([remote, active]))
    }

    @Test func inactiveOrDisabledNeverFetches() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = ConfigStore(directory: directory.path)
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        var calls = 0
        let tracker = CodexResetTracker(config: config, defaults: defaults,
            fetch: { calls += 1; return Data() })

        await tracker.refresh(activeCodex: false)
        #expect(calls == 0)
        config.saveCodexResetAnnouncements(false)
        await tracker.refresh(activeCodex: true)
        #expect(calls == 0)
        #expect(tracker.announcement == nil)
    }

    @Test func refreshThrottlesAndDeduplicatesNotificationAcrossInstances() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = ConfigStore(directory: directory.path)
        config.saveCodexResetNotifications(true)
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let now = try #require(ISO8601DateFormatter().date(from: "2026-10-23T06:00:00Z"))
        var calls = 0
        var notifications = 0
        let data = Data("""
        {"schema_version":1,"generated_at":"2026-10-23T05:55:00Z","scheduled":{"certainty":"announced","day":"2026-10-24","scheduled_for":"2026-10-23T17:00:00Z","url":"https://x.com/thsottiaux/status/123","announced_at":"2026-10-23T05:00:00Z"},"events":[]}
        """.utf8)
        let fetch: @MainActor () async throws -> Data = { calls += 1; return data }
        let tracker = CodexResetTracker(config: config, defaults: defaults, now: { now }, fetch: fetch)
        tracker.onNotify = { _ in notifications += 1 }
        await tracker.refresh(activeCodex: true)
        await tracker.refresh(activeCodex: true)
        #expect(calls == 1)
        #expect(notifications == 1)
        #expect(tracker.announcement?.phase == .scheduled)

        let restarted = CodexResetTracker(config: config, defaults: defaults, now: { now }, fetch: fetch)
        restarted.onNotify = { _ in notifications += 1 }
        await restarted.refresh(activeCodex: true)
        #expect(calls == 2)
        #expect(notifications == 1)

        config.saveCodexResetAnnouncements(false)
        await tracker.refresh(activeCodex: true)
        #expect(tracker.announcement == nil)
        #expect(calls == 2)
        config.saveCodexResetAnnouncements(true)
        await tracker.refresh(activeCodex: true)
        #expect(calls == 2)
        #expect(notifications == 1)
    }

    @Test func firstPollNotifiesARecentAnnouncement() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = ConfigStore(directory: directory.path)
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let now = try #require(ISO8601DateFormatter().date(from: "2026-10-23T06:00:00Z"))
        let data = Data("""
        {"schema_version":1,"generated_at":"2026-10-23T05:55:00Z","scheduled":null,"events":[{"kind":"regular","scope":"all","url":"https://x.com/thsottiaux/status/456","announced_at":"2026-10-23T04:00:00Z","delivered_at":null,"seeded":false}]}
        """.utf8)
        defaults.set(["https://x.com/thsottiaux/status/456:announced"],
            forKey: "codexResetNotifiedAnnouncementsV1")
        var notifications = 0
        let tracker = CodexResetTracker(config: config, defaults: defaults, now: { now }, fetch: { data })
        tracker.onNotify = { _ in notifications += 1 }
        await tracker.refresh(activeCodex: true)
        #expect(tracker.announcement?.phase == .announced)
        #expect(notifications == 1)
        await tracker.refresh(activeCodex: true)
        #expect(notifications == 1)
    }

    @Test func firstPollDoesNotNotifyAnOldAnnouncement() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = ConfigStore(directory: directory.path)
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let now = try #require(ISO8601DateFormatter().date(from: "2026-10-23T12:00:00Z"))
        let data = Data("""
        {"schema_version":1,"generated_at":"2026-10-23T11:55:00Z","scheduled":null,"events":[{"kind":"regular","scope":"all","url":"https://x.com/thsottiaux/status/456","announced_at":"2026-10-23T04:00:00Z","delivered_at":null,"seeded":false}]}
        """.utf8)
        var notifications = 0
        let tracker = CodexResetTracker(config: config, defaults: defaults, now: { now }, fetch: { data })
        tracker.onNotify = { _ in notifications += 1 }
        await tracker.refresh(activeCodex: true)
        #expect(tracker.announcement?.phase == .announced)
        #expect(notifications == 0)
    }

    @Test func activityToggleDoesNotBypassFiveMinuteRequestLimit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = ConfigStore(directory: directory.path)
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        var calls = 0
        let tracker = CodexResetTracker(config: config, defaults: defaults, fetch: {
            calls += 1
            return Data()
        })
        await tracker.refresh(activeCodex: true)
        await tracker.refresh(activeCodex: false)
        await tracker.refresh(activeCodex: true)
        #expect(calls == 1)
    }

    @Test func recentNoticeReturnsImmediatelyWhenCodexBecomesActiveAgain() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = ConfigStore(directory: directory.path)
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let now = try #require(ISO8601DateFormatter().date(from: "2026-10-31T14:47:00Z"))
        let data = Data("""
        {"schema_version":1,"generated_at":"2026-10-31T12:16:43Z","scheduled":null,"events":[{"kind":"regular","scope":"all","url":"https://x.com/thsottiaux/status/2116405414921384099","announced_at":"2026-10-31T05:42:26Z","delivered_at":null,"seeded":false}]}
        """.utf8)
        var calls = 0
        let tracker = CodexResetTracker(config: config, defaults: defaults, now: { now }, fetch: {
            calls += 1
            return data
        })
        await tracker.refresh(activeCodex: true)
        #expect(tracker.announcement != nil)
        await tracker.refresh(activeCodex: false)
        #expect(tracker.announcement == nil)
        await tracker.refresh(activeCodex: true)
        #expect(calls == 1)
        #expect(tracker.announcement?.sourceURL.absoluteString == "https://x.com/thsottiaux/status/2116405414921384099")
    }

    @Test(arguments: [false, true])
    func noticeIsRetainedWhenActivityChangesDuringFetch(activeBeforeResponse: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let now = try #require(ISO8601DateFormatter().date(from: "2026-10-31T14:47:00Z"))
        let data = Data("""
        {"schema_version":1,"generated_at":"2026-10-31T12:16:43Z","scheduled":null,"events":[{"kind":"regular","url":"https://x.com/example/status/123","announced_at":"2026-10-31T05:42:26Z"}]}
        """.utf8)
        var pending: CheckedContinuation<Data, Error>?
        var calls = 0
        let tracker = CodexResetTracker(config: ConfigStore(directory: directory.path), defaults: defaults,
            now: { now }, fetch: {
                calls += 1
                return try await withCheckedThrowingContinuation { pending = $0 }
            })
        let request = Task { await tracker.refresh(activeCodex: true) }
        for _ in 0..<100 {
            if pending != nil { break }
            await Task.yield()
        }
        let response = try #require(pending)
        await tracker.refresh(activeCodex: false)
        if activeBeforeResponse { await tracker.refresh(activeCodex: true) }
        response.resume(returning: data)
        await request.value
        #expect((tracker.announcement != nil) == activeBeforeResponse)
        await tracker.refresh(activeCodex: true)
        #expect(calls == 1)
        #expect(tracker.announcement?.sourceURL.absoluteString == "https://x.com/example/status/123")
    }

    @Test(arguments: ["disabled", "stopped"])
    func pendingResponseDoesNotPublishOrNotifyAfterDeactivation(reason: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = ConfigStore(directory: directory.path)
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let now = try #require(ISO8601DateFormatter().date(from: "2026-10-31T14:47:00Z"))
        let data = Data("""
        {"schema_version":1,"generated_at":"2026-10-31T14:46:00Z","scheduled":null,"events":[{"kind":"regular","url":"https://x.com/example/status/123","announced_at":"2026-10-31T14:46:00Z"}]}
        """.utf8)
        var pending: CheckedContinuation<Data, Error>?
        var notifications = 0
        let tracker = CodexResetTracker(config: config, defaults: defaults, now: { now }, fetch: {
            try await withCheckedThrowingContinuation { pending = $0 }
        })
        tracker.onNotify = { _ in notifications += 1 }
        let request = Task { await tracker.refresh(activeCodex: true) }
        for _ in 0..<100 {
            if pending != nil { break }
            await Task.yield()
        }
        let response = try #require(pending)
        if reason == "disabled" {
            config.saveCodexResetAnnouncements(false)
            await tracker.refresh(activeCodex: true)
        } else {
            tracker.stop()
        }
        response.resume(returning: data)
        await request.value
        #expect(tracker.announcement == nil)
        #expect(notifications == 0)
    }

    @Test func staleCachedFeedIsNotRestoredAfterActivityReturns() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        var clock = try #require(ISO8601DateFormatter().date(from: "2026-10-31T14:47:00Z"))
        let data = Data("""
        {"schema_version":1,"generated_at":"2026-10-31T12:16:43Z","scheduled":null,"events":[{"kind":"regular","url":"https://x.com/example/status/123","announced_at":"2026-10-31T05:42:26Z"}]}
        """.utf8)
        var calls = 0
        let tracker = CodexResetTracker(config: ConfigStore(directory: directory.path), defaults: defaults,
            now: { clock }, fetch: {
                calls += 1
                if calls > 1 { throw URLError(.notConnectedToInternet) }
                return data
            })
        await tracker.refresh(activeCodex: true)
        #expect(tracker.announcement != nil)
        await tracker.refresh(activeCodex: false)
        clock.addTimeInterval(4 * 3600)
        await tracker.refresh(activeCodex: true)
        #expect(calls == 2)
        #expect(tracker.announcement == nil)
    }

    @Test func configRoundTripPreservesExistingSettingsAndCorruptFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = ConfigStore(directory: directory.path)
        #expect(config.loadCodexResetAnnouncements())
        #expect(config.loadCodexResetNotifications())
        config.saveTheme(.f1)
        config.saveCodexResetAnnouncements(false)
        config.saveCodexResetNotifications(true)
        #expect(!config.loadCodexResetAnnouncements())
        #expect(config.loadCodexResetNotifications())
        #expect(config.loadTheme() == .f1)

        let path = directory.appendingPathComponent("config.json")
        try Data("bad json".utf8).write(to: path)
        config.saveCodexResetAnnouncements(true)
        #expect(try Data(contentsOf: path) == Data("bad json".utf8))
    }
}
