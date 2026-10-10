import Foundation

/// Display-only formatting of an observed raw ID; never used for pricing lookup.
enum ClaudeModelMetadata {
    static func displayName(for model: String) -> String {
        let parts = PricingTable.stripDateSuffix(model).split(separator: "-")
        let families = ["fable": "Fable", "opus": "Opus", "sonnet": "Sonnet", "haiku": "Haiku"]
        guard (3...4).contains(parts.count), parts[0] == "claude",
              let family = families[String(parts[1])],
              parts.dropFirst(2).allSatisfy({ Int($0) != nil }) else { return model }
        return family + " " + parts.dropFirst(2).joined(separator: ".")
    }
}
