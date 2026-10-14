import Foundation
import SQLite3
import Testing

@testable import AppLib

struct UsageArchiveDatabaseTests {
    @Test func archivesSurviveReopenAndSummaryDoesNotReadObservations() async throws {
        let root = try UsageLedgerStorageTests().folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("archive.sqlite")
        let day = UsageLedgerTests.utc.startOfDay(for: UsageLedgerTests.start)
        var record = UsageLedgerStorageTests().record()
        record.date = day.addingTimeInterval(100)
        let db = UsageArchiveDatabase(url: url)
        try await db.apply(records: [record, record], source: "source", checkpoint: Data("cursor".utf8))
        try await db.archive(day: day, calendar: UsageLedgerTests.utc)
        let restored = UsageArchiveDatabase(url: url)
        let summary = try await restored.summary(
            days: 7, now: day.addingTimeInterval(86400), calendar: UsageLedgerTests.utc)
        #expect(summary.totalTokens == record.tokens)
        #expect(await restored.observationReads == 0)
        #expect(try await restored.checkpoint(source: "source") == Data("cursor".utf8))
    }
    @Test func invalidTransactionDoesNotAdvanceCursor() async throws {
        let root = try UsageLedgerStorageTests().folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = UsageArchiveDatabase(url: root.appendingPathComponent("archive.sqlite"))
        var invalid = UsageLedgerStorageTests().record()
        invalid.input = -1
        await #expect(throws: (any Error).self) {
            try await db.apply(
                records: [UsageLedgerStorageTests().record(), invalid], source: "s", checkpoint: Data([1]))
        }
        #expect(try await db.checkpoint(source: "s") == nil)
    }
    @Test func counterPredecessorAndRevisionsInvalidateSuccessorDay() async throws {
        let root = try UsageLedgerStorageTests().folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = UsageArchiveDatabase(url: root.appendingPathComponent("archive.sqlite"))
        let day = UsageLedgerTests.utc.startOfDay(for: UsageLedgerTests.start)
        var a = UsageLedgerStorageTests().record()
        a.id = "a"
        a.agent = .codex
        a.kind = .counter
        a.date = day.addingTimeInterval(-100)
        a.input = 100
        var b = a
        b.id = "b"
        b.date = day.addingTimeInterval(100)
        b.input = 150
        try await db.apply(records: [a, b])
        try await db.archive(day: day, calendar: UsageLedgerTests.utc)
        #expect(
            try await db.summary(days: 7, now: day.addingTimeInterval(86400), calendar: UsageLedgerTests.utc)
                .totalTokens == 50)
        a.input = 120
        try await db.apply(records: [a])
        #expect(try await db.dirtyDays(calendar: UsageLedgerTests.utc).contains(day))
        try await db.archive(day: day, calendar: UsageLedgerTests.utc)
        #expect(
            try await db.summary(days: 7, now: day.addingTimeInterval(86400), calendar: UsageLedgerTests.utc)
                .totalTokens == 30)
    }
}

