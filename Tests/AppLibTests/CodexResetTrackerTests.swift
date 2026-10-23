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
        #expect(calls == 3)
        #expect(notifications == 1)
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
