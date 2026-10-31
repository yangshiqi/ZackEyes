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

extension UsageArchiveDatabaseTests {
    @Test func cachedReadDisplayChangesTotalsDaysAndRankOrderAfterReopen() async throws {
        let root = try UsageLedgerStorageTests().folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("archive.sqlite")
        let db = UsageArchiveDatabase(url: url)
        let calendar = UsageLedgerTests.utc
        let day = calendar.startOfDay(for: UsageLedgerTests.start)
        var records: [UsageLedgerRecord] = []
        for i in 0..<12 {
            var record = UsageLedgerStorageTests().record(100 + i, at: day.addingTimeInterval(100))
            record.id = "cached-\(i)"
            record.project = "project-\(i)"
            record.model = "model-\(i)"
            record.cacheRead = i == 0 ? 10000 : 0
            records.append(record)
        }
        try await db.apply(records: records)
        try await db.archive(day: day, calendar: calendar)
        let restored = UsageArchiveDatabase(url: url)
        let now = day.addingTimeInterval(86400)
        let excluded = try await restored.summary(days: 7, now: now, calendar: calendar)
        let included = try await restored.summary(
            days: 7, now: now, calendar: calendar, includeCacheReads: true)
        #expect(included.totalTokens == excluded.totalTokens + 10000)
        #expect(included.days.reduce(0) { $0 + $1.tokens } == included.totalTokens)
        #expect(included.projects.first?.name == "project-0")
        #expect(included.projects.first?.value == 10100)
        #expect(included.models.first?.name == "model-0")
        #expect(excluded.projects.first?.name == "project-11")
        #expect(included.cacheHitRate == excluded.cacheHitRate)
        #expect(included.activeSeconds == excluded.activeSeconds)
        #expect(await restored.observationReads == 0)
    }
}

extension UsageArchiveDatabaseTests {
    @Test func cachedReadsAcrossDaysAndCodexCountersAreNotDoubleCounted() async throws {
        let root = try UsageLedgerStorageTests().folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = UsageArchiveDatabase(url: root.appendingPathComponent("archive.sqlite"))
        let calendar = UsageLedgerTests.utc
        let day = calendar.startOfDay(for: UsageLedgerTests.start)
        var first = UsageLedgerStorageTests().record(100, at: day.addingTimeInterval(100))
        first.id = "first"
        first.agent = .codex
        first.kind = .counter
        first.cacheRead = 80
        first.output = 10
        var second = first
        second.id = "second"
        second.date = first.date.addingTimeInterval(86400)
        second.input = 300
        second.cacheRead = 250
        second.output = 30
        var cachedOnly = UsageLedgerStorageTests().record(0, at: first.date)
        cachedOnly.id = "cache-only"
        cachedOnly.project = "Cache only"
        cachedOnly.cacheRead = 1000
        try await db.apply(records: [first, second, cachedOnly])
        try await db.archive(day: day, calendar: calendar)
        try await db.archive(day: day.addingTimeInterval(86400), calendar: calendar)
        let now = day.addingTimeInterval(2 * 86400)
        let included = try await db.summary(
            days: 7, now: now, calendar: calendar, includeCacheReads: true)
        let excluded = try await db.summary(days: 7, now: now, calendar: calendar)
        #expect(included.totalTokens == 1330)
        #expect(excluded.totalTokens == 80)
        #expect(included.days.filter { $0.agent == .codex }.reduce(0) { $0 + $1.tokens } == 330)
        #expect(included.projects.first?.name == "Cache only")
        #expect(!excluded.projects.contains { $0.name == "Cache only" })
        #expect(included.cacheHitRate == excluded.cacheHitRate)
    }

    @Test func legacyArchivesBackfillCacheBreakdownOnceFromSavedObservations() async throws {
        let root = try UsageLedgerStorageTests().folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("archive.sqlite")
        let db = UsageArchiveDatabase(url: url)
        let calendar = UsageLedgerTests.utc
        let day = calendar.startOfDay(for: UsageLedgerTests.start)
        var record = UsageLedgerStorageTests().record(100, at: day.addingTimeInterval(100))
        record.cacheRead = 900
        try await db.apply(records: [record])
        try await db.archive(day: day, calendar: calendar)
        // Simulate the previous app's JSON shape without per-rank/per-day cache metadata.
        var legacy = UsageLedgerSummary.make(
            records: [record], days: 1,
            now: day.addingTimeInterval(86399), calendar: calendar)
        legacy.cacheBreakdownVersion = nil
        for i in legacy.days.indices { legacy.days[i].cacheRead = nil }
        for i in legacy.projects.indices { legacy.projects[i].cacheRead = nil }
        for i in legacy.models.indices { legacy.models[i].cacheRead = nil }
        let bytes = try JSONEncoder().encode(legacy)
        var connectionPointer: OpaquePointer?
        #expect(sqlite3_open(url.path, &connectionPointer) == SQLITE_OK)
        let connection = try #require(connectionPointer)
        defer { sqlite3_close(connection) }
        var statementPointer: OpaquePointer?
        #expect(
            sqlite3_prepare_v2(connection, "UPDATE archives SET body=?", -1, &statementPointer, nil)
                == SQLITE_OK)
        let statement = try #require(statementPointer)
        defer { sqlite3_finalize(statement) }
        bytes.withUnsafeBytes { buffer in
            #expect(
                sqlite3_bind_blob(statement, 1, buffer.baseAddress, Int32(bytes.count), nil) == SQLITE_OK)
            #expect(sqlite3_step(statement) == SQLITE_DONE)
        }
        let restored = UsageArchiveDatabase(url: url)
        let now = day.addingTimeInterval(86400)
        let report = try await restored.summary(
            days: 7, now: now, calendar: calendar, includeCacheReads: true)
        #expect(report.totalTokens == 1000)
        #expect(report.projects.first?.value == 1000)
        #expect(report.days.reduce(0) { $0 + $1.tokens } == 1000)
        let reads = await restored.observationReads
        #expect(reads > 0)
        let reopened = UsageArchiveDatabase(url: url)
        #expect(
            try await reopened.summary(days: 7, now: now, calendar: calendar, includeCacheReads: true)
                .totalTokens == 1000)
        #expect(await reopened.observationReads == 0)
    }
}
