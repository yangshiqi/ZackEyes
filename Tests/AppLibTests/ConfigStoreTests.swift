import XCTest
@testable import AppLib

final class NotchVisibilityConfigStoreTests: XCTestCase {

    private var tempDir: String!

    override func setUp() {
        super.setUp()
        tempDir = NSTemporaryDirectory() + "ze-configstore-test-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tempDir)
        super.tearDown()
    }

    // MARK: - Visibility

    func testVisibilityDefaultWhenUnset() {
        let store = ConfigStore(directory: tempDir)
        XCTAssertEqual(store.loadNotchVisibility(), .always)
    }

    func testVisibilityRoundtripHidden() {
        let store = ConfigStore(directory: tempDir)
        store.saveNotchVisibility(.hidden)
        XCTAssertEqual(store.loadNotchVisibility(), .hidden)
    }

    func testVisibilityRoundtripAlways() {
        let store = ConfigStore(directory: tempDir)
        store.saveNotchVisibility(.hidden)
        store.saveNotchVisibility(.always)
        XCTAssertEqual(store.loadNotchVisibility(), .always)
    }

    func testVisibilityPreservesHotkey() {
        let store = ConfigStore(directory: tempDir)
        let customHotkey = HotKeyConfig(keyCode: 12, modifiers: [.command, .option])
        store.save(customHotkey)
        store.saveNotchVisibility(.hidden)
        XCTAssertEqual(store.load(), customHotkey)
        XCTAssertEqual(store.loadNotchVisibility(), .hidden)
    }

    func testVisibilityPreservesTheme() {
        let store = ConfigStore(directory: tempDir)
        store.saveTheme(.f1)
        store.saveNotchVisibility(.hidden)
        XCTAssertEqual(store.loadTheme(), .f1)
        XCTAssertEqual(store.loadNotchVisibility(), .hidden)
    }

    func testVisibilityDefaultWhenFileCorrupt() {
        let store = ConfigStore(directory: tempDir)
        let path = tempDir + "/config.json"
        try? "not json".write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertEqual(store.loadNotchVisibility(), .always)
    }
}
