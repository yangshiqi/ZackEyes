import Testing
import Foundation
@testable import AppLib

struct DailyUsageTests {
    // Fixed clock so "today" is deterministic. 2026-06-02 12:00 UTC.
    static let now = Date(timeIntervalSince1970: 1_780_401_600)
    static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    static func pricing() -> PricingTable {
        let json = """
        {"version":"t","models":{
          "claude-opus-4-8":{"input":1e-5,"output":1e-4,"cache_read":1e-6,"cache_creation":2e-5},
          "gpt-5.5":{"input":1e-6,"output":1e-5,"cache_read":1e-7,"cache_creation":0}
        }}
        """
        return try! PricingTable(data: Data(json.utf8))
    }

    @Test func sevenZeroFilledBucketsEndingToday() {
        let days = UsageTracker.buildDailyUsage(claude: [:], codex: [:], pricing: .empty, calendar: Self.utc, now: Self.now)
        #expect(days.count == 7)
        #expect(days.last?.dayStart == Self.utc.startOfDay(for: Self.now))
        #expect(days.allSatisfy { $0.totalTokens == 0 })
        #expect(days.last?.claudeCostUSD == nil)   // no priced tokens → nil, not 0
        #expect(days.last?.anyUnpriced == false)
    }

    @Test func claudeTokensAndCostForToday() {
        let today = Self.utc.startOfDay(for: Self.now)
        let claude: [Date: [String: ModelTokenTally]] = [
            today: ["claude-opus-4-8": ModelTokenTally(input: 100, output: 10, cacheRead: 1000, cacheCreate: 50)]
        ]
        let days = UsageTracker.buildDailyUsage(claude: claude, codex: [:], pricing: Self.pricing(), calendar: Self.utc, now: Self.now)
        let t = days.last!
        #expect(t.claudeTokens == 1160)                 // 100+10+1000+50
        // 100*1e-5 + 10*1e-4 + 1000*1e-6 + 50*2e-5 = 0.001+0.001+0.001+0.001 = 0.004
        #expect(abs((t.claudeCostUSD ?? -1) - 0.004) < 1e-12)
        #expect(t.codexCostUSD == nil)
        #expect(t.anyUnpriced == false)
    }

    @Test func codexUncachedInputCost() {
        let today = Self.utc.startOfDay(for: Self.now)
        // input includes cached: input=1000, cached(cacheRead)=600, output=20
        let codex: [Date: [String: ModelTokenTally]] = [
            today: ["gpt-5.5": ModelTokenTally(input: 1000, output: 20, cacheRead: 600, cacheCreate: 0)]
        ]
        let days = UsageTracker.buildDailyUsage(claude: [:], codex: codex, pricing: Self.pricing(), calendar: Self.utc, now: Self.now)
        let t = days.last!
        #expect(t.codexTokens == 1020)                  // input+output (cached is subset of input)
        // uncached=400 *1e-6 + cached 600*1e-7 + output 20*1e-5 = 4e-4 + 6e-5 + 2e-4 = 6.6e-4
        #expect(abs((t.codexCostUSD ?? -1) - 6.6e-4) < 1e-12)
    }

    @Test func unpricedModelCountsTokensButNoCostAndSetsFlag() {
        let today = Self.utc.startOfDay(for: Self.now)
        let claude: [Date: [String: ModelTokenTally]] = [
            today: ["mystery-model": ModelTokenTally(input: 100, output: 10, cacheRead: 0, cacheCreate: 0)]
        ]
        let days = UsageTracker.buildDailyUsage(claude: claude, codex: [:], pricing: Self.pricing(), calendar: Self.utc, now: Self.now)
        let t = days.last!
        #expect(t.claudeTokens == 110)
        #expect(t.claudeCostUSD == nil)     // no priced tokens at all → nil
        #expect(t.anyUnpriced == true)      // floor marker
    }

    @Test func dropsTalliesOutsideSevenDayWindow() {
        let old = Self.utc.date(byAdding: .day, value: -30, to: Self.utc.startOfDay(for: Self.now))!
        let claude: [Date: [String: ModelTokenTally]] = [
            old: ["claude-opus-4-8": ModelTokenTally(input: 999, output: 0, cacheRead: 0, cacheCreate: 0)]
        ]
        let days = UsageTracker.buildDailyUsage(claude: claude, codex: [:], pricing: Self.pricing(), calendar: Self.utc, now: Self.now)
        #expect(days.allSatisfy { $0.claudeTokens == 0 })   // 30-day-old bucket not in the 7-day window
    }

    @Test func tokensThreeDaysAgoLandInCorrectBucket() {
        let threeDaysAgo = Self.utc.date(byAdding: .day, value: -3, to: Self.utc.startOfDay(for: Self.now))!
        let claude: [Date: [String: ModelTokenTally]] = [
            threeDaysAgo: ["claude-opus-4-8": ModelTokenTally(input: 50, output: 5, cacheRead: 0, cacheCreate: 0)]
        ]
        let days = UsageTracker.buildDailyUsage(claude: claude, codex: [:], pricing: .empty,
                                                calendar: Self.utc, now: Self.now)
        #expect(days.count == 7)
        #expect(days[3].claudeTokens == 55)   // index 3 == today-3 (oldest→today)
        #expect(days[6].claudeTokens == 0)    // today empty
    }

    @Test func combinedClaudeAndCodexSameDay() {
        let today = Self.utc.startOfDay(for: Self.now)
        let claude: [Date: [String: ModelTokenTally]] = [
            today: ["claude-opus-4-8": ModelTokenTally(input: 100, output: 10, cacheRead: 0, cacheCreate: 0)]
        ]
        let codex: [Date: [String: ModelTokenTally]] = [
            today: ["gpt-5.5": ModelTokenTally(input: 200, output: 20, cacheRead: 0, cacheCreate: 0)]
        ]
        let t = UsageTracker.buildDailyUsage(claude: claude, codex: codex, pricing: Self.pricing(),
                                             calendar: Self.utc, now: Self.now).last!
        #expect(t.claudeTokens == 110)
        #expect(t.codexTokens == 220)
        #expect(t.totalTokens == 330)
        #expect(t.claudeCostUSD != nil)
        #expect(t.codexCostUSD != nil)
        #expect(t.anyUnpriced == false)
    }
}
