import Foundation
import Testing

@testable import AppLib

@MainActor
struct UsageLedgerServiceTests {
    @Test func refreshAndRangeChangesOnlyReadArchives() async throws {
        let root = try UsageLedgerStorageTests().folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = UsageArchiveDatabase(url: root.appendingPathComponent("archive.sqlite"))
        let calendar = UsageLedgerTests.utc
        let day = calendar.startOfDay(for: UsageLedgerTests.start)
        var record = UsageLedgerStorageTests().record()
        record.date = day.addingTimeInterval(100)
        try await db.apply(records: [record])
        try await db.archive(day: day, calendar: calendar)
        let engine = UsageArchiveEngine(
            database: db, claudeRoot: root, codexRoot: root, legacyURL: root.appendingPathComponent("missing"),
            throttle: false)
        let service = UsageLedgerService(
            database: db, engine: engine, now: { day.addingTimeInterval(86400) }, calendar: { calendar })
        let reads = await db.observationReads
        await service.refresh()
        await service.setDays(7)
        await service.setDays(90)
        #expect(service.summary.totalTokens == 100)
        #expect(service.summary.days.count == 180)
        #expect(await db.observationReads == reads)
        #expect(try await engine.pendingMode() == nil)
        #expect(!service.isLoading)
    }
    @Test func pausePersistsAcrossRestart() async throws {
        let root = try UsageLedgerStorageTests().folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = UsageArchiveDatabase(url: root.appendingPathComponent("archive.sqlite"))
        let engine = UsageArchiveEngine(
            database: db, claudeRoot: root, codexRoot: root, legacyURL: root.appendingPathComponent("missing"),
            throttle: false)
        let service = UsageLedgerService(database: db, engine: engine)
        await service.pause()
        let restarted = UsageLedgerService(database: db, engine: engine)
        await restarted.tick(startup: true)
        #expect(restarted.isPaused)
        #expect(!restarted.isLoading)
    }
}

extension UsageLedgerServiceTests {
    @Test func overlappingRangeRefreshesPublishLatestSelection() async throws {
        let root = try UsageLedgerStorageTests().folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = UsageArchiveDatabase(url: root.appendingPathComponent("archive.sqlite"))
        let engine = UsageArchiveEngine(
            database: db, claudeRoot: root, codexRoot: root, legacyURL: root.appendingPathComponent("missing"),
            throttle: false)
        let service = UsageLedgerService(database: db, engine: engine)
        for _ in 0..<20 {
            let old = Task { await service.setDays(90) }
            await Task.yield()
            await service.setDays(7)
            await old.value
            #expect(service.days == 7)
            #expect(service.summary.days.count == 14)
        }
    }
}

extension UsageLedgerServiceTests {
    @Test func missingOptionalLegacyImportDoesNotBlockNormalSettlement() async throws {
        let root = try UsageLedgerStorageTests().folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = UsageArchiveDatabase(url: root.appendingPathComponent("archive.sqlite"))
        let engine = UsageArchiveEngine(
            database: db, claudeRoot: root.appendingPathComponent("claude"),
            codexRoot: root.appendingPathComponent("codex"), legacyURL: root.appendingPathComponent("missing"),
            throttle: false)
        let service = UsageLedgerService(database: db, engine: engine)
        service.importLegacy()
        await service.waitForJob()
        #expect(service.errorMessage != nil)
        #expect(!service.isPaused)
        #expect(try await engine.pendingMode() == nil)
        service.updateNow()
        await service.waitForJob()
        #expect(service.errorMessage == nil && service.settledThrough != nil)
    }
}
