import XCTest
@testable import AppLib

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
    /// wipe githubToken / theme / other fields the user can still recover
    /// from the corrupt file manually. This differs from siblings (save,
    /// saveTheme, …) which do still overwrite; harmonizing those is a
    /// follow-up.
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
}
