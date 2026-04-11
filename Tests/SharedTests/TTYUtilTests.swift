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
}
