import XCTest
@testable import AppLib

final class UpdateCheckerTests: XCTestCase {

    // MARK: - Version comparison

    func testNewerMajor() {
        XCTAssertTrue(UpdateChecker.isNewer(remote: "1.0.0", thanLocal: "0.1.0"))
    }

    func testNewerMinor() {
        XCTAssertTrue(UpdateChecker.isNewer(remote: "0.2.0", thanLocal: "0.1.0"))
    }

    func testNewerPatch() {
        XCTAssertTrue(UpdateChecker.isNewer(remote: "0.1.1", thanLocal: "0.1.0"))
    }

    func testSameVersion() {
        XCTAssertFalse(UpdateChecker.isNewer(remote: "0.1.0", thanLocal: "0.1.0"))
    }

    func testOlderVersion() {
        XCTAssertFalse(UpdateChecker.isNewer(remote: "0.0.9", thanLocal: "0.1.0"))
    }

    func testStripsVPrefix() {
        XCTAssertTrue(UpdateChecker.isNewer(remote: "v0.2.0", thanLocal: "0.1.0"))
    }

    func testMalformedRemoteReturnsFalse() {
        XCTAssertFalse(UpdateChecker.isNewer(remote: "not-a-version", thanLocal: "0.1.0"))
    }

    func testMalformedLocalReturnsFalse() {
        XCTAssertFalse(UpdateChecker.isNewer(remote: "0.2.0", thanLocal: "bad"))
    }

    func testTwoComponentVersion() {
        XCTAssertTrue(UpdateChecker.isNewer(remote: "0.2", thanLocal: "0.1.0"))
    }

    // MARK: - GitHub JSON parsing

    func testParseReleaseJSON() throws {
        let json = """
        {
            "tag_name": "v0.2.0",
            "html_url": "https://github.com/yangshiqi/ZackEyes/releases/tag/v0.2.0"
        }
        """.data(using: .utf8)!

        let release = try JSONDecoder().decode(GitHubRelease.self, from: json)
        XCTAssertEqual(release.tagName, "v0.2.0")
        XCTAssertEqual(release.htmlURL.absoluteString, "https://github.com/yangshiqi/ZackEyes/releases/tag/v0.2.0")
    }

    func testParseReleaseIgnoresExtraFields() throws {
        let json = """
        {
            "tag_name": "v0.3.0",
            "html_url": "https://github.com/yangshiqi/ZackEyes/releases/tag/v0.3.0",
            "name": "Release 0.3.0",
            "draft": false,
            "prerelease": false,
            "body": "changelog here"
        }
        """.data(using: .utf8)!

        let release = try JSONDecoder().decode(GitHubRelease.self, from: json)
        XCTAssertEqual(release.tagName, "v0.3.0")
    }
}
