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
