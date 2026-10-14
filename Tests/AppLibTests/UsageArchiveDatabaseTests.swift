import Foundation
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
        let summary = try await restored.summary(days: 7, now: day.addingTimeInterval(86400), calendar: UsageLedgerTests.utc)
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
            try await db.apply(records: [UsageLedgerStorageTests().record(), invalid], source: "s", checkpoint: Data([1]))
        }
        #expect(try await db.checkpoint(source: "s") == nil)
    }
    @Test func counterPredecessorAndRevisionsInvalidateSuccessorDay() async throws {
        let root = try UsageLedgerStorageTests().folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = UsageArchiveDatabase(url: root.appendingPathComponent("archive.sqlite"))
        let day = UsageLedgerTests.utc.startOfDay(for: UsageLedgerTests.start)
        var a = UsageLedgerStorageTests().record()
        a.id = "a"; a.agent = .codex; a.kind = .counter; a.date = day.addingTimeInterval(-100); a.input = 100
        var b = a; b.id = "b"; b.date = day.addingTimeInterval(100); b.input = 150
        try await db.apply(records: [a, b])
        try await db.archive(day: day, calendar: UsageLedgerTests.utc)
        #expect(try await db.summary(days: 7, now: day.addingTimeInterval(86400), calendar: UsageLedgerTests.utc).totalTokens == 50)
        a.input = 120
        try await db.apply(records: [a])
        #expect(try await db.dirtyDays(calendar: UsageLedgerTests.utc).contains(day))
        try await db.archive(day: day, calendar: UsageLedgerTests.utc)
        #expect(try await db.summary(days: 7, now: day.addingTimeInterval(86400), calendar: UsageLedgerTests.utc).totalTokens == 30)
    }
}
