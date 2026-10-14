import Foundation
import Testing

@testable import AppLib

struct UsageArchiveEngineTests {
    @Test func dailyScheduleAndRestartOnlySettleOnce() async throws {
        let root = try UsageLedgerStorageTests().folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = UsageArchiveDatabase(url: root.appendingPathComponent("archive.sqlite"))
        let engine = UsageArchiveEngine(
            database: db, claudeRoot: root.appendingPathComponent("claude"),
            codexRoot: root.appendingPathComponent("codex"), legacyURL: root.appendingPathComponent("history.jsonl"),
            throttle: false)
        let today = UsageLedgerTests.utc.startOfDay(for: UsageLedgerTests.start)
        _ = try await engine.run(
            mode: .automatic, now: today.addingTimeInterval(3600), calendar: UsageLedgerTests.utc, startup: true)
        #expect(
            try await !engine.isDue(now: today.addingTimeInterval(7200), calendar: UsageLedgerTests.utc, startup: true))
        #expect(try await !engine.isDue(now: today.addingTimeInterval(86400 + 7200), calendar: UsageLedgerTests.utc))
        #expect(try await engine.isDue(now: today.addingTimeInterval(86400 + 10800), calendar: UsageLedgerTests.utc))
        #expect(
            try await engine.isDue(
                now: today.addingTimeInterval(86400 * 3), calendar: UsageLedgerTests.utc, startup: true))
    }
}

extension UsageArchiveEngineTests {
    @Test func legacyImportCannotMarkUnscannedYesterdayCompleteAndZoneChangesAreDue() async throws {
        let root = try UsageLedgerStorageTests().folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("history.jsonl")
        var bytes = try JSONEncoder().encode(UsageLedgerStorageTests().record())
        bytes.append(10)
        try bytes.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let db = UsageArchiveDatabase(url: root.appendingPathComponent("archive.sqlite"))
        let engine = UsageArchiveEngine(
            database: db, claudeRoot: root.appendingPathComponent("claude"),
            codexRoot: root.appendingPathComponent("codex"), legacyURL: file, throttle: false)
        let now = UsageLedgerTests.start.addingTimeInterval(86400)
        _ = try await engine.run(mode: .legacy, now: now, calendar: UsageLedgerTests.utc)
        #expect(try await engine.lastSettlement(calendar: UsageLedgerTests.utc) == nil)
        #expect(try await engine.isDue(now: now, calendar: UsageLedgerTests.utc, startup: true))
        _ = try await engine.run(mode: .automatic, now: now, calendar: UsageLedgerTests.utc, startup: true)
        var changed = UsageLedgerTests.utc
        changed.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        #expect(try await engine.isDue(now: now, calendar: changed, startup: true))
    }
}
