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

    func testSiliconTaglinesCount() {
        XCTAssertEqual(BuddyTheme.silicon.taglines.count, 29)
    }

    func testSiliconTaglinesIncludeKnownMemes() {
        let taglines = BuddyTheme.silicon.taglines
        XCTAssertTrue(taglines.contains("AGI is coming"))
        XCTAssertTrue(taglines.contains("Race to the top"))
        XCTAssertTrue(taglines.contains("The bitter lesson"))
        XCTAssertTrue(taglines.contains("源神，启动！"))
        XCTAssertTrue(taglines.contains("把成本打下来"))
    }

    func testSiliconTaglinesNo996() {
        XCTAssertFalse(BuddyTheme.silicon.taglines.contains("996 是福报"))
    }

    func testSiliconSoundsCount() {
        XCTAssertEqual(BuddyTheme.silicon.availableSounds.count, 7)
    }

    func testSiliconHasNoneSentinel() {
        let files = BuddyTheme.silicon.availableSounds.map(\.file)
        XCTAssertTrue(files.contains("none"))
    }

    func testSiliconDefaultSound() {
        XCTAssertEqual(BuddyTheme.silicon.defaultSoundFile, "agi-altman")
    }

    func testSiliconSoundFilenamesUnique() {
        let files = BuddyTheme.silicon.availableSounds.map(\.file)
        XCTAssertEqual(files.count, Set(files).count, "duplicate sound filenames")
    }

    func testSiliconCodableRoundTrip() throws {
        let encoded = try JSONEncoder().encode(BuddyTheme.silicon)
        let decoded = try JSONDecoder().decode(BuddyTheme.self, from: encoded)
        XCTAssertEqual(decoded, .silicon)
    }

    func testBuddyAssignmentIsDeterministic() {
        let a = Buddy.from(sessionId: "fixed-session-id", theme: .silicon)
        let b = Buddy.from(sessionId: "fixed-session-id", theme: .silicon)
        XCTAssertEqual(a.name, b.name)
        XCTAssertEqual(a.tagline, b.tagline)
        XCTAssertTrue(BuddyTheme.silicon.names.contains(a.name))
        XCTAssertTrue(BuddyTheme.silicon.taglines.contains(a.tagline))
    }
}
