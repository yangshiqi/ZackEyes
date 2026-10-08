import Foundation

/// Codex reports inclusive input: cached reads and writes are subsets.
public struct CodexUsageTotals: Sendable, Equatable {
    public var input: Int
    public var cached: Int
    public var writes: Int
    public var output: Int

    public init(input: Int, cached: Int = 0, writes: Int = 0, output: Int) {
        self.input = max(0, min(input, 1_000_000_000))
        self.cached = max(0, min(cached, self.input))
        self.writes = max(0, min(writes, self.input - self.cached))
        self.output = max(0, min(output, 1_000_000_000))
    }

    func delta(from previous: Self?) -> Self {
        Self(input: max(0, input - (previous?.input ?? 0)),
             cached: max(0, cached - (previous?.cached ?? 0)),
             writes: max(0, writes - (previous?.writes ?? 0)),
             output: max(0, output - (previous?.output ?? 0)))
    }
}

/// Weighted billable units preserve request multipliers without retaining
/// individual requests or changing the raw token counts displayed in the UI.
public struct CodexBillingUnits: Sendable, Equatable {
    var input = 0.0
    var cached = 0.0
    var writes = 0.0
    var output = 0.0

    static func estimate(_ usage: CodexUsageTotals, model: String, tier: String?, request: CodexUsageTotals?) -> Self {
        let isGPT6 = model == "gpt-6.1-sol" || model.hasPrefix("gpt-6.1-sol-20")
            || model == "gpt-6-astra" || model.hasPrefix("gpt-6-astra-20")
        var scale = 1.0
        if isGPT6 {
            switch tier?.lowercased() {
            case "fast", "priority": scale = 2
            case "ultrafast": scale = 6
            case "flex", "batch": scale = 0.5
            default: break
            }
        }
        // A cumulative gap may cover several requests. Apply the threshold
        // only when the last-request components agree with the observed delta.
        let long = isGPT6 && request == usage && usage.input > 272_000
        let inputScale = scale * (long ? 2 : 1)
        return Self(input: Double(max(0, usage.input - usage.cached - usage.writes)) * inputScale,
                    cached: Double(usage.cached) * inputScale,
                    writes: Double(usage.writes) * inputScale,
                    output: Double(usage.output) * scale * (long ? 1.5 : 1))
    }

    func cost(using price: ModelPrice) -> Double {
        input * price.inputPerToken + cached * price.cacheReadPerToken
            + writes * price.cacheCreatePerToken + output * price.outputPerToken
    }

    static func + (lhs: Self, rhs: Self) -> Self {
        Self(input: lhs.input + rhs.input, cached: lhs.cached + rhs.cached,
             writes: lhs.writes + rhs.writes, output: lhs.output + rhs.output)
    }
}
