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
        #expect(t.claudeTokens == 110)                  // input + output only (cache excluded from count)
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

    // Real-rollout-shaped fixture: session_meta, turn_context (model), then two
    // token_count events whose cumulative total_token_usage grows per turn.
    static func codexRollout() -> String {
        [
        #"{"type":"session_meta","timestamp":"2026-06-02T03:00:00.000Z","payload":{"id":"x"}}"#,
        #"{"type":"turn_context","timestamp":"2026-06-02T03:00:01.000Z","payload":{"model":"gpt-5.5"}}"#,
        // turn 1: cumulative input=100 (cached 40), output=10
        #"{"type":"event_msg","timestamp":"2026-06-02T03:00:02.000Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":40,"output_tokens":10,"total_tokens":110},"total_token_usage":{"input_tokens":100,"cached_input_tokens":40,"output_tokens":10,"total_tokens":110}}}}"#,
        // turn 2: cumulative input=300 (cached 140), output=30 → delta input=200, cached=100, output=20
        #"{"type":"event_msg","timestamp":"2026-06-02T03:00:03.000Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":200,"cached_input_tokens":100,"output_tokens":20,"total_tokens":220},"total_token_usage":{"input_tokens":300,"cached_input_tokens":140,"output_tokens":30,"total_tokens":330}}}}"#
        ].joined(separator: "\n")
    }

    @Test func codexDeltaFromCumulativeTotals() {
        // now 2026-06-02 12:00 UTC; cutoff = startOfDay - 6d, so everything is in-window.
        let tallies = UsageTracker.parseCodexDailyTallies(text: Self.codexRollout(), calendar: Self.utc,
            cutoff: Self.utc.date(byAdding: .day, value: -6, to: Self.utc.startOfDay(for: Self.now))!)
        let day = Self.utc.startOfDay(for: Self.now)
        let t = tallies[day]?["gpt-5.5"]
        #expect(t?.input == 300)        // 100 + 200 (per-turn deltas of cumulative input)
        #expect(t?.cacheRead == 140)    // 40 + 100 (cached deltas)
        #expect(t?.output == 30)        // 10 + 20
        #expect(t?.cacheCreate == 0)    // codex has no cache-creation
    }

    @Test func codexDropsTurnsBeforeCutoff() {
        let line = #"{"type":"turn_context","timestamp":"2020-01-01T00:00:00.000Z","payload":{"model":"gpt-5.5"}}"#
            + "\n" + #"{"type":"event_msg","timestamp":"2020-01-01T00:00:01.000Z","payload":{"type":"token_count","info":{"last_token_usage":{},"total_token_usage":{"input_tokens":500,"cached_input_tokens":0,"output_tokens":50,"total_tokens":550}}}}"#
        let tallies = UsageTracker.parseCodexDailyTallies(text: line, calendar: Self.utc,
            cutoff: Self.utc.date(byAdding: .day, value: -6, to: Self.utc.startOfDay(for: Self.now))!)
        #expect(tallies.isEmpty)        // 2020 turn is far before the 7-day window
    }

    @Test func codexUnknownModelFallbackWhenNoTurnContext() {
        // A token_count with NO preceding turn_context → model defaults to "unknown".
        let text = #"{"type":"event_msg","timestamp":"2026-06-02T03:00:02.000Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":10,"total_tokens":110}}}}"#
        let tallies = UsageTracker.parseCodexDailyTallies(text: text, calendar: Self.utc,
            cutoff: Self.utc.date(byAdding: .day, value: -6, to: Self.utc.startOfDay(for: Self.now))!)
        let day = Self.utc.startOfDay(for: Self.now)
        #expect(tallies[day]?["unknown"]?.input == 100)
        #expect(tallies[day]?["unknown"]?.output == 10)
    }

    @Test func claudeTokensExcludeCacheFromCount() {
        let today = Self.utc.startOfDay(for: Self.now)
        let claude: [Date: [String: ModelTokenTally]] = [
            today: ["claude-opus-4-8": ModelTokenTally(input: 5, output: 3, cacheRead: 9_999, cacheCreate: 7_777)]
        ]
        let t = UsageTracker.buildDailyUsage(claude: claude, codex: [:], pricing: .empty, calendar: Self.utc, now: Self.now).last!
        #expect(t.claudeTokens == 8)    // 5 + 3 only; cache_read/creation NOT counted
    }

    @Test func codexModelSwitchMidFileAttributesDeltasCorrectly() {
        // turn_context(A) → token_count(cum 100/0/10) → turn_context(B) → token_count(cum 300/0/30)
        // delta1 = 100in/10out → model A ; delta2 = 200in/20out → model B
        let text = [
            #"{"type":"turn_context","timestamp":"2026-06-02T03:00:00.000Z","payload":{"model":"model-a"}}"#,
            #"{"type":"event_msg","timestamp":"2026-06-02T03:00:01.000Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":10,"total_tokens":110}}}}"#,
            #"{"type":"turn_context","timestamp":"2026-06-02T03:00:02.000Z","payload":{"model":"model-b"}}"#,
            #"{"type":"event_msg","timestamp":"2026-06-02T03:00:03.000Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":300,"cached_input_tokens":0,"output_tokens":30,"total_tokens":330}}}}"#
        ].joined(separator: "\n")
        let tallies = UsageTracker.parseCodexDailyTallies(text: text, calendar: Self.utc,
            cutoff: Self.utc.date(byAdding: .day, value: -6, to: Self.utc.startOfDay(for: Self.now))!)
        let day = Self.utc.startOfDay(for: Self.now)
        #expect(tallies[day]?["model-a"]?.input == 100)
        #expect(tallies[day]?["model-a"]?.output == 10)
        #expect(tallies[day]?["model-b"]?.input == 200)   // 300-100
        #expect(tallies[day]?["model-b"]?.output == 20)    // 30-10
    }
}
