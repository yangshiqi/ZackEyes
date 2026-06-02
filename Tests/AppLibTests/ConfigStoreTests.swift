import XCTest
@testable import AppLib
import Shared

final class ConfigStoreTests: XCTestCase {

    private var tmpDir: URL!

    override func setUp() {
        super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zackeyes-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        super.tearDown()
    }

    // MARK: - HotKey

    func testLoadDefaultWhenNoFile() {
        let store = ConfigStore(directory: tmpDir.path)
        let config = store.load()
        XCTAssertEqual(config, HotKeyConfig.default)
    }

    func testSaveAndLoad() {
        let store = ConfigStore(directory: tmpDir.path)
        let custom = HotKeyConfig(keyCode: 40, modifiers: [.option, .command])
        store.save(custom)
        let loaded = store.load()
        XCTAssertEqual(loaded, custom)
    }

    func testLoadCorruptFileFallsBackToDefault() {
        let configPath = tmpDir.appendingPathComponent("config.json").path
        try! "not json".write(toFile: configPath, atomically: true, encoding: .utf8)
        let store = ConfigStore(directory: tmpDir.path)
        let config = store.load()
        XCTAssertEqual(config, HotKeyConfig.default)
    }

    func testSaveCreatesDirectory() {
        let nested = tmpDir.appendingPathComponent("nested").path
        let store = ConfigStore(directory: nested)
        let config = HotKeyConfig(keyCode: 1, modifiers: [.command])
        store.save(config)
        let loaded = store.load()
        XCTAssertEqual(loaded, config)
    }

    func testConfigJsonWrappedInHotkeyKey() throws {
        let store = ConfigStore(directory: tmpDir.path)
        let config = HotKeyConfig(keyCode: 6, modifiers: [.command, .shift])
        store.save(config)

        let data = try Data(contentsOf: tmpDir.appendingPathComponent("config.json"))
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNotNil(json["hotkey"], "Config should be nested under 'hotkey' key")
    }

    // MARK: - Visibility

    func testVisibilityDefaultWhenUnset() {
        let store = ConfigStore(directory: tmpDir.path)
        XCTAssertEqual(store.loadNotchVisibility(), .always)
    }

    func testVisibilityRoundtripHidden() {
        let store = ConfigStore(directory: tmpDir.path)
        store.saveNotchVisibility(.hidden)
        XCTAssertEqual(store.loadNotchVisibility(), .hidden)
    }

    func testVisibilityRoundtripAlways() {
        let store = ConfigStore(directory: tmpDir.path)
        store.saveNotchVisibility(.hidden)
        store.saveNotchVisibility(.always)
        XCTAssertEqual(store.loadNotchVisibility(), .always)
    }

    func testVisibilityPreservesHotkey() {
        let store = ConfigStore(directory: tmpDir.path)
        let customHotkey = HotKeyConfig(keyCode: 12, modifiers: [.command, .option])
        store.save(customHotkey)
        store.saveNotchVisibility(.hidden)
        XCTAssertEqual(store.load(), customHotkey)
        XCTAssertEqual(store.loadNotchVisibility(), .hidden)
    }

    func testVisibilityPreservesTheme() {
        let store = ConfigStore(directory: tmpDir.path)
        store.saveTheme(.f1)
        store.saveNotchVisibility(.hidden)
        XCTAssertEqual(store.loadTheme(), .f1)
        XCTAssertEqual(store.loadNotchVisibility(), .hidden)
    }

    func testVisibilityDefaultWhenFileCorrupt() {
        let store = ConfigStore(directory: tmpDir.path)
        let path = tmpDir.appendingPathComponent("config.json").path
        try? "not json".write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertEqual(store.loadNotchVisibility(), .always)
    }

    /// If config.json exists but cannot be decoded, saveNotchVisibility
    /// must abort rather than seed defaults — otherwise the save would
    /// wipe theme / other fields the user can still recover from the
    /// corrupt file manually. This differs from siblings (save, saveTheme, …)
    /// which do still overwrite; harmonizing those is a follow-up.
    func testSaveAbortsWhenFileCorrupt() {
        let store = ConfigStore(directory: tmpDir.path)
        let path = tmpDir.appendingPathComponent("config.json").path
        let garbage = "not json — keep this content intact"
        try? garbage.write(toFile: path, atomically: true, encoding: .utf8)

        store.saveNotchVisibility(.hidden)

        // File unchanged — abort preserved the corrupt bytes
        let after = try? String(contentsOfFile: path, encoding: .utf8)
        XCTAssertEqual(after, garbage)
    }

