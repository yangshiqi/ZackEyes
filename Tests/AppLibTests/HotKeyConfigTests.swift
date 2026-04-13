import XCTest
import Carbon.HIToolbox
@testable import AppLib

final class HotKeyConfigTests: XCTestCase {

    // MARK: - HotKeyModifiers

    func testCarbonFlagsCommandShift() {
        let mods: HotKeyModifiers = [.command, .shift]
        XCTAssertEqual(mods.carbonFlags, UInt32(cmdKey | shiftKey))
    }

    func testCarbonFlagsAll() {
        let mods: HotKeyModifiers = [.command, .shift, .option, .control]
        XCTAssertEqual(mods.carbonFlags, UInt32(cmdKey | shiftKey | optionKey | controlKey))
    }

    func testCarbonFlagsEmpty() {
        let mods: HotKeyModifiers = []
        XCTAssertEqual(mods.carbonFlags, 0)
    }

    func testModifiersFromCarbonFlags() {
        let mods = HotKeyModifiers.fromCarbonFlags(UInt32(cmdKey | optionKey))
        XCTAssertTrue(mods.contains(.command))
        XCTAssertTrue(mods.contains(.option))
        XCTAssertFalse(mods.contains(.shift))
        XCTAssertFalse(mods.contains(.control))
    }

    func testModifiersFromNSEventFlags() {
        let flags: NSEvent.ModifierFlags = [.command, .shift]
        let mods = HotKeyModifiers.fromNSEventFlags(flags)
        XCTAssertEqual(mods, [.command, .shift])
    }

    // MARK: - HotKeyConfig

    func testDefaultConfig() {
        let config = HotKeyConfig.default
        XCTAssertEqual(config.keyCode, UInt32(kVK_ANSI_Slash))
        XCTAssertEqual(config.modifiers, [.command, .shift])
    }

    // MARK: - Codable round-trip

    func testCodableRoundTrip() throws {
        let config = HotKeyConfig(keyCode: UInt32(kVK_ANSI_K), modifiers: [.option, .command])
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(HotKeyConfig.self, from: data)
        XCTAssertEqual(decoded, config)
    }

    func testJSONFormat() throws {
        let config = HotKeyConfig(keyCode: 6, modifiers: [.command, .shift])
        let data = try JSONEncoder().encode(config)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["keyCode"] as? Int, 6)
        let mods = json["modifiers"] as? [String]
        XCTAssertNotNil(mods)
        XCTAssertTrue(mods!.contains("command"))
        XCTAssertTrue(mods!.contains("shift"))
    }

    // MARK: - Display string

    func testDisplayStringCommandShiftSlash() {
        let config = HotKeyConfig.default
        XCTAssertEqual(config.displayString, "⇧⌘/")
    }

    func testDisplayStringOptionCommandK() {
        let config = HotKeyConfig(keyCode: UInt32(kVK_ANSI_K), modifiers: [.option, .command])
        XCTAssertEqual(config.displayString, "⌥⌘K")
    }
}

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
}
