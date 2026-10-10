import Testing
import Foundation
import Shared
@testable import AppLib

struct CodexRequestPricingTests {
    static let price = try! PricingTable(data: Data(#"{"models":{"gpt-6.1-sol":{"input":0.000002,"output":0.00001,"cache_read":0.0000001,"cache_creation":0.0000025},"gpt-6-astra":{"input":0.00001,"output":0.00005,"cache_read":0.000001,"cache_creation":0.0000125}}}"#.utf8))
    static let now = ISO8601DateFormatter().date(from: "2026-10-08T12:00:00Z")!
    static let calendar = Calendar(identifier: .gregorian)

    static func cost(input: Int, tier: String?, writes: Int = 0) -> DayUsage {
        let settings = tier.map { #"{"type":"event_msg","payload":{"type":"thread_settings_applied","thread_settings":{"model":"gpt-6.1-sol","service_tier":""# + $0 + #""}}}"# + "\n" } ?? ""
        let text = settings + #"{"type":"turn_context","payload":{"model":"gpt-6.1-sol"}}"# + "\n" + """
        {"timestamp":"2026-10-08T12:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\(input),"cached_input_tokens":100,"cache_write_input_tokens":\(writes),"output_tokens":100},"last_token_usage":{"input_tokens":\(input),"cached_input_tokens":100,"cache_write_input_tokens":\(writes),"output_tokens":100}}}}
        """
        let tally = UsageTracker.parseCodexDailyTallies(text: text, calendar: calendar, cutoff: .distantPast)
        return UsageTracker.buildDailyUsage(claude: [:], codex: tally, pricing: price, calendar: calendar, now: now).last!
    }

    @Test func longContextUsesRequestThresholdAndDifferentOutputMultiplier() {
        let short = Self.cost(input: 272000, tier: "default")
        let long = Self.cost(input: 272001, tier: "default")
        #expect(abs((short.codexCostUSD ?? -1) - (271900 * 2e-6 + 100 * 1e-7 + 100 * 1e-5)) < 1e-10)
        #expect(abs((long.codexCostUSD ?? -1) - (271901 * 4e-6 + 100 * 2e-7 + 100 * 1.5e-5)) < 1e-10)
    }

    @Test func tiersScaleCostWithoutChangingTokenCounts() {
        let standard = Self.cost(input: 1000, tier: "default")
        for (tier, scale) in [("priority", 2.0), ("fast", 2.0), ("ultrafast", 6.0), ("flex", 0.5), ("batch", 0.5)] {
            let value = Self.cost(input: 1000, tier: tier)
            #expect(value.codexTokens == standard.codexTokens)
            #expect(abs((value.codexCostUSD ?? -1) - (standard.codexCostUSD ?? 0) * scale) < 1e-10)
        }
    }

    @Test func onlyExplicitCacheWritesAreCharged() {
        let value = Self.cost(input: 1000, tier: "default", writes: 200)
        #expect(value.cacheWriteTokens == 200)
        #expect(value.inputTokens == 700)
        #expect(abs((value.codexCostUSD ?? -1) - (700 * 2e-6 + 100 * 1e-7 + 200 * 2.5e-6 + 100 * 1e-5)) < 1e-10)
        #expect(Self.cost(input: 1000, tier: nil).cacheWriteTokens == 0)
    }
}

@MainActor @Test func sessionModelSwitchDoesNotRepricePriorUsage() {
    let store = SessionStore()
    store.codexPriceLookup = { CodexRequestPricingTests.price.price(for: $0) }
    store.setCodexModelDisplayName(sessionId: "s", cwd: nil, transcriptPath: nil, displayName: "gpt-6.1-sol")
    store.recordCodexContext(sessionId: "s", cwd: nil, contextUsedPct: 1, contextWindowSize: 1000000, transcriptPath: nil, observedAt: Date(), cumulativeInput: 1000, cumulativeCached: 0, cumulativeOutput: 100)
    store.setCodexModelDisplayName(sessionId: "s", cwd: nil, transcriptPath: nil, displayName: "gpt-6-astra")
    store.recordCodexContext(sessionId: "s", cwd: nil, contextUsedPct: 1, contextWindowSize: 1000000, transcriptPath: nil, observedAt: Date(), cumulativeInput: 2000, cumulativeCached: 0, cumulativeOutput: 200)
    #expect(abs((store.sessions["s"]?.totalCostUSD ?? -1) - 0.018) < 1e-10)
}

@MainActor @Test func streamedPricingPreservesTierAndDeduplicatesTokenRows() throws {
    let store = SessionStore()
    store.codexPriceLookup = { CodexRequestPricingTests.price.price(for: $0) }
    let text = """
    {"type":"event_msg","payload":{"type":"thread_settings_applied","thread_settings":{"model":"gpt-6.1-sol","service_tier":"fast"}}}
    {"type":"turn_context","payload":{"model":"gpt-6.1-sol"}}
    {"type":"event_msg","payload":{"type":"token_count","info":{"model_context_window":1050000,"total_token_usage":{"input_tokens":272001,"cached_input_tokens":100,"cache_write_input_tokens":200,"output_tokens":100},"last_token_usage":{"input_tokens":272001,"cached_input_tokens":100,"cache_write_input_tokens":200,"output_tokens":100,"total_tokens":272101}}}}
    """ + "\n"
    var pending = ""
    let events = CodexJsonlTailer.parseTaskLifecycleEvents(chunk: text, pending: &pending, sessionId: "s", cwd: nil, transcriptPath: "/tmp/rollout.jsonl")
    for event in events {
        switch event {
        case .modelChanged(let model): store.recordCodexModel(model)
        case .tokenCount(let usage):
            store.recordCodexTokenCount(usage, observedAt: Date())
            store.recordCodexTokenCount(usage, observedAt: Date())
        default: break
        }
    }
    #expect(store.sessions["s"]?.codexServiceTier == "fast")
    let expected = (271701 * 4e-6 + 100 * 2e-7 + 200 * 5e-6 + 100 * 1.5e-5) * 2
    #expect(abs((store.sessions["s"]?.totalCostUSD ?? -1) - expected) < 1e-10)
}

@Test func cumulativeGapIsNotTreatedAsOneLongRequest() {
    let usage = CodexUsageTotals(input: 300000, cached: 100, output: 100)
    let last = CodexUsageTotals(input: 150000, cached: 50, output: 50)
    let units = CodexBillingUnits.estimate(usage, model: "gpt-6.1-sol", tier: nil, request: last)
    #expect(abs(units.cost(using: CodexRequestPricingTests.price.price(for: "gpt-6.1-sol")!) - (299900 * 2e-6 + 100 * 1e-7 + 100 * 1e-5)) < 1e-10)
}

@Test func mergingFilesPreservesWeightedCostsAndRawCounts() {
    var weighted = ModelTokenTally(input: 1000, output: 100)
    weighted.codexBilling = .estimate(CodexUsageTotals(input: 1000, output: 100), model: "gpt-6.1-sol", tier: "fast", request: nil)
    let plain = ModelTokenTally(input: 1000, output: 100)
    let day = CodexRequestPricingTests.calendar.startOfDay(for: CodexRequestPricingTests.now)
    var tallies = [day: ["gpt-6.1-sol": plain]]
    UsageTracker.mergeTallies(&tallies, [day: ["gpt-6.1-sol": weighted]])
    let result = UsageTracker.buildDailyUsage(claude: [:], codex: tallies, pricing: CodexRequestPricingTests.price, calendar: CodexRequestPricingTests.calendar, now: CodexRequestPricingTests.now).last!
    #expect(result.codexTokens == 2200)
    #expect(abs((result.codexCostUSD ?? -1) - 0.009) < 1e-10)
}

@MainActor @Test func streamedTurnContextTierChangesMatchDailyPricing() throws {
    let store = SessionStore()
    store.codexPriceLookup = { CodexRequestPricingTests.price.price(for: $0) }
    var transcript = ""
    var expectedCost = 0.0
    let variants: [(String, String?, Double)] = [
        (#", "service_tier":"fast""#, "fast", 2),
        ("", "fast", 2),
        (#", "service_tier":"default""#, "default", 1),
        (#", "service_tier":"fast""#, "fast", 2),
        (#", "service_tier":null"#, nil, 1),
    ]
    for (index, variant) in variants.enumerated() {
        let row = """
        {"timestamp":"2026-10-08T12:00:00Z","type":"turn_context","payload":{"model":"gpt-6.1-sol"\(variant.0)}}
        {"timestamp":"2026-10-08T12:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"model_context_window":1050000,"total_token_usage":{"input_tokens":\((index + 1) * 1000),"output_tokens":\((index + 1) * 100)},"last_token_usage":{"input_tokens":1000,"output_tokens":100,"total_tokens":1100}}}}
        """ + "\n"
        transcript += row
        var pending = ""
        let events = CodexJsonlTailer.parseTaskLifecycleEvents(chunk: row, pending: &pending, sessionId: "s", cwd: nil, transcriptPath: "/tmp/rollout")
        for event in events {
            switch event {
            case .modelChanged(let model): store.recordCodexModel(model)
            case .tokenCount(let usage): store.recordCodexTokenCount(usage, observedAt: Date())
            default: break
            }
        }
        expectedCost += 0.003 * variant.2
        #expect(store.sessions["s"]?.codexServiceTier == variant.1)
        #expect(abs((store.sessions["s"]?.totalCostUSD ?? -1) - expectedCost) < 1e-10)
        let daily = UsageTracker.parseCodexDailyTallies(text: transcript, calendar: CodexRequestPricingTests.calendar, cutoff: .distantPast)
        let cost = UsageTracker.buildDailyUsage(claude: [:], codex: daily, pricing: CodexRequestPricingTests.price, calendar: CodexRequestPricingTests.calendar, now: CodexRequestPricingTests.now).last?.codexCostUSD
        #expect(abs((store.sessions["s"]?.totalCostUSD ?? -1) - (cost ?? -2)) < 1e-10)
    }
}

@MainActor @Test(arguments: [false, true]) func missingWriteTotalsPreserveBillingBaseline(useContext: Bool) {
    let store = SessionStore()
    store.codexPriceLookup = { CodexRequestPricingTests.price.price(for: $0) }
    store.setCodexModelDisplayName(sessionId: "s", cwd: nil, transcriptPath: nil, displayName: "gpt-6.1-sol")
    func record(input: Int, writes: Int?) {
        let event = CodexTokenCountEvent(sessionId: "s", cwd: nil, contextUsedPct: 1,
            contextWindowSize: 1000000, transcriptPath: "/tmp/rollout", cumulativeInput: input,
            cumulativeCached: 0, cumulativeOutput: 0, cumulativeWrites: writes)
        store.recordCodexTokenCount(event, observedAt: Date())
    }
    record(input: 1000, writes: 200)
    if useContext {
        store.recordCodexContext(sessionId: "s", cwd: nil, contextUsedPct: 1,
            contextWindowSize: 1000000, transcriptPath: nil, observedAt: Date(),
            cumulativeInput: 2000, cumulativeCached: 0, cumulativeOutput: 0)
    } else {
        record(input: 2000, writes: nil)
    }
    #expect(store.sessions["s"]?.codexUsageTotals?.writes == 200)
    record(input: 3000, writes: 200)
    #expect(abs((store.sessions["s"]?.totalCostUSD ?? -1) - (2800 * 2e-6 + 200 * 2.5e-6)) < 1e-10)
}

@MainActor @Test func explicitZeroWritesResetsBillingBaseline() {
    let store = SessionStore()
    store.codexPriceLookup = { CodexRequestPricingTests.price.price(for: $0) }
    store.setCodexModelDisplayName(sessionId: "s", cwd: nil, transcriptPath: nil, displayName: "gpt-6.1-sol")
    for (input, writes) in [(1000, 200), (2000, 0), (3000, 200)] {
        store.recordCodexTokenCount(CodexTokenCountEvent(sessionId: "s", cwd: nil, contextUsedPct: 1,
            contextWindowSize: 1000000, transcriptPath: "/tmp/rollout", cumulativeInput: input,
            cumulativeCached: 0, cumulativeOutput: 0, cumulativeWrites: writes), observedAt: Date())
        #expect(store.sessions["s"]?.codexUsageTotals?.writes == writes)
    }
    #expect(abs((store.sessions["s"]?.totalCostUSD ?? -1) - (2600 * 2e-6 + 400 * 2.5e-6)) < 1e-10)
}
