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
        // Pre-place a fake DMG in an injected download dir so download() takes
        // the cache-hit path. (Production's dir is per-launch + unpredictable,
        // #129/F-017 — so the test injects one it controls.)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZackEyesTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = URL(string: "https://example.com/path/ZackEyes-test-cache.dmg")!
        let cached = dir.appendingPathComponent(url.lastPathComponent)
        try Self.fakeDMGData().write(to: cached)

        let d = UpdateDownloader(opener: { _ in /* swallow open */ }, downloadDir: dir)
        await d.download(from: url)

        if case .ready(let path) = d.state {
            XCTAssertEqual(path, cached)
        } else {
            XCTFail("expected .ready, got \(d.state)")
        }
    }

    // #121 — 512-byte fixture carrying the UDIF `koly` trailer so it passes the
    // disk-image content check.
    private static func fakeDMGData() -> Data {
        var d = Data([0x6B, 0x6F, 0x6C, 0x79])   // "koly"
        d.append(Data(count: 512 - d.count))
        return d
    }

    func testRejectsNonDMGContentOnCacheHit() async throws {
        // A 200-but-wrong-content artifact (a CDN error page, truncated file)
        // sitting at the download path must NOT be handed to Finder (#121).
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZackEyesTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = URL(string: "https://example.com/path/ZackEyes-test-cache.dmg")!
        let cached = dir.appendingPathComponent(url.lastPathComponent)
        try Data("<html>404 Not Found</html>".utf8).write(to: cached)

        var opened = false
        let d = UpdateDownloader(opener: { _ in opened = true }, downloadDir: dir)
        await d.download(from: url)

        XCTAssertFalse(opened, "non-DMG content must not be opened")
        if case .failed = d.state {} else { XCTFail("expected .failed, got \(d.state)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: cached.path),
                       "rejected file should be removed")
    }

    func testLooksLikeDMG() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZackEyesTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let good = dir.appendingPathComponent("good.dmg")
        try Self.fakeDMGData().write(to: good)
        XCTAssertTrue(UpdateDownloader.looksLikeDMG(good))

        let bad = dir.appendingPathComponent("bad.dmg")
        try Data(repeating: 0x41, count: 600).write(to: bad)   // ≥512B but no koly trailer
        XCTAssertFalse(UpdateDownloader.looksLikeDMG(bad))

        let short = dir.appendingPathComponent("short.dmg")
        try Data(repeating: 0, count: 100).write(to: short)    // < 512 bytes
        XCTAssertFalse(UpdateDownloader.looksLikeDMG(short))
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
