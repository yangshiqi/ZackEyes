import XCTest
@testable import BridgeLib

final class TerminalTitleWriterTests: XCTestCase {

    // MARK: sanitizePrompt

    func test_sanitizePrompt_stripsControlChars() {
        XCTAssertEqual(
            TerminalTitleWriter.sanitizePrompt("hello\u{001B}]2;evil\u{0007}world"),
            "hello]2;evilworld"
        )
    }

    func test_sanitizePrompt_replacesNewlinesAndTabsWithSpace() {
        XCTAssertEqual(
            TerminalTitleWriter.sanitizePrompt("line1\nline2\tend\rmore"),
            "line1 line2 end more"
        )
    }

    func test_sanitizePrompt_keepsUnicodeText() {
        XCTAssertEqual(
            TerminalTitleWriter.sanitizePrompt("弹出层中的 session，跳转"),
            "弹出层中的 session，跳转"
        )
    }

    // MARK: C1 controls (T-3 hardening)

    func test_sanitizePrompt_stripsC1Controls() {
        // C1 controls (U+0080–U+009F, e.g. ST/CSI) are now dropped too.
        XCTAssertEqual(TerminalTitleWriter.sanitizePrompt("a\u{009C}b\u{0080}c"), "abc")
    }

    // MARK: oscEscape sanitizes the whole title (T-3: cwd basename can't inject)

    func test_oscEscape_sanitizesWholeTitle_basenameCannotInject() {
        // formatTitle interpolates the cwd basename raw; oscEscape must sanitize
        // the whole composed title at the boundary so an ESC/BEL-bearing dir name
        // cannot smuggle a follow-on escape (e.g. OSC 52 clipboard write).
        let title = TerminalTitleWriter.formatTitle(
            cwd: "/tmp/proj\u{0007}\u{001B}]52;c;evil",
            sessionId: "abcd1234",
            prompt: nil
        )
        let osc = TerminalTitleWriter.oscEscape(title: title)
        XCTAssertTrue(osc.hasPrefix("\u{001B}]2;"))
        XCTAssertTrue(osc.hasSuffix("\u{0007}"))
        let inner = String(osc.dropFirst(4).dropLast())
        XCTAssertFalse(
            inner.unicodeScalars.contains { $0.value == 0x1B || $0.value == 0x07 },
            "no ESC/BEL may survive inside the OSC title"
        )
    }

    // MARK: TitleCache session_id validation (#126 path traversal)

    func test_isSafeSessionId() {
        XCTAssertTrue(TitleCache.isSafeSessionId("a1b2-c3d4_EF"))
        XCTAssertFalse(TitleCache.isSafeSessionId("../x"))
        XCTAssertFalse(TitleCache.isSafeSessionId("a/b"))
        XCTAssertFalse(TitleCache.isSafeSessionId("a.b"))
        XCTAssertFalse(TitleCache.isSafeSessionId(""))
    }

    func test_titleCache_rejectsPathTraversalSessionId() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let cache = TitleCache(directory: tmp.appendingPathComponent("osc2").path)

        // A traversal session_id is a no-op: nothing written, read returns nil.
        cache.writeIfMissing(sessionId: "../escaped", content: "secret")
        XCTAssertNil(cache.read(sessionId: "../escaped"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("escaped").path))