    // MARK: - Compact agent

    func testCompactAgentDefaultsToClaude() {
        let store = ConfigStore(directory: tmpDir.path)
        XCTAssertEqual(store.loadCompactAgent(), .claude)
    }

    func testSaveAndLoadCompactAgent() {
        let store = ConfigStore(directory: tmpDir.path)
        store.saveCompactAgent(.codex)
        XCTAssertEqual(store.loadCompactAgent(), .codex)
        store.saveCompactAgent(.claude)
        XCTAssertEqual(store.loadCompactAgent(), .claude)
    }

    /// Setting compactAgent must not wipe theme / hotkey / other keys.
    func testCompactAgentSavePreservesOtherKeys() {
        let store = ConfigStore(directory: tmpDir.path)
        let custom = HotKeyConfig(keyCode: 40, modifiers: [.option, .command])
        store.save(custom)
        store.saveTheme(.f1)

        store.saveCompactAgent(.codex)

        XCTAssertEqual(store.load(), custom)
        XCTAssertEqual(store.loadTheme(), .f1)
        XCTAssertEqual(store.loadCompactAgent(), .codex)
    }

    func testCompactAgentSaveAbortsWhenFileCorrupt() {
        let store = ConfigStore(directory: tmpDir.path)
        let path = tmpDir.appendingPathComponent("config.json").path
        let garbage = "not json — preserve me"
        try? garbage.write(toFile: path, atomically: true, encoding: .utf8)

        store.saveCompactAgent(.codex)

        let after = try? String(contentsOfFile: path, encoding: .utf8)
        XCTAssertEqual(after, garbage)
    }

    // MARK: - Notch offset

    func testNotchOffsetDefaultsToZero() {
        let store = ConfigStore(directory: tmpDir.path)
        XCTAssertEqual(store.loadNotchOffsetX(), 0)
    }

    func testNotchOffsetRoundtrip() {
        let store = ConfigStore(directory: tmpDir.path)
        store.saveNotchOffsetX(-180)
        XCTAssertEqual(store.loadNotchOffsetX(), -180)
        store.saveNotchOffsetX(240.5)
        XCTAssertEqual(store.loadNotchOffsetX(), 240.5)
    }

    /// Setting the offset must not wipe theme / hotkey / other keys.
    func testNotchOffsetSavePreservesOtherKeys() {
        let store = ConfigStore(directory: tmpDir.path)
        let custom = HotKeyConfig(keyCode: 40, modifiers: [.option, .command])
        store.save(custom)
        store.saveTheme(.f1)

        store.saveNotchOffsetX(-120)

        XCTAssertEqual(store.load(), custom)
        XCTAssertEqual(store.loadTheme(), .f1)
        XCTAssertEqual(store.loadNotchOffsetX(), -120)
    }

    func testNotchOffsetDefaultWhenFileCorrupt() {
        let store = ConfigStore(directory: tmpDir.path)
        let path = tmpDir.appendingPathComponent("config.json").path
        try? "not json".write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertEqual(store.loadNotchOffsetX(), 0)
    }

    func testNotchOffsetSaveAbortsWhenFileCorrupt() {
        let store = ConfigStore(directory: tmpDir.path)
        let path = tmpDir.appendingPathComponent("config.json").path
        let garbage = "not json — preserve me"
        try? garbage.write(toFile: path, atomically: true, encoding: .utf8)

        store.saveNotchOffsetX(99)

        let after = try? String(contentsOfFile: path, encoding: .utf8)
        XCTAssertEqual(after, garbage)
    }

    // MARK: - Show Today Consumption

    func testShowTodayConsumptionDefaultsTrue() {
        let store = ConfigStore(directory: tmpDir.path)
        XCTAssertTrue(store.loadShowTodayConsumption())   // default ON
    }

    func testShowTodayConsumptionRoundTrips() {
        let store = ConfigStore(directory: tmpDir.path)
        store.saveShowTodayConsumption(false)
        XCTAssertFalse(store.loadShowTodayConsumption())
        store.saveShowTodayConsumption(true)
        XCTAssertTrue(store.loadShowTodayConsumption())
    }

    func testSaveShowTodayConsumptionPreservesOtherKeys() {
        let store = ConfigStore(directory: tmpDir.path)
        store.saveCompactAgent(.codex)
        store.saveShowTodayConsumption(false)
        XCTAssertEqual(store.loadCompactAgent(), .codex)
        XCTAssertFalse(store.loadShowTodayConsumption())
    }

}
