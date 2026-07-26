import XCTest
@testable import AppLib

final class BuddyThemeTests: XCTestCase {

    func testSiliconCaseExists() {
        XCTAssertTrue(BuddyTheme.allCases.contains(.silicon))
    }

    func testSiliconDisplayName() {
        XCTAssertEqual(BuddyTheme.silicon.displayName, "AI Moguls")
    }

    func testAllCasesCount() {
        XCTAssertEqual(BuddyTheme.allCases.count, 4)
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

    func testOriginalSoundFilesRemainMappedToTheirThemes() {
        XCTAssertEqual(
            BuddyTheme.rock.availableSounds.map(\.file),
            ["ba-dum", "guitar-riff", "skull-guitar", "guitar-notif", "guitar-quick", "none"]
        )
        XCTAssertEqual(
            BuddyTheme.f1.availableSounds.map(\.file),
            [
                "box-box", "get-in-there", "for-what", "simply-lovely",
                "super-max", "team-radio", "f1-radio", "lights-out",
                "gp2-engine", "james-its-valtteri", "none",
            ]
        )
        XCTAssertEqual(
            BuddyTheme.silicon.availableSounds.map(\.file),
            [
                "agi-altman", "more-compute-jensen", "so-back", "tokens-karpathy",
                "race-to-the-top-dario", "move-fast-zuck", "none",
            ]
        )
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

    // MARK: - Shinchan theme

    func testShinchanCaseExists() {
        XCTAssertTrue(BuddyTheme.allCases.contains(.shinchan))
    }

    func testShinchanDisplayName() {
        XCTAssertEqual(BuddyTheme.shinchan.displayName, "Crayon Shin-chan")
    }

    /// Menu-visible strings (theme picker + sound picker) must be English.
    func testMenuLabelsAreEnglish() {
        let cjk = try! NSRegularExpression(pattern: "\\p{Han}")
        func hasHan(_ s: String) -> Bool {
            cjk.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
        }
        for theme in BuddyTheme.allCases {
            XCTAssertFalse(hasHan(theme.displayName), "theme name not English: \(theme.displayName)")
            for sound in theme.availableSounds {
                XCTAssertFalse(hasHan(sound.name), "sound label not English: \(sound.name)")
            }
        }
    }

    func testShinchanNamesCount() {
        XCTAssertEqual(BuddyTheme.shinchan.names.count, 16)
    }

    func testShinchanNamesIncludeKnownCharacters() {
        let names = BuddyTheme.shinchan.names
        XCTAssertTrue(names.contains("新之助 from 野原家"))
        XCTAssertTrue(names.contains("美冴 from 野原家"))
        XCTAssertTrue(names.contains("小白 from 野原家"))
        XCTAssertTrue(names.contains("风间 from 向日葵班"))
        XCTAssertTrue(names.contains("动感超人 from 春日部"))
    }

    func testShinchanTaglinesCount() {
        XCTAssertEqual(BuddyTheme.shinchan.taglines.count, 20)
    }

    func testShinchanTaglinesIncludeKnownLines() {
        let taglines = BuddyTheme.shinchan.taglines
        XCTAssertTrue(taglines.contains("我是野原新之助，今年 5 岁"))
        XCTAssertTrue(taglines.contains("动感光波～"))
        XCTAssertTrue(taglines.contains("大象～大象～"))
    }

    func testShinchanSoundsCount() {
        XCTAssertEqual(BuddyTheme.shinchan.availableSounds.count, 8)
    }

    func testShinchanHasNoneSentinel() {
        XCTAssertTrue(BuddyTheme.shinchan.availableSounds.map(\.file).contains("none"))
    }

    func testShinchanDefaultSound() {
        XCTAssertEqual(BuddyTheme.shinchan.defaultSoundFile, "xin-yay")
    }

    func testShinchanSoundFilenamesUnique() {
        let files = BuddyTheme.shinchan.availableSounds.map(\.file)
        XCTAssertEqual(files.count, Set(files).count, "duplicate sound filenames")
    }

    func testShinchanCodableRoundTrip() throws {
        let encoded = try JSONEncoder().encode(BuddyTheme.shinchan)
        let decoded = try JSONDecoder().decode(BuddyTheme.self, from: encoded)
        XCTAssertEqual(decoded, .shinchan)
    }

    func testShinchanBuddyAssignmentIsDeterministic() {
        let a = Buddy.from(sessionId: "fixed-session-id", theme: .shinchan)
        let b = Buddy.from(sessionId: "fixed-session-id", theme: .shinchan)
        XCTAssertEqual(a.name, b.name)
        XCTAssertEqual(a.tagline, b.tagline)
        XCTAssertTrue(BuddyTheme.shinchan.names.contains(a.name))
        XCTAssertTrue(BuddyTheme.shinchan.taglines.contains(a.tagline))
    }

    // MARK: - Sound file availability

    /// Every declared sound must have a shipping mp3. Without this, adding a
    /// menu entry but forgetting the audio file yields a silently dead choice.
    func testEveryDeclaredSoundHasAResourceFile() {
        let resources = URL(fileURLWithPath: #filePath)   // Tests/AppLibTests/…
            .deletingLastPathComponent()                  // Tests/AppLibTests
            .deletingLastPathComponent()                  // Tests
            .deletingLastPathComponent()                  // repo root
            .appendingPathComponent("Resources")

        for theme in BuddyTheme.allCases {
            for sound in theme.availableSounds where sound.file != "none" {
                let mp3 = resources.appendingPathComponent(sound.file + ".mp3")
                XCTAssertTrue(
                    FileManager.default.fileExists(atPath: mp3.path),
                    "\(theme.rawValue) declares \(sound.file) but Resources/\(sound.file).mp3 is missing"
                )
            }
        }
    }
}
