import XCTest
@testable import Shared

final class TTYUtilTests: XCTestCase {
    func test_parseTTYOutput_plainName_prependsDev() {
        XCTAssertEqual(TTYUtil.parseTTYOutput("ttys003"), "/dev/ttys003")
    }

    func test_parseTTYOutput_withTrailingNewline_isTrimmed() {
        XCTAssertEqual(TTYUtil.parseTTYOutput("ttys003\n"), "/dev/ttys003")
    }

    func test_parseTTYOutput_alreadyAbsolute_isKept() {
        XCTAssertEqual(TTYUtil.parseTTYOutput("/dev/ttys012"), "/dev/ttys012")
    }

    func test_parseTTYOutput_questionMark_returnsNil() {
        XCTAssertNil(TTYUtil.parseTTYOutput("?"))
    }

    func test_parseTTYOutput_empty_returnsNil() {
        XCTAssertNil(TTYUtil.parseTTYOutput(""))
    }

    func test_parseTTYOutput_whitespaceOnly_returnsNil() {
        XCTAssertNil(TTYUtil.parseTTYOutput("   \n  "))
    }

    // #204 — a process with no controlling terminal prints `??` on macOS
    // (verified against `ps -p 1 -o tty=`), which the old `!= "?"` guard let
    // through as `/dev/??`.
    func test_parseTTYOutput_doubleQuestionMark_returnsNil() {
        XCTAssertNil(TTYUtil.parseTTYOutput("??"))
        XCTAssertNil(TTYUtil.parseTTYOutput("??      \n"))
    }

    // Only real pty slave names survive: the value is interpolated into
    // AppleScript source by TerminalLocator.
    func test_parseTTYOutput_rejectsNonPtyNames() {
        XCTAssertNil(TTYUtil.parseTTYOutput("console"))
        XCTAssertNil(TTYUtil.parseTTYOutput("ttys003; do shell script \"boom\""))
        XCTAssertNil(TTYUtil.parseTTYOutput("../../etc/passwd"))
    }

    func test_parseTTYOutput_acceptsPtsForm() {
        XCTAssertEqual(TTYUtil.parseTTYOutput("pts/4"), "/dev/pts/4")
    }
}
