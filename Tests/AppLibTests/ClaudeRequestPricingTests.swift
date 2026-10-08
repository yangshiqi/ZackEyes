import Foundation
import Testing
@testable import AppLib

struct ClaudeRequestPricingTests {
    private func scan(_ records: [(String, String, String)]) throws -> UsageTracker.ClaudeScanResult {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ts = ISO8601DateFormatter().string(from: Date())
        let lines = records.map { id, model, usage in
            "{\"type\":\"assistant\",\"timestamp\":\"\(ts)\",\"message\":{\"id\":\"\(id)\",\"model\":\"\(model)\",\"usage\":\(usage)}}"
        }.joined(separator: "\n")
        try lines.write(to: dir.appendingPathComponent("s.jsonl"), atomically: true, encoding: .utf8)
        let fresh = UsageTracker.computeSnapshot(projectsDir: dir)
        let cached = UsageTracker.computeSnapshot(projectsDir: dir, cache: fresh.cache)
        #expect(fresh.daily == cached.daily)
        return fresh
    }

    private func cost(_ daily: [Date: [String: ModelTokenTally]]) throws -> Double {
        UsageTracker.buildDailyUsage(claude: daily, codex: [:], pricing: try ClaudePricingTests.bundled(), calendar: .current, now: Date()).compactMap(\.claudeCostUSD).reduce(0, +)
    }

    @Test func mixedSpeedsAndTTLBillEachResponseOnceAndMergeWithLegacyTallies() throws {
        let standard = #"{"input_tokens":100,"output_tokens":10,"cache_read_input_tokens":1000,"cache_creation_input_tokens":100,"cache_creation":{"ephemeral_5m_input_tokens":40,"ephemeral_1h_input_tokens":60},"speed":"standard"}"#
        let fast = standard.replacingOccurrences(of: "standard", with: "fast")
        let r = try scan([("a", "claude-opus-5-5", standard), ("a", "claude-opus-5-5", standard), ("b", "claude-opus-5-5", fast)])
        #expect(abs(try cost(r.daily) - 0.00444) < 1e-12)
        let t = try #require(r.daily.values.first?["claude-opus-5-5"])
        #expect(t.input == 200 && t.output == 20 && t.cacheCreate == 200 && t.cacheRead == 2000)
        #expect(r.snapshot.messages7d == 2)
        var merged = r.daily
        UsageTracker.mergeTallies(&merged, [Calendar.current.startOfDay(for: Date()): ["claude-opus-5-5": ModelTokenTally(input: 30)]])
        #expect(abs(try cost(merged) - 0.00456) < 1e-12)
    }

    @Test func absentSpeedDoesNotInheritFastAndUnsupportedFastDoesNotMultiply() throws {
        let r = try scan([
            ("fast", "claude-opus-5-5", #"{"input_tokens":100,"speed":"fast"}"#),
            ("default", "claude-opus-5-5", #"{"input_tokens":100}"#),
            ("unsupported", "claude-fable-5-1", #"{"input_tokens":100,"speed":"fast"}"#)
        ])
        #expect(abs(try cost(r.daily) - 0.0022) < 1e-12)
    }

    @Test func cacheSplitIsBoundedByAggregateAndLegacyWritesStillWork() throws {
        let r = try scan([
            ("clamped", "claude-opus-5-5", #"{"cache_creation_input_tokens":100,"cache_creation":{"ephemeral_1h_input_tokens":9999999999}}"#),
            ("legacy", "claude-opus-5-5", #"{"cache_creation_input_tokens":100}"#),
            ("negative", "claude-opus-5-5", #"{"cache_creation_input_tokens":100,"cache_creation":{"ephemeral_1h_input_tokens":-10}}"#)
        ])
        #expect(abs(try cost(r.daily) - 0.0018) < 1e-12)
        #expect(r.daily.values.first?["claude-opus-5-5"]?.cacheCreate == 300)
    }

    @Test func fullContextDoesNotApplyCodexLongContextMultiplier() throws {
        let r = try scan([("long", "claude-opus-5-5", #"{"input_tokens":900000,"output_tokens":1000}"#)])
        #expect(abs(try cost(r.daily) - 3.62) < 1e-12)
    }
}

@Test func legacyClaudePriceFileKeepsExistingWriteEstimate() throws {
    let table = try PricingTable(data: Data(#"{"models":{"claude-opus-5-5":{"input":0.000004,"output":0.000020,"cache_creation":0.000005}}}"#.utf8))
    let price = try #require(table.price(for: "claude-opus-5-5"))
    #expect(price.cacheCreate1hPerToken == nil)
    let units = ClaudeBillingUnits.estimate(input: 0, output: 0, cached: 0, writes: 100, writes1h: 100, model: "claude-opus-5-5")
    #expect(abs(units.cost(using: price) - 0.0005) < 1e-12)
}
