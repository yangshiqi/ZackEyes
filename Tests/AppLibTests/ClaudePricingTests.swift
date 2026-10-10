import Foundation
import Testing
@testable import AppLib

struct ClaudePricingTests {
    static func bundled() throws -> PricingTable {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try PricingTable(data: Data(contentsOf: root.appendingPathComponent("Resources/pricing.json")))
    }

    @Test func exactCurrentModelRatesAndDates() throws {
        let table = try Self.bundled()
        for (model, input, output, read) in [
            ("claude-fable-5", 10.0, 50.0, 1.0),
            ("claude-fable-5-1", 10.0, 50.0, 0.25),
            ("claude-opus-5-5", 4.0, 20.0, 0.2),
            ("claude-opus-5", 5.0, 25.0, 0.5),
            ("claude-opus-4-8", 5.0, 25.0, 0.5),
            ("claude-opus-4-7", 5.0, 25.0, 0.5),
            ("claude-sonnet-5", 2.0, 10.0, 0.2),
            ("claude-sonnet-5-5", 2.0, 10.0, 0.1)
        ] {
            let price = try #require(table.price(for: model))
            #expect(price.inputPerToken == input / 1_000_000)
            #expect(price.outputPerToken == output / 1_000_000)
            #expect(price.cacheReadPerToken == read / 1_000_000)
            #expect(table.price(for: model + "-20261001") == price)
        }
        #expect(table.price(for: "Opus 5.5") == nil)
        #expect(table.price(for: "claude-haiku-5-5") == nil)
        #expect(table.price(for: "claude-fable-5-2") == nil)
    }
}
