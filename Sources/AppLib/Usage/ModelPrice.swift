import Foundation

/// Per-token USD unit prices for one model (LiteLLM convention, e.g. `1.5e-5`).
/// `cacheCreatePerToken` is 0 for providers (Codex) with no cache-creation cost.
public struct ModelPrice: Sendable, Equatable, Codable {
    public let inputPerToken: Double
    public let outputPerToken: Double
    public let cacheReadPerToken: Double
    public let cacheCreatePerToken: Double

    public init(inputPerToken: Double, outputPerToken: Double,
                cacheReadPerToken: Double, cacheCreatePerToken: Double) {
        self.inputPerToken = inputPerToken
        self.outputPerToken = outputPerToken
        self.cacheReadPerToken = cacheReadPerToken
        self.cacheCreatePerToken = cacheCreatePerToken
    }
}
