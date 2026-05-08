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

    func testSiliconNamesCount() {
        XCTAssertEqual(BuddyTheme.silicon.names.count, 34)
    }

    func testSiliconNamesIncludeKnownMoguls() {
        let names = BuddyTheme.silicon.names
        XCTAssertTrue(names.contains("🇺🇸 Sam from OpenAI"))
        XCTAssertTrue(names.contains("🇮🇹 Dario from Anthropic"))
        XCTAssertTrue(names.contains("🇹🇼 Jensen from Nvidia"))
        XCTAssertTrue(names.contains("🇨🇳 文锋 from DeepSeek"))
        XCTAssertTrue(names.contains("🇨🇳 植麟 from Moonshot"))
    }

    func testSiliconNamesNoJackMa() {
        let names = BuddyTheme.silicon.names
        XCTAssertFalse(names.contains(where: { $0.contains("Jack from Alibaba") }))
    }
}
