import XCTest
@testable import AppLib

@MainActor
final class UpdateDownloaderTests: XCTestCase {

    func testInitialStateIsIdle() {
        let d = UpdateDownloader()
        XCTAssertEqual(d.state, .idle)
    }

    func testResetReturnsToIdle() {
        let d = UpdateDownloader()
        // Force state by simulating a failure first, then reset.
        d.simulateFailure(message: "test")
        XCTAssertEqual(d.state, .failed("test"))
        d.reset()
        XCTAssertEqual(d.state, .idle)
    }

    func testCacheHitTransitionsToReadyWithoutNetwork() async throws {
        // Pre-place a fake DMG in tmp so download() takes the cache-hit path.
        let url = URL(string: "https://example.com/path/ZackEyes-test-cache.dmg")!
        let cached = FileManager.default.temporaryDirectory
            .appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: cached)
        try Data("fake dmg".utf8).write(to: cached)
        defer { try? FileManager.default.removeItem(at: cached) }

        let d = UpdateDownloader(opener: { _ in /* swallow open */ })
        await d.download(from: url)

        if case .ready(let path) = d.state {
            XCTAssertEqual(path, cached)
        } else {
            XCTFail("expected .ready, got \(d.state)")
        }
    }
}
