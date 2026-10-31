import Foundation
import Testing
@testable import AppLib

@MainActor
struct CodexUsageHistoryTests {
    let fixture = CodexPaginatedUsageTests()

    @Test(arguments: [false, true])
    func missingOrLinkedParentNeverMintsInheritedTokens(linked: Bool) async throws {
        let root = try UsageLedgerStorageTests().folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let day = root.appendingPathComponent("2026/10/27")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let parentID = UUID().uuidString.lowercased(), pageID = UUID().uuidString.lowercased()
        let parent = fixture.meta(id: parentID) + fixture.event(at: "2026-10-26T15:59:00Z", input: 500, cached: 400, output: 50)
        if linked {
            let outside = root.appendingPathComponent("outside.txt")
            try parent.write(to: outside, atomically: true, encoding: .utf8)
            try FileManager.default.createSymbolicLink(at: day.appendingPathComponent("rollout-\(parentID).jsonl"), withDestinationURL: outside)
        }
        let page = fixture.meta(id: parentID, base: parentID, offset: parent.utf8.count)
            + "{\"type\":\"turn_context\",\"payload\":{\"model\":\"gpt-6.1-sol\"}}\n"
            + fixture.event(at: "2026-10-27T01:00:00Z", input: 600, cached: 480, output: 55)
            + fixture.event(at: "2026-10-27T02:00:00Z", input: 700, cached: 560, output: 60)
        let file = day.appendingPathComponent("rollout-\(parentID)_\(pageID).jsonl")
        try page.write(to: file, atomically: true, encoding: .utf8)
        let scan = UsageTracker.scanCodexDailyTokens(rootDir: root, cache: [:], calendar: fixture.calendar,
                                                   now: fixture.date("2026-10-28T08:00:00Z"))
        let tally = try #require(scan.merged[fixture.date("2026-10-26T16:00:00Z")]?["gpt-6.1-sol"])
        #expect(tally.input == 100 && tally.cacheRead == 80 && tally.output == 5 && tally.isPartial)
        let db = UsageArchiveDatabase(url: root.appendingPathComponent("archive.sqlite"))
        let importer = UsageArchiveImporter(database: db, throttle: false, codexRoot: root)
        #expect(try await importer.importFile(file, agent: .codex, cutoff: nil).rejected > 0)
        let records = try await db.records(start: fixture.date("2026-10-26T16:00:00Z"), end: fixture.date("2026-10-27T16:00:00Z"))
        let report = UsageLedgerSummary.make(records: records, days: 1, now: fixture.date("2026-10-27T15:59:59Z"), calendar: fixture.calendar)
        #expect(report.totalTokens == 25 && report.cacheReused == 80)
    }

    @Test func archivePageBaselineIsNonBillableAndParentImportDoesNotDoubleCount() async throws {
        let root = try UsageLedgerStorageTests().folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let parentID = UUID().uuidString.lowercased(), pageID = UUID().uuidString.lowercased()
        let parent = fixture.meta(id: parentID) + fixture.event(at: "2026-10-26T15:59:00Z", input: 500, cached: 400, output: 50)
        let baseURL = root.appendingPathComponent("rollout-\(parentID).jsonl")
        try parent.write(to: baseURL, atomically: true, encoding: .utf8)
        let page = fixture.meta(id: parentID, base: parentID, offset: parent.utf8.count)
            + fixture.event(at: "2026-10-27T01:00:00Z", input: 600, cached: 480, output: 55)
        let pageURL = root.appendingPathComponent("rollout-\(parentID)_\(pageID).jsonl")
        try page.write(to: pageURL, atomically: true, encoding: .utf8)
        let db = UsageArchiveDatabase(url: root.appendingPathComponent("archive.sqlite"))
        let importer = UsageArchiveImporter(database: db, throttle: false, codexRoot: root)
        _ = try await importer.importFile(pageURL, agent: .codex, cutoff: nil)
        func summary(_ records: [UsageLedgerRecord]) -> UsageLedgerSummary {
            UsageLedgerSummary.make(records: records, days: 2, now: fixture.date("2026-10-27T15:59:59Z"), calendar: fixture.calendar)
        }
        let start = fixture.date("2026-10-25T16:00:00Z"), end = fixture.date("2026-10-27T16:00:00Z")
        #expect(summary(try await db.records(start: start, end: end)).totalTokens == 25)
        _ = try await importer.importFile(baseURL, agent: .codex, cutoff: nil)
        #expect(summary(try await db.records(start: start, end: end)).totalTokens == 175)
        #expect(try await importer.importFile(pageURL, agent: .codex, cutoff: nil).bytesRead == 0)
        #expect(summary(try await db.records(start: start, end: end)).totalTokens == 175)
    }