        // A normal slug still round-trips.
        cache.writeIfMissing(sessionId: "abc-123_DEF", content: "ok")
        XCTAssertEqual(cache.read(sessionId: "abc-123_DEF"), "ok")
    }

    // MARK: truncateToChars

    func test_truncateToChars_shortPassesThrough() {
        XCTAssertEqual(TerminalTitleWriter.truncateToChars("abc", max: 30), "abc")
    }

    func test_truncateToChars_truncatesByCharacterCount() {
        // 40 ASCII chars, max 30 → first 30 chars kept
        let input = String(repeating: "x", count: 40)
        XCTAssertEqual(TerminalTitleWriter.truncateToChars(input, max: 30).count, 30)
    }

    func test_truncateToChars_truncatesCJKByCharacter() {
        // 15 CJK chars. Limit 10 chars → 10 characters.
        let input = "弹出层中的 session 跳转到对应"  // 15 characters
        let result = TerminalTitleWriter.truncateToChars(input, max: 10)
        XCTAssertEqual(result.count, 10)
    }

    // MARK: formatTitle

    func test_formatTitle_withPrompt_producesFullFormat() {
        let title = TerminalTitleWriter.formatTitle(
            cwd: "/Users/ysq/Work/lab/ccisland",
            sessionId: "3e0a4419-cf88-4389-b37e-d1482a9a7d94",
            prompt: "弹出层中的 session，点击跳转"
        )
        XCTAssertEqual(title, "ccisland · 弹出层中的 session，点击跳转 · ze:3e0a4419")
    }

    func test_formatTitle_withoutPrompt_producesShortFormat() {
        let title = TerminalTitleWriter.formatTitle(
            cwd: "/Users/ysq/Work/lab/ccisland",
            sessionId: "3e0a4419-cf88-4389-b37e-d1482a9a7d94",
            prompt: nil
        )
        XCTAssertEqual(title, "ccisland · ze:3e0a4419")
    }

    func test_formatTitle_withEmptyPrompt_usesShortFormat() {
        let title = TerminalTitleWriter.formatTitle(
            cwd: "/tmp",
            sessionId: "abcdefgh-1234-5678-9abc-def012345678",
            prompt: ""
        )
        XCTAssertEqual(title, "tmp · ze:abcdefgh")
    }

    func test_formatTitle_promptWithNewlines_replaceWithSpaces() {
        let title = TerminalTitleWriter.formatTitle(
            cwd: "/tmp/foo",
            sessionId: "11111111-2222-3333-4444-555555555555",
            prompt: "line1\nline2"
        )
        XCTAssertEqual(title, "foo · line1 line2 · ze:11111111")
    }

    func test_formatTitle_longPrompt_truncatedTo30Chars() {
        let longPrompt = String(repeating: "a", count: 50)
        let title = TerminalTitleWriter.formatTitle(
            cwd: "/tmp/foo",
            sessionId: "11111111-2222-3333-4444-555555555555",
            prompt: longPrompt
        )
        XCTAssertEqual(title, "foo · \(String(repeating: "a", count: 30)) · ze:11111111")
    }

    // MARK: oscEscape

    func test_oscEscape_wrapsWithEsc2AndBel() {
        let osc = TerminalTitleWriter.oscEscape(title: "hello")
        XCTAssertEqual(osc, "\u{001B}]2;hello\u{0007}")
    }

    func test_oscEscape_unicodeIsPreserved() {
        let osc = TerminalTitleWriter.oscEscape(title: "ccisland · ze:3e0a4419")
        XCTAssertEqual(osc, "\u{001B}]2;ccisland · ze:3e0a4419\u{0007}")
    }
}

// MARK: - TitleCache

final class TitleCacheTests: XCTestCase {
    var tmpDir: URL!

    override func setUp() {
        super.setUp()
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("zackeyes-titlecache-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        super.tearDown()
    }

    func test_read_missingFile_returnsNil() {
        let cache = TitleCache(directory: tmpDir.path)
        XCTAssertNil(cache.read(sessionId: "3e0a4419-cf88-4389-b37e-d1482a9a7d94"))
    }

    func test_writeIfMissing_thenRead_roundTrips() {
        let cache = TitleCache(directory: tmpDir.path)
        let sid = "3e0a4419-cf88-4389-b37e-d1482a9a7d94"
        cache.writeIfMissing(sessionId: sid, content: "first prompt")
        XCTAssertEqual(cache.read(sessionId: sid), "first prompt")
    }

    func test_writeIfMissing_secondCallIsNoOp() {
        let cache = TitleCache(directory: tmpDir.path)
        let sid = "3e0a4419-cf88-4389-b37e-d1482a9a7d94"
        cache.writeIfMissing(sessionId: sid, content: "first")
        cache.writeIfMissing(sessionId: sid, content: "second")
        XCTAssertEqual(cache.read(sessionId: sid), "first")
    }

    func test_filename_uses16CharSidPrefix() {
        let cache = TitleCache(directory: tmpDir.path)
        let sid = "3e0a4419-cf88-4389-b37e-d1482a9a7d94"
        cache.writeIfMissing(sessionId: sid, content: "x")
        // filename should be the first 16 chars of the UUID: "3e0a4419-cf88-43"
        let expected16 = tmpDir.appendingPathComponent("3e0a4419-cf88-43").path
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: expected16),
            "expected cache file at \(expected16)"
        )
    }

    func test_createsDirectoryIfMissing() {
        let nested = tmpDir.appendingPathComponent("subdir/deeper")
        let cache = TitleCache(directory: nested.path)
        cache.writeIfMissing(sessionId: "abcdefgh-1111-2222-3333-444444444444", content: "x")
        XCTAssertEqual(cache.read(sessionId: "abcdefgh-1111-2222-3333-444444444444"), "x")
    }
}
