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

    func testMenuLabelIdle() {
        let (t, e) = StatusBarMenu.updateMenuLabel(version: "0.3.0", state: .idle)
        XCTAssertEqual(t, "Update Available (v0.3.0)")
        XCTAssertTrue(e)
    }

    func testMenuLabelDownloading() {
        let (t, e) = StatusBarMenu.updateMenuLabel(version: "0.3.0", state: .downloading)
        XCTAssertEqual(t, "Downloading v0.3.0…")
        XCTAssertFalse(e)
    }

    func testMenuLabelReady() {
        let (t, e) = StatusBarMenu.updateMenuLabel(
            version: "0.3.0",
            state: .ready(URL(fileURLWithPath: "/tmp/x.dmg"))
        )
        XCTAssertEqual(t, "Update Ready (v0.3.0) — Click to Open")
        XCTAssertTrue(e)
    }

    func testMenuLabelFailed() {
        let (t, e) = StatusBarMenu.updateMenuLabel(
            version: "0.3.0",
            state: .failed("network error")
        )
        XCTAssertEqual(t, "Update Failed — Click to Retry")
        XCTAssertTrue(e)
    }
}
