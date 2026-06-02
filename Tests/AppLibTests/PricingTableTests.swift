import Testing
import Foundation
@testable import AppLib

struct PricingTableTests {
    static let json = """
    {
      "version": "2026-06-02",
      "models": {
        "claude-opus-4-8":  { "input": 1.5e-5, "output": 7.5e-5, "cache_read": 1.5e-6, "cache_creation": 1.875e-5 },
        "claude-haiku-4-5": { "input": 1.0e-6, "output": 5.0e-6, "cache_read": 1.0e-7, "cache_creation": 1.25e-6 },
        "gpt-5.5":          { "input": 1.25e-6, "output": 1.0e-5, "cache_read": 1.25e-7, "cache_creation": 0 }
      },
      "aliases": { "claude-opus-latest": "claude-opus-4-8" }
    }
    """.data(using: .utf8)!

    @Test func parsesVersionAndExactLookup() throws {
        let t = try PricingTable(data: Self.json)
        #expect(t.version == "2026-06-02")
        let p = t.price(for: "claude-opus-4-8")
        #expect(p?.inputPerToken == 1.5e-5)
        #expect(p?.outputPerToken == 7.5e-5)
        #expect(p?.cacheReadPerToken == 1.5e-6)
        #expect(p?.cacheCreatePerToken == 1.875e-5)
    }

    @Test func dateSuffixStripped() throws {
        let t = try PricingTable(data: Self.json)
        #expect(t.price(for: "claude-haiku-4-5-20251001")?.inputPerToken == 1.0e-6)
    }

    @Test func aliasLookup() throws {
        let t = try PricingTable(data: Self.json)
        #expect(t.price(for: "claude-opus-latest")?.inputPerToken == 1.5e-5)
    }

    @Test func missingModelIsNil() throws {
        let t = try PricingTable(data: Self.json)
        #expect(t.price(for: "totally-unknown-model") == nil)
    }

    @Test func displayNameIsNil() throws {
        // Model-ID contract: display names must NOT resolve to a price.
        let t = try PricingTable(data: Self.json)
        #expect(t.price(for: "Opus 4.8") == nil)
    }

    @Test func stripDateSuffixHandlesBothFormsAndLeavesNonDates() {
        // 8-digit YYYYMMDD form
        #expect(PricingTable.stripDateSuffix("claude-haiku-4-5-20251001") == "claude-haiku-4-5")
        // dashed YYYY-MM-DD form
        #expect(PricingTable.stripDateSuffix("claude-haiku-4-5-2025-10-01") == "claude-haiku-4-5")
        // non-date trailing segments must NOT be stripped
        #expect(PricingTable.stripDateSuffix("claude-opus-4-8") == "claude-opus-4-8")
        #expect(PricingTable.stripDateSuffix("gpt-5.5") == "gpt-5.5")
    }

    @Test func malformedThrows() {
        #expect(throws: (any Error).self) {
            _ = try PricingTable(data: Data("{not json".utf8))
        }
    }

    @Test func emptyModelsParses() throws {
        let t = try PricingTable(data: Data(#"{"models":{}}"#.utf8))
        #expect(t.version == "")
        #expect(t.price(for: "claude-opus-4-8") == nil)
    }

    @Test func bundledResourceFileParsesAndHasCoreModels() throws {
        // Locate Resources/pricing.json relative to this test file (repo root
        // is three dirs up from Tests/AppLibTests/).
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // AppLibTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
        let url = repoRoot.appendingPathComponent("Resources/pricing.json")
        let data = try Data(contentsOf: url)
        let table = try PricingTable(data: data)
        #expect(!table.version.isEmpty)
        #expect(table.price(for: "claude-opus-4-8") != nil)
        #expect(table.price(for: "gpt-5.5") != nil)
    }
}
