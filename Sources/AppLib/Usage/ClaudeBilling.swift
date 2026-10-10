import Foundation

/// Response-weighted units keep mixed speeds and cache lifetimes correct after
/// aggregation. Claude input counts are disjoint from cache reads and writes.
public struct ClaudeBillingUnits: Sendable, Equatable {
    var input = 0.0
    var output = 0.0
    var cached = 0.0
    var writes5m = 0.0
    var writes1h = 0.0

    static func estimate(input: Int, output: Int, cached: Int, writes: Int,
                         writes1h: Int = 0, model: String, speed: String? = nil) -> Self {
        let canonical = PricingTable.stripDateSuffix(model)
        let supportsFast = ["claude-opus-5-5", "claude-opus-5", "claude-opus-4-8"].contains(canonical)
        let scale = supportsFast && speed == "fast" ? 2.0 : 1.0
        let total = UsageTracker.clampTokens(writes)
        let hour = min(total, UsageTracker.clampTokens(writes1h))
        return Self(input: Double(UsageTracker.clampTokens(input)) * scale,
                    output: Double(UsageTracker.clampTokens(output)) * scale,
                    cached: Double(UsageTracker.clampTokens(cached)) * scale,
                    writes5m: Double(total - hour) * scale, writes1h: Double(hour) * scale)
    }

    static func legacy(_ tally: ModelTokenTally, model: String) -> Self {
        estimate(input: tally.input, output: tally.output, cached: tally.cacheRead,
                 writes: tally.cacheCreate, model: model)
    }

    func cost(using price: ModelPrice) -> Double {
        input * price.inputPerToken + output * price.outputPerToken
            + cached * price.cacheReadPerToken + writes5m * price.cacheCreatePerToken
            + writes1h * (price.cacheCreate1hPerToken ?? price.cacheCreatePerToken)
    }

    static func + (lhs: Self, rhs: Self) -> Self {
        Self(input: lhs.input + rhs.input, output: lhs.output + rhs.output,
             cached: lhs.cached + rhs.cached, writes5m: lhs.writes5m + rhs.writes5m,
             writes1h: lhs.writes1h + rhs.writes1h)
    }
}