extension UsageArchiveDatabaseTests {
    @Test func allTiedPredecessorsAreRetained() async throws {
        let root = try UsageLedgerStorageTests().folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = UsageArchiveDatabase(url: root.appendingPathComponent("archive.sqlite"))
        let day = UsageLedgerTests.utc.startOfDay(for: UsageLedgerTests.start)
        var high = UsageLedgerStorageTests().record()
        high.id = "high"
        high.agent = .codex
        high.kind = .counter
        high.input = 150
        high.date = day.addingTimeInterval(-100)
        var low = high
        low.id = "low"
        low.input = 100
        var current = high
        current.id = "current"
        current.input = 200
        current.date = day.addingTimeInterval(100)
        try await db.apply(records: [high, low, current])
        try await db.archive(day: day, calendar: UsageLedgerTests.utc)
        #expect(
            try await db.summary(days: 7, now: day.addingTimeInterval(86400), calendar: UsageLedgerTests.utc)
                .totalTokens == 50)
    }
    @Test func dailyReportsPreserveDSTRanksAndWeightedCacheRates() async throws {
        let root = try UsageLedgerStorageTests().folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = UsageArchiveDatabase(url: root.appendingPathComponent("archive.sqlite"))
        var calendar = UsageLedgerTests.utc
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let day = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1))!
        let end = calendar.date(byAdding: .day, value: 2, to: day)!
        var records: [UsageLedgerRecord] = []
        for d in 0..<2 {
            let start = calendar.date(byAdding: .day, value: d, to: day)!
            for i in 0..<12 {
                var record = UsageLedgerStorageTests().record(100 + i, at: start.addingTimeInterval(100))
                record.id = "\(d):\(i)"
                record.project = i == 0 ? "Shared" : "day\(d)-\(i)"
                record.cacheRead = d == 0 ? 1000 : 1
                records.append(record)
            }
        }
        var work = records[0]
        work.id = "work"
        work.input = 0
        work.cacheRead = 0
        work.kind = .work
        work.date = day
        work.end = end
        records.append(work)
        try await db.apply(records: records)
        try await db.archive(day: day, calendar: calendar)
        try await db.archive(day: calendar.date(byAdding: .day, value: 1, to: day)!, calendar: calendar)
        let report = try await db.summary(days: 7, now: end, calendar: calendar)
        let expected = UsageLedgerSummary.make(
            records: records, days: 7, now: end.addingTimeInterval(-0.000001), calendar: calendar)
        #expect(report.totalTokens == expected.totalTokens)
        #expect(abs(report.activeSeconds - 49 * 3600) < 0.001)
        #expect(report.projects.first?.name == "Shared")
        #expect(report.cacheHitRate == expected.cacheHitRate)
        #expect(report.heatmap.first { $0.day == day && $0.hour == 1 }?.seconds == 7200)
        let anotherZone = try await db.summary(days: 7, now: end, calendar: UsageLedgerTests.utc)
        #expect(anotherZone.totalTokens == 0)
    }
}

extension UsageArchiveDatabaseTests {
    @Test func unsafeFilesAndUnsupportedSchemaRemainUnchanged() async throws {
        let root = try UsageLedgerStorageTests().folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("archive.sqlite")
        let db = UsageArchiveDatabase(url: url)
        _ = try await db.metadata("initialize")
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        let link = root.appendingPathComponent("linked.sqlite")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        await #expect(throws: UsageArchiveDatabase.Failure.unsafeFile) {
            _ = try await UsageArchiveDatabase(url: link).metadata("test")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        await #expect(throws: UsageArchiveDatabase.Failure.unsafeFile) {
            _ = try await UsageArchiveDatabase(url: url).metadata("test")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        // A standalone foreign database must be rejected before any journal/DDL writes.
        let foreign = root.appendingPathComponent("foreign.sqlite")
        try createFutureDatabase(foreign)
        let original = try Data(contentsOf: foreign)
        await #expect(throws: UsageArchiveDatabase.Failure.unsupportedSchema) {
            _ = try await UsageArchiveDatabase(url: foreign).metadata("test")
        }
        #expect(try Data(contentsOf: foreign) == original)
    }
}

private func createFutureDatabase(_ url: URL) throws {
    var db: OpaquePointer?
    guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else { throw CocoaError(.fileWriteUnknown) }
    defer { sqlite3_close(db) }
    #expect(sqlite3_exec(db, "PRAGMA user_version=999", nil, nil, nil) == SQLITE_OK)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}

extension UsageArchiveDatabaseTests {
    @Test func midnightBoundaryIncludesFinalFractionAndExcludesNextDay() async throws {
        let root = try UsageLedgerStorageTests().folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = UsageArchiveDatabase(url: root.appendingPathComponent("archive.sqlite"))
        let day = UsageLedgerTests.utc.startOfDay(for: UsageLedgerTests.start)
        let end = UsageLedgerTests.utc.date(byAdding: .day, value: 1, to: day)!
        var before = UsageLedgerStorageTests().record(10, at: end.addingTimeInterval(-0.0000005))
        before.id = "before"
        var next = before
        next.id = "next"
        next.date = end
        next.input = 100
        try await db.apply(records: [before, next])
        try await db.archive(day: day, calendar: UsageLedgerTests.utc)
        #expect(try await db.summary(days: 7, now: end, calendar: UsageLedgerTests.utc).totalTokens == 10)
    }
}
