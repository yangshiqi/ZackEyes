import Testing
import Foundation
@testable import AppLib

@MainActor
struct PricingStoreTests {
    private static func tmpCacheURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("pricing-cache.json")
    }

    private nonisolated static func json(version: String, opusInput: Double) -> Data {
        """
        {"version":"\(version)","models":{"claude-opus-4-8":{"input":\(opusInput),"output":1,"cache_read":1,"cache_creation":1}}}
        """.data(using: .utf8)!
    }

    @Test func loadPrefersHigherVersionCacheOverBundled() throws {
        let cache = Self.tmpCacheURL()
        try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.json(version: "2026-06-02", opusInput: 2e-5).write(to: cache)
        let store = PricingStore(
            cacheURL: cache,
            bundledData: { Self.json(version: "2026-01-01", opusInput: 9e-9) },
            fetch: { nil }
        )
        store.loadInitial()
        #expect(store.price(for: "claude-opus-4-8")?.inputPerToken == 2e-5)
    }

    @Test func loadPrefersHigherVersionBundledAfterUpdate() throws {
        let cache = Self.tmpCacheURL()
        try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.json(version: "2026-01-01", opusInput: 9e-9).write(to: cache)
        let store = PricingStore(
            cacheURL: cache,
            bundledData: { Self.json(version: "2026-06-02", opusInput: 2e-5) },
            fetch: { nil }
        )
        store.loadInitial()
        #expect(store.price(for: "claude-opus-4-8")?.inputPerToken == 2e-5)
    }

    @Test func corruptCacheFallsBackToBundled() throws {
        let cache = Self.tmpCacheURL()
        try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: cache)
        let store = PricingStore(
            cacheURL: cache,
            bundledData: { Self.json(version: "2026-06-02", opusInput: 2e-5) },
            fetch: { nil }
        )
        store.loadInitial()
        #expect(store.price(for: "claude-opus-4-8")?.inputPerToken == 2e-5)
    }

    @Test func missingBothGivesEmptyTable() {
        let store = PricingStore(cacheURL: Self.tmpCacheURL(), bundledData: { nil }, fetch: { nil })
        store.loadInitial()
        #expect(store.price(for: "claude-opus-4-8") == nil)
    }

    @Test func refreshSwapsOnNewerVersionAndWritesCache() async {
        let cache = Self.tmpCacheURL()
        let store = PricingStore(
            cacheURL: cache,
            bundledData: { Self.json(version: "2026-01-01", opusInput: 1e-9) },
            fetch: { Self.json(version: "2026-06-02", opusInput: 2e-5) }
        )
        store.loadInitial()
        await store.refresh()
        #expect(store.price(for: "claude-opus-4-8")?.inputPerToken == 2e-5)
        #expect(FileManager.default.fileExists(atPath: cache.path))
    }

    @Test func refreshIgnoresOlderVersion() async {
        let store = PricingStore(
            cacheURL: Self.tmpCacheURL(),
            bundledData: { Self.json(version: "2026-06-02", opusInput: 2e-5) },
            fetch: { Self.json(version: "2025-01-01", opusInput: 9e-9) }
        )
        store.loadInitial()
        await store.refresh()
        #expect(store.price(for: "claude-opus-4-8")?.inputPerToken == 2e-5)
    }

    @Test func refreshIgnoresNilFetch() async {
        let store = PricingStore(
            cacheURL: Self.tmpCacheURL(),
            bundledData: { Self.json(version: "2026-06-02", opusInput: 2e-5) },
            fetch: { nil }
        )
        store.loadInitial()
        await store.refresh()
        #expect(store.price(for: "claude-opus-4-8")?.inputPerToken == 2e-5)
    }
}
