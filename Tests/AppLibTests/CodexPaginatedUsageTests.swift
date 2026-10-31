import Foundation
import Testing
@testable import AppLib

@MainActor
struct CodexPaginatedUsageTests {
    let iso = ISO8601DateFormatter()
    var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return value
    }
    func date(_ raw: String) -> Date { iso.date(from: raw)! }
    func event(at: String, input: Int, cached: Int, output: Int) -> String {
        """
        {"timestamp":"\(at)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\(input),"cached_input_tokens":\(cached),"output_tokens":\(output)}}}}

        """
    }
    func meta(id: String, base: String? = nil, offset: Int = 0) -> String {
        let history = base.map { ",\"history_mode\":\"paginated\",\"history_base\":{\"thread_id\":\"\($0)\",\"end_byte_offset\":\(offset),\"end_ordinal_exclusive\":3}" } ?? ""
        return "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(id)\"\(history)}}\n"
    }

    @Test func liveDifferencesCumulativeCountersAboveOneBillion() throws {
        let text = """
        {"type":"turn_context","payload":{"model":"gpt-6.1-sol"}}

        """ + event(at: "2026-10-26T15:59:00Z", input: 1_313_546_957, cached: 1_297_960_576, output: 3_229_492)
            + event(at: "2026-10-27T01:57:55Z", input: 1_313_695_658, cached: 1_298_109_056, output: 3_229_718)
        let tallies = UsageTracker.parseCodexDailyTallies(text: text, calendar: calendar, cutoff: date("2026-10-26T16:00:00Z"))
        let tally = try #require(tallies[date("2026-10-26T16:00:00Z")]?["gpt-6.1-sol"])
        #expect(tally.input == 148_701)
        #expect(tally.cacheRead == 148_480)
        #expect(tally.output == 226)
    }

    @Test func liveContinuationUsesPinnedHistoryBaseline() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let day = root.appendingPathComponent("2026/10/27")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let baseID = UUID().uuidString.lowercased()
        let pageID = UUID().uuidString.lowercased()
        let base = meta(id: baseID)
            + event(at: "2026-10-26T15:59:00Z", input: 1_313_546_957, cached: 1_297_960_576, output: 3_229_492)
        // A later parent append is outside the referenced snapshot and must not
        // affect the page's initial baseline.
        let append = event(at: "2026-10-27T02:30:00Z", input: 1_313_546_957, cached: 1_297_960_576, output: 3_229_492)
        try (base + append).write(to: day.appendingPathComponent("rollout-\(baseID).jsonl"), atomically: true, encoding: .utf8)
        let page = meta(id: baseID, base: baseID, offset: base.utf8.count)
            + "{\"type\":\"turn_context\",\"payload\":{\"model\":\"gpt-6.1-sol\"}}\n"
            + event(at: "2026-10-27T01:57:55Z", input: 1_313_695_658, cached: 1_298_109_056, output: 3_229_718)
        try page.write(to: day.appendingPathComponent("rollout-\(baseID)_\(pageID).jsonl"), atomically: true, encoding: .utf8)
        let scan = UsageTracker.scanCodexDailyTokens(rootDir: root, cache: [:], calendar: calendar,
                                                   now: date("2026-10-28T08:00:00Z"))
        let tally = try #require(scan.merged[date("2026-10-26T16:00:00Z")]?["gpt-6.1-sol"])
        #expect(tally.input == 148_701)
        #expect(tally.cacheRead == 148_480)
        #expect(tally.output == 226)
    }

    @Test func archiveAcceptsWideCountersAndDifferencesBeforeSumming() throws {
        let text = meta(id: UUID().uuidString)
            + event(at: "2026-10-26T15:59:00Z", input: 1_313_546_957, cached: 1_297_960_576, output: 3_229_492)
            + event(at: "2026-10-27T01:57:55Z", input: 1_313_695_658, cached: 1_298_109_056, output: 3_229_718)
        let records = UsageLedgerParser.parse(text: text, agent: .codex, sourceID: "test")
        #expect(records.filter { $0.kind == .counter }.count == 2)
        let report = UsageLedgerSummary.make(records: records, days: 1,
                                             now: date("2026-10-27T15:59:59Z"), calendar: calendar)
        #expect(report.totalTokens == 447)
        #expect(report.cacheReused == 148_480)
    }
}

extension CodexPaginatedUsageTests {
    @Test func legacyCounterCanBeCorrectedToBaselineThenConfirmed() {
        var legacy = UsageLedgerRecord(id: "counter", session: "session", agent: .codex,
                                      project: "p", model: "m", date: Date(), kind: .counter, input: 500)
        var incomplete = legacy
        incomplete.baseline = true
        #expect(incomplete.supersedes(legacy))
        legacy.baseline = false
        #expect(legacy.supersedes(incomplete))
        #expect(!incomplete.supersedes(legacy))
    }

    @Test func archiveCheckpointUpgradeRunsOnceThenReadsZero() async throws {
        let root = try UsageLedgerStorageTests().folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("source.jsonl")
        let text = meta(id: UUID().uuidString)
            + event(at: "2026-10-26T15:59:00Z", input: 1_313_546_957, cached: 1_297_960_576, output: 3_229_492)
            + event(at: "2026-10-27T01:57:55Z", input: 1_313_695_658, cached: 1_298_109_056, output: 3_229_718)
        try text.write(to: file, atomically: true, encoding: .utf8)
        let db = UsageArchiveDatabase(url: root.appendingPathComponent("archive.sqlite"))
        let importer = UsageArchiveImporter(database: db, throttle: false)
        _ = try await importer.importFile(file, agent: .codex, cutoff: nil)
        let source = UsageLedgerRecord.identity(file.standardizedFileURL.path)
        let checkpoint = try #require(try await db.checkpoint(source: source))
        var old = try #require(JSONSerialization.jsonObject(with: checkpoint) as? [String: Any])
        old.removeValue(forKey: "counterVersion")
        old["rejected"] = 1
        try await db.apply(records: [], source: source, checkpoint: JSONSerialization.data(withJSONObject: old))
        #expect(try await importer.importFile(file, agent: .codex, cutoff: nil).bytesRead > 0)
        #expect(try await importer.importFile(file, agent: .codex, cutoff: nil).bytesRead == 0)
        let records = try await db.records(start: date("2026-10-26T16:00:00Z"), end: date("2026-10-27T16:00:00Z"))
        let report = UsageLedgerSummary.make(records: records, days: 1, now: date("2026-10-27T15:59:59Z"), calendar: calendar)
        #expect(report.totalTokens == 447)
    }
}
