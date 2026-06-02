import Foundation

/// Per-(day, agent, model) token tally. Raw counts as emitted by each agent.
public struct ModelTokenTally: Sendable, Equatable {
    public var input: Int
    public var output: Int
    public var cacheRead: Int
    public var cacheCreate: Int
    public init(input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheCreate: Int = 0) {
        self.input = input; self.output = output
        self.cacheRead = cacheRead; self.cacheCreate = cacheCreate
    }
}

/// One calendar day's consumption across both agents.
public struct DayUsage: Sendable, Codable, Equatable {
    public var dayStart: Date            // local startOfDay
    public var claudeTokens: Int
    public var codexTokens: Int
    public var claudeCostUSD: Double?    // nil = no priced Claude tokens that day
    public var codexCostUSD: Double?     // nil = no priced Codex tokens that day
    public var anyUnpriced: Bool         // some tokens lacked a price → combined cost is a floor (≥)
    public var totalTokens: Int { claudeTokens + codexTokens }

    public init(dayStart: Date, claudeTokens: Int = 0, codexTokens: Int = 0,
                claudeCostUSD: Double? = nil, codexCostUSD: Double? = nil, anyUnpriced: Bool = false) {
        self.dayStart = dayStart; self.claudeTokens = claudeTokens; self.codexTokens = codexTokens
        self.claudeCostUSD = claudeCostUSD; self.codexCostUSD = codexCostUSD; self.anyUnpriced = anyUnpriced
    }
}

extension UsageTracker {
    /// Sum `src` tallies into `dst` (per day, per model).
    nonisolated static func mergeTallies(
        _ dst: inout [Date: [String: ModelTokenTally]],
        _ src: [Date: [String: ModelTokenTally]]
    ) {
        for (day, models) in src {
            for (model, t) in models {
                var cur = dst[day]?[model] ?? ModelTokenTally()
                cur.input += t.input; cur.output += t.output
                cur.cacheRead += t.cacheRead; cur.cacheCreate += t.cacheCreate
                dst[day, default: [:]][model] = cur
            }
        }
    }

    /// Pure cost fold (nonisolated; called from `@MainActor refresh()`). Builds
    /// exactly 7 zero-filled local-day buckets ending at `now`'s local day,
    /// folds tokens and `PricingTable` cost. `*CostUSD` is nil only when EVERY model
    /// for that agent lacked a price entry; if ≥1 model was priced it holds the
    /// partial sum, and `anyUnpriced` then signals the total is a floor (≥ actual).
    nonisolated static func buildDailyUsage(
        claude: [Date: [String: ModelTokenTally]],
        codex: [Date: [String: ModelTokenTally]],
        pricing: PricingTable,
        calendar: Calendar,
        now: Date
    ) -> [DayUsage] {
        let today = calendar.startOfDay(for: now)
        let days: [Date] = (0..<7).reversed().compactMap {
            calendar.date(byAdding: .day, value: -$0, to: today)
        }
        return days.map { day in
            var u = DayUsage(dayStart: day)
            if let models = claude[day] {
                var cost = 0.0, priced = false
                for (model, t) in models {
                    u.claudeTokens += t.input + t.output + t.cacheRead + t.cacheCreate
                    if let p = pricing.price(for: model) {
                        cost += Double(t.input) * p.inputPerToken
                              + Double(t.output) * p.outputPerToken
                              + Double(t.cacheRead) * p.cacheReadPerToken
                              + Double(t.cacheCreate) * p.cacheCreatePerToken
                        priced = true
                    } else { u.anyUnpriced = true }
                }
                if priced { u.claudeCostUSD = cost }
            }
            if let models = codex[day] {
                var cost = 0.0, priced = false
                for (model, t) in models {
                    u.codexTokens += t.input + t.output    // cached is a subset of input
                    if let p = pricing.price(for: model) {
                        let uncached = max(0, t.input - t.cacheRead)
                        cost += Double(uncached) * p.inputPerToken
                              + Double(t.cacheRead) * p.cacheReadPerToken
                              + Double(t.output) * p.outputPerToken
                        priced = true
                    } else { u.anyUnpriced = true }
                }
                if priced { u.codexCostUSD = cost }
            }
            return u
        }
    }
}