    @Test func emptyIntermediatePagesFollowPinnedAncestorsAndCyclesFailClosed() throws {
        let root = try UsageLedgerStorageTests().folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let baseID = UUID().uuidString.lowercased(), pageID = UUID().uuidString.lowercased()
        let base = fixture.meta(id: baseID) + fixture.event(at: "2026-10-26T15:59:00Z", input: 1_313_546_957, cached: 1_297_960_576, output: 3_229_492)
        try base.write(to: root.appendingPathComponent("rollout-\(baseID).jsonl"), atomically: true, encoding: .utf8)
        let intermediate = fixture.meta(id: baseID, base: baseID, offset: base.utf8.count)
        try intermediate.write(to: root.appendingPathComponent("rollout-\(baseID)_\(pageID).jsonl"), atomically: true, encoding: .utf8)
        var files = CodexUsageHistory.fileIndex(root: root)
        let resolved = try #require(CodexUsageHistory.resolve(.init(fileID: pageID, offset: UInt64(intermediate.utf8.count)), files: files))
        #expect(resolved.usage.input == 1_313_546_957)
        let cycleID = UUID().uuidString.lowercased()
        var cycle = fixture.meta(id: cycleID, base: cycleID, offset: 0)
        for _ in 0..<5 { cycle = fixture.meta(id: cycleID, base: cycleID, offset: cycle.utf8.count) }
        try cycle.write(to: root.appendingPathComponent("rollout-\(cycleID).jsonl"), atomically: true, encoding: .utf8)
        files = CodexUsageHistory.fileIndex(root: root)
        #expect(CodexUsageHistory.resolve(.init(fileID: cycleID, offset: UInt64(cycle.utf8.count)), files: files) == nil)
        #expect(CodexUsageHistory.resolve(.init(fileID: baseID, offset: UInt64(base.utf8.count + 1)), files: files) == nil)
    }
}

extension CodexUsageHistoryTests {
    @Test(arguments: [true, false])
    func rejectedWideJumpCannotMintAFalseReset(returnsToTrustedRange: Bool) {
        let text = fixture.meta(id: UUID().uuidString)
            + fixture.event(at: "2026-10-27T01:00:00Z", input: 100, cached: 0, output: 0)
            + fixture.event(at: "2026-10-27T02:00:00Z", input: 1_500_000_000, cached: 0, output: 0)
            + fixture.event(at: "2026-10-27T03:00:00Z", input: returnsToTrustedRange ? 150 : 1_500_000_050, cached: 0, output: 0)
        let parsed = UsageTracker.parseCodexDailyTallies(text: text, calendar: fixture.calendar,
            cutoff: fixture.date("2026-10-26T16:00:00Z"))
        let day = parsed[fixture.date("2026-10-26T16:00:00Z")]?["unknown"]
        #expect(day?.input == 150)
        #expect(day?.isPartial == true)
        var issues = 0
        let records = UsageLedgerParser.parse(text: text, agent: .codex, sourceID: "jump", onIssue: { issues += 1 })
        let report = UsageLedgerSummary.make(records: records, days: 1, now: fixture.date("2026-10-27T15:59:59Z"), calendar: fixture.calendar)
        #expect(report.totalTokens == 150)
        #expect(issues > 0)
    }

