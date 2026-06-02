import Testing
import Foundation
@testable import AppLib

@MainActor
struct UsageTrackerDailyTests {
    private static func tmpDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    // A Shanghai (UTC+8) calendar to prove buckets use the LOCAL day boundary.
    private static let shanghai: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }()
    private static func claudeLine(ts: String, model: String, input: Int, output: Int) -> String {
        """
        {"type":"assistant","timestamp":"\(ts)","message":{"model":"\(model)","usage":{"input_tokens":\(input),"output_tokens":\(output),"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
        """
    }

    private static func codexDayDir(under root: URL, now: Date) -> URL {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!
        let comps = c.dateComponents([.year, .month, .day], from: now)
        return root.appendingPathComponent(String(format: "%04d/%02d/%02d", comps.year!, comps.month!, comps.day!))
    }

    @Test func codexScanReadsRolloutAndCacheIsHonored() throws {
        let now = Date()
        let root = try Self.tmpDir()
        let dayDir = Self.codexDayDir(under: root, now: now)
        try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
        let file = dayDir.appendingPathComponent("rollout-x.jsonl")
        let key = file.resolvingSymlinksInPath().path
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let tsString = iso.string(from: now)
        let text = #"{"type":"turn_context","timestamp":"\#(tsString)","payload":{"model":"gpt-5.5"}}"#
            + "\n" + #"{"type":"event_msg","timestamp":"\#(tsString)","payload":{"type":"token_count","info":{"last_token_usage":{},"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":10,"total_tokens":110}}}}"#
        try text.write(to: file, atomically: true, encoding: .utf8)

        let cal = Calendar.current
        let r1 = UsageTracker.scanCodexDailyTokens(rootDir: root, cache: [:], calendar: cal, now: now)
        let today = cal.startOfDay(for: now)
        #expect(r1.merged[today]?["gpt-5.5"]?.input == 100)
        #expect(r1.cache[key] != nil)

        // Re-scan with a cache that returns a SENTINEL tally for the unchanged file →
        // proves the cache is used (file not re-parsed).
        var poisoned = r1.cache
        poisoned[key]?.tallies = [today: ["sentinel": ModelTokenTally(input: 7)]]
        let r2 = UsageTracker.scanCodexDailyTokens(rootDir: root, cache: poisoned, calendar: cal, now: now)
        #expect(r2.merged[today]?["sentinel"]?.input == 7)        // served from cache
        #expect(r2.merged[today]?["gpt-5.5"] == nil)
    }

    @Test func refreshPopulatesSevenDayUsageWithCost() async throws {
        let now = Date()
        let projects = try Self.tmpDir()
        let proj = projects.appendingPathComponent("p"); try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let line = """
        {"type":"assistant","timestamp":"\(iso.string(from: now))","message":{"model":"claude-opus-4-8","usage":{"input_tokens":1000,"output_tokens":100,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
        """
        try line.write(to: proj.appendingPathComponent("s.jsonl"), atomically: true, encoding: .utf8)

        let tracker = UsageTracker(projectsDir: projects, codexSessionsDir: nil)
        let store = PricingStore(cacheURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
                                 bundledData: { Data(#"{"version":"t","models":{"claude-opus-4-8":{"input":1e-5,"output":1e-4,"cache_read":0,"cache_creation":0}}}"#.utf8) },
                                 fetch: { nil })
        store.loadInitial()
        tracker.pricingStore = store

        await tracker.refresh()
        let today = Calendar.current.startOfDay(for: now)
        let day = tracker.snapshot.dailyUsage.first { $0.dayStart == today }
        #expect(tracker.snapshot.dailyUsage.count == 7)
        #expect(day?.claudeTokens == 1100)
        // 1000*1e-5 + 100*1e-4 = 0.01 + 0.01 = 0.02
        #expect(abs((day?.claudeCostUSD ?? -1) - 0.02) < 1e-12)
    }

    @Test func oldUsageCacheWithoutDailyUsageStillDecodes() throws {
        // Simulate an OLD usage-cache.json written before `dailyUsage` existed:
        // it has the 5h/7d rate-limit fields but NO "dailyUsage" key.
        let oldJSON = """
        {"fiveHourUsedPct":42.0,"sevenDayUsedPct":71.0,"tokens5h":0,"tokens7d":0,"messages5h":0,"messages7d":0}
        """
        let snap = try JSONDecoder().decode(UsageTracker.Snapshot.self, from: Data(oldJSON.utf8))
        #expect(snap.fiveHourUsedPct == 42.0)     // rate-limit fields restored (not dropped)
        #expect(snap.sevenDayUsedPct == 71.0)
        #expect(snap.dailyUsage.isEmpty)           // missing key → default [], no throw
    }

    @Test func snapshotDoesNotPersistDailyUsage() throws {
        let d = Date(timeIntervalSince1970: 0)
        var snap = UsageTracker.Snapshot.empty
        snap.dailyUsage = [DayUsage(dayStart: d, claudeTokens: 100)]
        let data = try JSONEncoder().encode(snap)
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(!json.contains("dailyUsage"))      // not persisted
    }

    @Test func claudeMidnightSplitsByLocalDay() throws {
        // now = 2026-06-02 12:00 Shanghai. Two messages straddle local midnight:
        //  23:30 on 06-01 Shanghai (== 15:30Z) and 00:30 on 06-02 Shanghai (== 16:30Z 06-01).
        let now = Self.shanghai.date(from: DateComponents(timeZone: TimeZone(identifier: "Asia/Shanghai"),
            year: 2026, month: 6, day: 2, hour: 12))!
        let projects = try Self.tmpDir()
        let proj = projects.appendingPathComponent("p"); try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        let text = [
            Self.claudeLine(ts: "2026-06-01T15:30:00.000Z", model: "claude-opus-4-8", input: 10, output: 1),  // 23:30 06-01 SH
            Self.claudeLine(ts: "2026-06-01T16:30:00.000Z", model: "claude-opus-4-8", input: 20, output: 2)   // 00:30 06-02 SH
        ].joined(separator: "\n")
        try text.write(to: proj.appendingPathComponent("s.jsonl"), atomically: true, encoding: .utf8)

        let res = UsageTracker.computeSnapshot(projectsDir: projects, calendar: Self.shanghai, now: now)
        let jun1 = Self.shanghai.startOfDay(for: Self.shanghai.date(from: DateComponents(timeZone: TimeZone(identifier: "Asia/Shanghai"), year: 2026, month: 6, day: 1, hour: 12))!)
        let jun2 = Self.shanghai.startOfDay(for: now)
        #expect(res.daily[jun1]?["claude-opus-4-8"]?.input == 10)   // first msg → 06-01 local
        #expect(res.daily[jun2]?["claude-opus-4-8"]?.input == 20)   // second msg → 06-02 local
    }
}
