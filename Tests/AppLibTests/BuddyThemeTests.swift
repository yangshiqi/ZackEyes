import XCTest
@testable import AppLib

final class BuddyThemeTests: XCTestCase {

    func testSiliconCaseExists() {
        XCTAssertTrue(BuddyTheme.allCases.contains(.silicon))
    }

    func testSiliconDisplayName() {
        XCTAssertEqual(BuddyTheme.silicon.displayName, "AI 大佬")
    }

    func testAllCasesCount() {
        XCTAssertEqual(BuddyTheme.allCases.count, 3)
    }
}