    @Test func parentArrivalRepairsUnchangedLiveAndArchivedPage() async throws {
        let root = try UsageLedgerStorageTests().folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let day = root.appendingPathComponent("2026/10/27")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let parentID = UUID().uuidString.lowercased(), pageID = UUID().uuidString.lowercased()
        let parent = fixture.meta(id: parentID) + fixture.event(at: "2026-10-26T15:59:00Z", input: 500, cached: 400, output: 50)
        let page = fixture.meta(id: parentID, base: parentID, offset: parent.utf8.count)
            + "{\"type\":\"turn_context\",\"payload\":{\"model\":\"gpt-6.1-sol\"}}\n"
            + fixture.event(at: "2026-10-27T01:00:00Z", input: 600, cached: 480, output: 55)
            + fixture.event(at: "2026-10-27T02:00:00Z", input: 700, cached: 560, output: 60)
        let file = day.appendingPathComponent("rollout-\(parentID)_\(pageID).jsonl")
        try page.write(to: file, atomically: true, encoding: .utf8)
        let now = fixture.date("2026-10-28T08:00:00Z")
        let first = UsageTracker.scanCodexDailyTokens(rootDir: root, cache: [:], calendar: fixture.calendar, now: now)
        let db = UsageArchiveDatabase(url: root.appendingPathComponent("archive.sqlite"))
        let importer = UsageArchiveImporter(database: db, throttle: false, codexRoot: root)
        _ = try await importer.importFile(file, agent: .codex, cutoff: nil)
        try parent.write(to: day.appendingPathComponent("rollout-\(parentID).jsonl"), atomically: true, encoding: .utf8)
        let second = UsageTracker.scanCodexDailyTokens(rootDir: root, cache: first.cache, calendar: fixture.calendar, now: now)
        let tally = second.merged[fixture.date("2026-10-26T16:00:00Z")]?["gpt-6.1-sol"]
        #expect(tally?.input == 200 && tally?.cacheRead == 160 && tally?.output == 10)
        #expect(tally?.isPartial == false)
        let restarted = UsageArchiveImporter(database: db, throttle: false, codexRoot: root)
        #expect(try await restarted.importFile(file, agent: .codex, cutoff: nil).bytesRead > 0)
        let records = try await db.records(start: fixture.date("2026-10-26T16:00:00Z"), end: fixture.date("2026-10-27T16:00:00Z"))
        let report = UsageLedgerSummary.make(records: records, days: 1, now: fixture.date("2026-10-27T15:59:59Z"), calendar: fixture.calendar)
        #expect(report.totalTokens == 50 && report.cacheReused == 160)
        #expect(try await restarted.importFile(file, agent: .codex, cutoff: nil).bytesRead == 0)
    }
}

extension CodexUsageHistoryTests {
    @Test func automaticRetryFindsTrackedOldPagesButDoesNotImportUnseenHistory() async throws {
        let root = try UsageLedgerStorageTests().folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let codex = root.appendingPathComponent("codex")
        let day = codex.appendingPathComponent("2026/10/20")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let parentID = UUID().uuidString.lowercased(), pageID = UUID().uuidString.lowercased()
        let parent = fixture.meta(id: parentID) + fixture.event(at: "2026-10-19T01:00:00Z", input: 500, cached: 400, output: 50)
        let page = fixture.meta(id: parentID, base: parentID, offset: parent.utf8.count)
            + fixture.event(at: "2026-10-20T01:00:00Z", input: 600, cached: 480, output: 55)
            + fixture.event(at: "2026-10-20T02:00:00Z", input: 700, cached: 560, output: 60)
        let pageURL = day.appendingPathComponent("rollout-\(parentID)_\(pageID).jsonl")
        try page.write(to: pageURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: fixture.date("2026-10-20T03:00:00Z")], ofItemAtPath: pageURL.path)
        let db = UsageArchiveDatabase(url: root.appendingPathComponent("archive.sqlite"))
        let now = fixture.date("2026-10-28T08:00:00Z")
        let engine = UsageArchiveEngine(database: db, claudeRoot: root.appendingPathComponent("empty"),
            codexRoot: codex, legacyURL: root.appendingPathComponent("no-legacy"), throttle: false)
        _ = try await engine.run(mode: .history, now: now, calendar: fixture.calendar)
        #expect(try await db.hasIncompleteCodexHistory())
        try parent.write(to: day.appendingPathComponent("rollout-\(parentID).jsonl"), atomically: true, encoding: .utf8)
        let unseen = day.appendingPathComponent("rollout-\(UUID().uuidString.lowercased()).jsonl")
        try (fixture.meta(id: UUID().uuidString) + fixture.event(at: "2026-10-20T02:00:00Z", input: 999, cached: 0, output: 0))
            .write(to: unseen, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: fixture.date("2026-10-20T03:00:00Z")], ofItemAtPath: unseen.path)
        _ = try await engine.run(mode: .automatic, now: now, calendar: fixture.calendar, startup: true, force: true)
        #expect(try await db.hasIncompleteCodexHistory() == false)
        let report = try await db.summary(days: 30, now: now, calendar: fixture.calendar)
        #expect(report.totalTokens == 200)
        let source = UsageLedgerRecord.identity(unseen.standardizedFileURL.path)
        #expect(try await db.checkpoint(source: source) == nil)
    }
}

