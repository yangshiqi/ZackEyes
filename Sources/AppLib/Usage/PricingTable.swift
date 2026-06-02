import Foundation

/// Pure model→price lookup parsed from a curated `pricing.json`.
/// No Bundle, no network — fully unit-testable with inline `Data`.
public struct PricingTable: Sendable {
    /// `pricing.json` `version` (ISO date string, e.g. "2026-06-02"); "" if
    /// absent. Used by `PricingStore` for monotonic version-gated selection.
    /// Compared lexicographically as a String — for well-formed ISO-8601 dates
    /// this equals chronological order, and "" (empty/absent) sorts lowest by
    /// design. Do NOT replace with Date parsing.
    public let version: String
    private let models: [String: ModelPrice]
    private let aliases: [String: String]

    /// Empty table — every lookup returns nil; version sorts lowest.
    public static let empty = PricingTable(version: "", models: [:], aliases: [:])

    init(version: String, models: [String: ModelPrice], aliases: [String: String]) {
        self.version = version
        self.models = models
        self.aliases = aliases
    }

    /// Parse a curated pricing.json. Throws on malformed JSON so callers can
    /// keep a previously-loaded table instead of swapping in garbage.
    public init(data: Data) throws {
        let dto = try JSONDecoder().decode(PricingFile.self, from: data)
        self.version = dto.version ?? ""
        self.models = dto.models.mapValues {
            ModelPrice(inputPerToken: $0.input, outputPerToken: $0.output,
                       cacheReadPerToken: $0.cache_read, cacheCreatePerToken: $0.cache_creation)
        }
        self.aliases = dto.aliases ?? [:]
    }

    /// Look up by RAW provider model id (e.g. "claude-opus-4-8", "gpt-5.5").
    /// Display names are not valid keys and return nil.
    /// Order: exact → date-suffix-stripped → alias → nil.
    public func price(for model: String) -> ModelPrice? {
        if let p = models[model] { return p }
        let stripped = Self.stripDateSuffix(model)
        if stripped != model, let p = models[stripped] { return p }
        // Alias keys are canonical raw IDs (no date suffix); date-stripping is
        // intentionally not re-applied to the alias lookup.
        if let canonical = aliases[model], let p = models[canonical] { return p }
        return nil
    }

    /// Drop a trailing `-YYYY-MM-DD` or `-YYYYMMDD` date stamp if present.
    static func stripDateSuffix(_ model: String) -> String {
        if let r = model.range(of: "-[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) {
            return String(model[..<r.lowerBound])
        }
        if let r = model.range(of: "-[0-9]{8}$", options: .regularExpression) {
            return String(model[..<r.lowerBound])
        }
        return model
    }
}

/// Wire format for `pricing.json`. Private — only `PricingTable` decodes it.
private struct PricingFile: Decodable {
    let version: String?
    let models: [String: Entry]
    let aliases: [String: String]?
    struct Entry: Decodable {
        let input: Double
        let output: Double
        let cache_read: Double
        let cache_creation: Double

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            input          = try c.decode(Double.self, forKey: .input)
            output         = try c.decode(Double.self, forKey: .output)
            cache_read     = try c.decodeIfPresent(Double.self, forKey: .cache_read) ?? 0
            cache_creation = try c.decodeIfPresent(Double.self, forKey: .cache_creation) ?? 0
        }

        enum CodingKeys: String, CodingKey {
            case input, output, cache_read, cache_creation
        }
    }
}