extension CodexUsageHistoryTests {
    @Test func permanentlyMissingParentBacksOffOldHistoryRetryForOneDay() async throws {
        let root = try UsageLedgerStorageTests().folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let codex = root.appendingPathComponent("codex")
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        let id = UUID().uuidString.lowercased()
        let page = fixture.meta(id: id, base: UUID().uuidString, offset: 100)
            + fixture.event(at: "2026-10-27T01:00:00Z", input: 600, cached: 480, output: 55)
        try page.write(to: codex.appendingPathComponent("rollout-\(id).jsonl"), atomically: true, encoding: .utf8)
        let db = UsageArchiveDatabase(url: root.appendingPathComponent("archive.sqlite"))
        let now = fixture.date("2026-10-28T08:00:00Z")
        let engine = UsageArchiveEngine(database: db, claudeRoot: root.appendingPathComponent("empty"),
            codexRoot: codex, legacyURL: root.appendingPathComponent("no-legacy"), throttle: false)
        _ = try await engine.run(mode: .automatic, now: now, calendar: fixture.calendar, startup: true)
        _ = try await engine.run(mode: .automatic, now: now.addingTimeInterval(3601), calendar: fixture.calendar, startup: true)
        #expect(try await db.metadata("codex-history-retry") != nil)
        let retried = now.addingTimeInterval(3601)
        try await db.setMetadata("settled:" + UsageArchiveDatabase.zone(fixture.calendar), JSONEncoder().encode(now.addingTimeInterval(172800)))
        #expect(try await engine.isDue(now: retried.addingTimeInterval(3601), calendar: fixture.calendar, startup: true) == false)
        #expect(try await engine.isDue(now: retried.addingTimeInterval(86_400), calendar: fixture.calendar, startup: true))
    }
}

extension CodexUsageHistoryTests {
    @Test func metadataReadIsBoundedBeforeScanningTheRestOfTheRollout() {
        let oversized = String(repeating: "x", count: 1_048_577) + "\n"
        let text = oversized + fixture.meta(id: UUID().uuidString)
        #expect(CodexUsageHistory.metadata(in: text) == nil)
    }

    @Test func dailyByteParsingPreservesUnicodeAndCRLF() {
        let text = fixture.meta(id: UUID().uuidString)
            + "{\"type\":\"response_item\",\"payload\":{\"text\":\"中文 👩🏽‍💻 é\"}}\n"
            + fixture.event(at: "2026-10-27T01:00:00Z", input: 700, cached: 560, output: 60)
        let tally = UsageTracker.parseCodexDailyTallies(text: text.replacingOccurrences(of: "\n", with: "\r\n"),
            calendar: fixture.calendar, cutoff: .distantPast)
        let day = fixture.calendar.startOfDay(for: fixture.date("2026-10-27T01:00:00Z"))
        #expect(tally[day]?.values.reduce(0, { $0 + $1.input }) == 700)
        #expect(tally[day]?.values.reduce(0, { $0 + $1.cacheRead }) == 560)
        #expect(tally[day]?.values.reduce(0, { $0 + $1.output }) == 60)
    }
}

extension CodexUsageHistoryTests {
    @Test func dailyByteFilterRetainsUnicodeEscapedSchema() {
        let text = fixture.event(at: "2026-10-27T01:00:00Z", input: 700, cached: 560, output: 60)
            .replacingOccurrences(of: "token_count", with: #"\u0074oken_count"#)
            .replacingOccurrences(of: "total_token_usage", with: #"\u0074otal_token_usage"#)
        let tally = UsageTracker.parseCodexDailyTallies(text: text, calendar: fixture.calendar, cutoff: .distantPast)
        let day = fixture.calendar.startOfDay(for: fixture.date("2026-10-27T01:00:00Z"))
        #expect(tally[day]?.values.reduce(0, { $0 + $1.input }) == 700)
        #expect(tally[day]?.values.reduce(0, { $0 + $1.output }) == 60)
    }
}
