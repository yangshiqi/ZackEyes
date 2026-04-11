# Custom Hotkey Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users change the global toggle hotkey (default Cmd+Shift+Z) via a key recorder UI, persisted to `~/.zackeyes/config.json`.

**Architecture:** New `ConfigStore` reads/writes a JSON config file. `HotKeyManager` becomes parameterized. A SwiftUI overlay in the gear menu lets users record a new shortcut. AppDelegate wires it all together at startup.

**Tech Stack:** Swift 6, AppKit (Carbon Event Manager for hotkeys, NSEvent local monitor for key capture), SwiftUI, Foundation (JSONEncoder/Decoder)

---

## File Structure

| File | Responsibility |
|------|---------------|
| **New** `Sources/AppLib/Config/HotKeyConfig.swift` | `HotKeyConfig` Codable struct + `HotKeyModifiers` OptionSet with Carbon flag conversion + display formatting |
| **New** `Sources/AppLib/Config/ConfigStore.swift` | Read/write `~/.zackeyes/config.json`, atomic save, graceful fallback on failure |
| **New** `Sources/AppLib/Notch/HotkeyRecorderView.swift` | SwiftUI overlay: current key display, "Press new shortcut…" recorder, Save/Cancel |
| **New** `Tests/AppLibTests/HotKeyConfigTests.swift` | Unit tests for HotKeyConfig + HotKeyModifiers + ConfigStore |
| **Mod** `Sources/AppLib/HotKey/HotKeyManager.swift` | Parameterized `register(keyCode:modifiers:onTrigger:)`, new `reregister(keyCode:modifiers:)` |
| **Mod** `Sources/AppLib/SimulatedNotch/SimulatedNotchRoot.swift` | Add `isHotkeyRecorderShown` to NotchModeStore, update `hasInteractiveOverlay` |
| **Mod** `Sources/AppLib/SimulatedNotch/GearMenuTarget.swift` | Add `hotkeyClicked(_:)` handler |
| **Mod** `Sources/AppLib/SimulatedNotch/SimulatedNotchFullView.swift` | Add "Change Hotkey…" menu item + hotkey recorder overlay |
| **Mod** `Sources/ZackEyes/AppDelegate.swift` | Load config at startup, pass to HotKeyManager |

---

### Task 1: HotKeyConfig data model

**Files:**
- Create: `Sources/AppLib/Config/HotKeyConfig.swift`
- Test: `Tests/AppLibTests/HotKeyConfigTests.swift`

- [ ] **Step 1: Write failing tests for HotKeyModifiers**

```swift
// Tests/AppLibTests/HotKeyConfigTests.swift
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
        XCTAssertEqual(config.keyCode, UInt32(kVK_ANSI_Z))
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

    func testDisplayStringCommandShiftZ() {
        let config = HotKeyConfig.default
        XCTAssertEqual(config.displayString, "⌃⌥⇧⌘Z" == "" ? "" : "") // placeholder, see step 3
        // Actual assertion:
        XCTAssertEqual(config.displayString, "⇧⌘Z")
    }

    func testDisplayStringOptionCommandK() {
        let config = HotKeyConfig(keyCode: UInt32(kVK_ANSI_K), modifiers: [.option, .command])
        XCTAssertEqual(config.displayString, "⌥⌘K")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter HotKeyConfigTests 2>&1 | tail -20`
Expected: FAIL — `HotKeyConfig` and `HotKeyModifiers` not found

- [ ] **Step 3: Implement HotKeyConfig and HotKeyModifiers**

```swift
// Sources/AppLib/Config/HotKeyConfig.swift
import Foundation
import Carbon.HIToolbox

/// Modifier keys for the global hotkey, stored as human-readable strings in JSON.
public struct HotKeyModifiers: OptionSet, Equatable, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let control = HotKeyModifiers(rawValue: 1 << 0)
    public static let option  = HotKeyModifiers(rawValue: 1 << 1)
    public static let shift   = HotKeyModifiers(rawValue: 1 << 2)
    public static let command = HotKeyModifiers(rawValue: 1 << 3)

    /// Convert to Carbon modifier flags for RegisterEventHotKey.
    public var carbonFlags: UInt32 {
        var flags: UInt32 = 0
        if contains(.command) { flags |= UInt32(cmdKey) }
        if contains(.shift)   { flags |= UInt32(shiftKey) }
        if contains(.option)  { flags |= UInt32(optionKey) }
        if contains(.control) { flags |= UInt32(controlKey) }
        return flags
    }

    /// Build from Carbon modifier flags.
    public static func fromCarbonFlags(_ flags: UInt32) -> HotKeyModifiers {
        var mods: HotKeyModifiers = []
        if flags & UInt32(cmdKey) != 0     { mods.insert(.command) }
        if flags & UInt32(shiftKey) != 0   { mods.insert(.shift) }
        if flags & UInt32(optionKey) != 0  { mods.insert(.option) }
        if flags & UInt32(controlKey) != 0 { mods.insert(.control) }
        return mods
    }

    /// Build from NSEvent.ModifierFlags (used by the key recorder).
    public static func fromNSEventFlags(_ flags: NSEvent.ModifierFlags) -> HotKeyModifiers {
        var mods: HotKeyModifiers = []
        if flags.contains(.command) { mods.insert(.command) }
        if flags.contains(.shift)   { mods.insert(.shift) }
        if flags.contains(.option)  { mods.insert(.option) }
        if flags.contains(.control) { mods.insert(.control) }
        return mods
    }

    // MARK: - Display

    /// Ordered modifier symbols for display (macOS standard order: ⌃⌥⇧⌘).
    public var displayString: String {
        var s = ""
        if contains(.control) { s += "⌃" }
        if contains(.option)  { s += "⌥" }
        if contains(.shift)   { s += "⇧" }
        if contains(.command) { s += "⌘" }
        return s
    }

    // MARK: - Codable (string array)

    private static let nameMap: [(HotKeyModifiers, String)] = [
        (.control, "control"), (.option, "option"),
        (.shift, "shift"), (.command, "command"),
    ]
}

extension HotKeyModifiers: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let names = try container.decode([String].self)
        var mods: HotKeyModifiers = []
        for (mod, name) in Self.nameMap {
            if names.contains(name) { mods.insert(mod) }
        }
        self = mods
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        var names: [String] = []
        for (mod, name) in Self.nameMap {
            if contains(mod) { names.append(name) }
        }
        try container.encode(names)
    }
}

/// Configuration for the global toggle hotkey.
public struct HotKeyConfig: Codable, Equatable, Sendable {
    public var keyCode: UInt32
    public var modifiers: HotKeyModifiers

    public init(keyCode: UInt32, modifiers: HotKeyModifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Default: Cmd+Shift+Z
    public static let `default` = HotKeyConfig(
        keyCode: UInt32(kVK_ANSI_Z),
        modifiers: [.command, .shift]
    )

    /// Human-readable display string, e.g. "⇧⌘Z".
    public var displayString: String {
        modifiers.displayString + keyName(for: keyCode)
    }
}

/// Map a Carbon virtual key code to a display name.
/// Covers A-Z, 0-9, F1-F12, and common special keys.
private func keyName(for keyCode: UInt32) -> String {
    switch Int(keyCode) {
    // Letters
    case kVK_ANSI_A: return "A"
    case kVK_ANSI_B: return "B"
    case kVK_ANSI_C: return "C"
    case kVK_ANSI_D: return "D"
    case kVK_ANSI_E: return "E"
    case kVK_ANSI_F: return "F"
    case kVK_ANSI_G: return "G"
    case kVK_ANSI_H: return "H"
    case kVK_ANSI_I: return "I"
    case kVK_ANSI_J: return "J"
    case kVK_ANSI_K: return "K"
    case kVK_ANSI_L: return "L"
    case kVK_ANSI_M: return "M"
    case kVK_ANSI_N: return "N"
    case kVK_ANSI_O: return "O"
    case kVK_ANSI_P: return "P"
    case kVK_ANSI_Q: return "Q"
    case kVK_ANSI_R: return "R"
    case kVK_ANSI_S: return "S"
    case kVK_ANSI_T: return "T"
    case kVK_ANSI_U: return "U"
    case kVK_ANSI_V: return "V"
    case kVK_ANSI_W: return "W"
    case kVK_ANSI_X: return "X"
    case kVK_ANSI_Y: return "Y"
    case kVK_ANSI_Z: return "Z"
    // Numbers
    case kVK_ANSI_0: return "0"
    case kVK_ANSI_1: return "1"
    case kVK_ANSI_2: return "2"
    case kVK_ANSI_3: return "3"
    case kVK_ANSI_4: return "4"
    case kVK_ANSI_5: return "5"
    case kVK_ANSI_6: return "6"
    case kVK_ANSI_7: return "7"
    case kVK_ANSI_8: return "8"
    case kVK_ANSI_9: return "9"
    // Function keys
    case kVK_F1:  return "F1"
    case kVK_F2:  return "F2"
    case kVK_F3:  return "F3"
    case kVK_F4:  return "F4"
    case kVK_F5:  return "F5"
    case kVK_F6:  return "F6"
    case kVK_F7:  return "F7"
    case kVK_F8:  return "F8"
    case kVK_F9:  return "F9"
    case kVK_F10: return "F10"
    case kVK_F11: return "F11"
    case kVK_F12: return "F12"
    // Special keys
    case kVK_Space:         return "Space"
    case kVK_Return:        return "Return"
    case kVK_Tab:           return "Tab"
    case kVK_Delete:        return "Delete"
    case kVK_ForwardDelete: return "Fwd Del"
    case kVK_Escape:        return "Esc"
    case kVK_LeftArrow:     return "←"
    case kVK_RightArrow:    return "→"
    case kVK_UpArrow:       return "↑"
    case kVK_DownArrow:     return "↓"
    case kVK_Home:          return "Home"
    case kVK_End:           return "End"
    case kVK_PageUp:        return "PgUp"
    case kVK_PageDown:      return "PgDn"
    // Punctuation
    case kVK_ANSI_Minus:        return "-"
    case kVK_ANSI_Equal:        return "="
    case kVK_ANSI_LeftBracket:  return "["
    case kVK_ANSI_RightBracket: return "]"
    case kVK_ANSI_Backslash:    return "\\"
    case kVK_ANSI_Semicolon:    return ";"
    case kVK_ANSI_Quote:        return "'"
    case kVK_ANSI_Comma:        return ","
    case kVK_ANSI_Period:       return "."
    case kVK_ANSI_Slash:        return "/"
    case kVK_ANSI_Grave:        return "`"
    default: return "Key(\(keyCode))"
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter HotKeyConfigTests 2>&1 | tail -20`
Expected: All tests PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/AppLib/Config/HotKeyConfig.swift Tests/AppLibTests/HotKeyConfigTests.swift
git commit -m "feat(hotkey): add HotKeyConfig and HotKeyModifiers data model"
```

---

### Task 2: ConfigStore (read/write config.json)

**Files:**
- Create: `Sources/AppLib/Config/ConfigStore.swift`
- Modify: `Tests/AppLibTests/HotKeyConfigTests.swift` (add ConfigStore tests)

- [ ] **Step 1: Write failing tests for ConfigStore**

Append to `Tests/AppLibTests/HotKeyConfigTests.swift`:

```swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ConfigStoreTests 2>&1 | tail -20`
Expected: FAIL — `ConfigStore` not found

- [ ] **Step 3: Implement ConfigStore**

```swift
// Sources/AppLib/Config/ConfigStore.swift
import Foundation

/// Reads and writes ZackEyes configuration from `~/.zackeyes/config.json`.
///
/// JSON format:
/// ```json
/// { "hotkey": { "keyCode": 6, "modifiers": ["command", "shift"] } }
/// ```
///
/// On any read failure (file missing, corrupt JSON), returns defaults silently.
public final class ConfigStore: Sendable {
    private let directory: String

    /// - Parameter directory: Directory containing `config.json`.
    ///   Defaults to `~/.zackeyes`.
    public init(directory: String = NSHomeDirectory() + "/.zackeyes") {
        self.directory = directory
    }

    private var configPath: String { directory + "/config.json" }

    /// Load the hotkey config. Returns `HotKeyConfig.default` on any failure.
    public func load() -> HotKeyConfig {
        guard let data = FileManager.default.contents(atPath: configPath) else {
            return .default
        }
        guard let wrapper = try? JSONDecoder().decode(ConfigWrapper.self, from: data) else {
            return .default
        }
        return wrapper.hotkey
    }

    /// Save the hotkey config atomically. Creates directory if needed.
    public func save(_ config: HotKeyConfig) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory) {
            try? fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
        let wrapper = ConfigWrapper(hotkey: config)
        guard let data = try? JSONEncoder().encode(wrapper) else { return }
        fm.createFile(atPath: configPath, contents: data)
    }
}

/// Top-level JSON wrapper so config.json has `{ "hotkey": { ... } }` structure,
/// leaving room for future settings keys without breaking the file format.
private struct ConfigWrapper: Codable {
    var hotkey: HotKeyConfig
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ConfigStoreTests 2>&1 | tail -20`
Expected: All tests PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/AppLib/Config/ConfigStore.swift Tests/AppLibTests/HotKeyConfigTests.swift
git commit -m "feat(hotkey): add ConfigStore for ~/.zackeyes/config.json"
```

---

### Task 3: Parameterize HotKeyManager

**Files:**
- Modify: `Sources/AppLib/HotKey/HotKeyManager.swift`

- [ ] **Step 1: Modify HotKeyManager to accept keyCode and modifiers**

Replace the entire file content of `Sources/AppLib/HotKey/HotKeyManager.swift`:

```swift
import AppKit
import Carbon.HIToolbox

/// Registers a global hotkey via the Carbon Event Manager.
/// Default is Cmd+Shift+Z; can be customized via `register(keyCode:modifiers:onTrigger:)`.
@MainActor
public final class HotKeyManager {

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var onTrigger: (() -> Void)?
    private var currentKeyCode: UInt32 = 0
    private var currentModifiers: UInt32 = 0

    public init() {}

    /// Register a global hotkey and call `onTrigger` when pressed.
    /// - Parameters:
    ///   - keyCode: Carbon virtual key code (e.g. `UInt32(kVK_ANSI_Z)`)
    ///   - modifiers: Carbon modifier flags (e.g. `UInt32(cmdKey | shiftKey)`)
    ///   - onTrigger: Closure called when the hotkey is pressed
    public func register(
        keyCode: UInt32,
        modifiers: UInt32,
        onTrigger: @escaping () -> Void
    ) {
        self.onTrigger = onTrigger
        self.currentKeyCode = keyCode
        self.currentModifiers = modifiers

        // Install event handler (only once — it handles all hotkey IDs)
        if eventHandler == nil {
            var eventType = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: OSType(kEventHotKeyPressed)
            )
            let selfPtr = Unmanaged.passUnretained(self).toOpaque()
            InstallEventHandler(
                GetApplicationEventTarget(),
                { _, event, userData in
                    guard let userData = userData, let event = event else { return noErr }
                    let manager = Unmanaged<HotKeyManager>.fromOpaque(userData)
                        .takeUnretainedValue()
                    Task { @MainActor in
                        manager.onTrigger?()
                    }
                    _ = event
                    return noErr
                },
                1,
                &eventType,
                selfPtr,
                &eventHandler
            )
        }

        registerHotKey(keyCode: keyCode, modifiers: modifiers)
    }

    /// Change the registered hotkey without changing the callback.
    /// Unregisters the old key and registers the new one.
    public func reregister(keyCode: UInt32, modifiers: UInt32) {
        unregisterHotKey()
        currentKeyCode = keyCode
        currentModifiers = modifiers
        registerHotKey(keyCode: keyCode, modifiers: modifiers)
    }

    public func unregister() {
        unregisterHotKey()
        if let eventHandler = eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
        onTrigger = nil
    }

    // MARK: - Private

    private func registerHotKey(keyCode: UInt32, modifiers: UInt32) {
        let hotKeyID = EventHotKeyID(signature: OSType(0x5A454B45) /* "ZEKE" */, id: 1)
        RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    private func unregisterHotKey() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }
}
```

- [ ] **Step 2: Build to verify compilation**

Run: `swift build 2>&1 | tail -5`
Expected: Build will FAIL because AppDelegate still calls old `register(onTrigger:)` signature

- [ ] **Step 3: Update AppDelegate to use new API with ConfigStore**

In `Sources/ZackEyes/AppDelegate.swift`, replace lines 79-90 (the hotkey section):

Old:
```swift
        // 4.5 Global hotkey (Cmd+Shift+Z) — toggles the simulated notch on
        // notchless Macs, falls back to the menu bar popover if neither exists.
        let hk = HotKeyManager()
        hk.register { [weak self] in
            guard let self = self else { return }
            if let sn = self.simulatedNotch {
                sn.toggleFull()
            } else {
                self.menuBarFallback?.toggle()
            }
        }
        hotKeyManager = hk
```

New:
```swift
        // 4.5 Global hotkey — toggles the simulated notch on notchless Macs,
        // falls back to the menu bar popover if neither exists.
        // Reads user-configured key from ~/.zackeyes/config.json (default: Cmd+Shift+Z).
        let hotkeyConfig = ConfigStore().load()
        let hk = HotKeyManager()
        hk.register(
            keyCode: hotkeyConfig.keyCode,
            modifiers: hotkeyConfig.modifiers.carbonFlags
        ) { [weak self] in
            guard let self = self else { return }
            if let sn = self.simulatedNotch {
                sn.toggleFull()
            } else {
                self.menuBarFallback?.toggle()
            }
        }
        hotKeyManager = hk
```

- [ ] **Step 4: Build to verify everything compiles**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds

- [ ] **Step 5: Run all tests to check nothing broke**

Run: `swift test 2>&1 | tail -20`
Expected: All tests PASS

- [ ] **Step 6: Commit**

```bash
git add Sources/AppLib/HotKey/HotKeyManager.swift Sources/ZackEyes/AppDelegate.swift
git commit -m "feat(hotkey): parameterize HotKeyManager, load config at startup"
```

---

### Task 4: Gear menu "Change Hotkey…" entry + state

**Files:**
- Modify: `Sources/AppLib/SimulatedNotch/SimulatedNotchRoot.swift` (NotchModeStore)
- Modify: `Sources/AppLib/SimulatedNotch/GearMenuTarget.swift`
- Modify: `Sources/AppLib/SimulatedNotch/SimulatedNotchFullView.swift`

- [ ] **Step 1: Add `isHotkeyRecorderShown` to NotchModeStore**

In `Sources/AppLib/SimulatedNotch/SimulatedNotchRoot.swift`, add after line 22 (`isAboutShown`):

```swift
    /// True while the hotkey recorder overlay is shown.
    @Published public var isHotkeyRecorderShown: Bool = false
```

Update `hasInteractiveOverlay` (line 27-29) to include it:

Old:
```swift
    public var hasInteractiveOverlay: Bool {
        isMenuOpen || isAboutShown
    }
```

New:
```swift
    public var hasInteractiveOverlay: Bool {
        isMenuOpen || isAboutShown || isHotkeyRecorderShown
    }
```

- [ ] **Step 2: Add `hotkeyClicked` to GearMenuTarget**

In `Sources/AppLib/SimulatedNotch/GearMenuTarget.swift`, add after `aboutClicked` (line 15-18):

```swift
    @objc func hotkeyClicked(_ sender: Any?) {
        modeStore?.isMenuOpen = false
        modeStore?.isHotkeyRecorderShown = true
    }
```

- [ ] **Step 3: Add "Change Hotkey…" menu item in SimulatedNotchFullView**

In `Sources/AppLib/SimulatedNotch/SimulatedNotchFullView.swift`, in the `popGearMenu()` method, add after the "About" menu item (after line 162 `menu.addItem(about)`) and before the separator:

```swift
        let hotkey = NSMenuItem(
            title: "Change Hotkey…",
            action: #selector(GearMenuTarget.hotkeyClicked(_:)),
            keyEquivalent: ""
        )
        hotkey.target = GearMenuTarget.shared
        menu.addItem(hotkey)
```

- [ ] **Step 4: Build to verify compilation**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds (overlay not wired yet, but state + menu item compile)

- [ ] **Step 5: Commit**

```bash
git add Sources/AppLib/SimulatedNotch/SimulatedNotchRoot.swift \
       Sources/AppLib/SimulatedNotch/GearMenuTarget.swift \
       Sources/AppLib/SimulatedNotch/SimulatedNotchFullView.swift
git commit -m "feat(hotkey): add 'Change Hotkey…' gear menu item + recorder state"
```

---

### Task 5: HotkeyRecorderView (SwiftUI key capture overlay)

**Files:**
- Create: `Sources/AppLib/Notch/HotkeyRecorderView.swift`
- Modify: `Sources/AppLib/SimulatedNotch/SimulatedNotchFullView.swift` (wire overlay)

- [ ] **Step 1: Create HotkeyRecorderView**

```swift
// Sources/AppLib/Notch/HotkeyRecorderView.swift
import SwiftUI
import AppKit
import Carbon.HIToolbox

/// Key recorder overlay. Captures a key combo via NSEvent local monitor,
/// validates it has at least one modifier, and calls onSave/onCancel.
struct HotkeyRecorderView: View {
    let currentConfig: HotKeyConfig
    let onSave: (HotKeyConfig) -> Void
    let onCancel: () -> Void

    @State private var capturedKeyCode: UInt32?
    @State private var capturedModifiers: HotKeyModifiers = []
    @State private var isRecording = true
    @State private var errorMessage: String?
    @State private var monitor: Any?

    var body: some View {
        ZStack {
            // Backdrop
            Color.black.opacity(0.6)
                .contentShape(Rectangle())
                .onTapGesture { onCancel() }

            // Card
            VStack(spacing: 16) {
                Text("Change Hotkey")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)

                // Current or captured shortcut display
                Text(displayText)
                    .font(.system(size: 28, weight: .medium, design: .rounded))
                    .foregroundColor(.white)
                    .frame(height: 40)

                Text(isRecording ? "Press new shortcut…" : "")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.5))
                    .frame(height: 16)

                if let error = errorMessage {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundColor(Color(red: 0.95, green: 0.30, blue: 0.30))
                        .frame(height: 14)
                } else {
                    Spacer().frame(height: 14)
                }

                HStack(spacing: 12) {
                    Button("Cancel") { onCancel() }
                        .buttonStyle(.bordered)
                        .keyboardShortcut(.cancelAction)

                    Button("Save") { save() }
                        .buttonStyle(.borderedProminent)
                        .disabled(capturedKeyCode == nil)
                }
            }
            .padding(24)
            .frame(width: 280, height: 220)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(white: 0.12))
            )
            .contentShape(Rectangle())
            .onTapGesture { /* prevent backdrop dismiss */ }
        }
        .onAppear { startMonitor() }
        .onDisappear { stopMonitor() }
    }

    private var displayText: String {
        if let keyCode = capturedKeyCode {
            let config = HotKeyConfig(keyCode: keyCode, modifiers: capturedModifiers)
            return config.displayString
        }
        return currentConfig.displayString
    }

    private func startMonitor() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let mods = HotKeyModifiers.fromNSEventFlags(event.modifierFlags)

            // Must have at least one modifier
            if mods.isEmpty {
                errorMessage = "Must include ⌘, ⌥, ⌃, or ⇧"
                return nil // swallow the event
            }

            // Don't accept Escape as the key (it's our cancel)
            if event.keyCode == UInt32(kVK_Escape) && mods.isEmpty {
                return event
            }

            errorMessage = nil
            capturedKeyCode = UInt32(event.keyCode)
            capturedModifiers = mods
            isRecording = false
            return nil // swallow the event
        }
    }

    private func stopMonitor() {
        if let mon = monitor {
            NSEvent.removeMonitor(mon)
            monitor = nil
        }
    }

    private func save() {
        guard let keyCode = capturedKeyCode else { return }
        let newConfig = HotKeyConfig(keyCode: keyCode, modifiers: capturedModifiers)
        if newConfig == currentConfig {
            onCancel() // no change
            return
        }
        onSave(newConfig)
    }
}
```

- [ ] **Step 2: Wire the overlay into SimulatedNotchFullView**

In `Sources/AppLib/SimulatedNotch/SimulatedNotchFullView.swift`:

a) Add after line 37 (`.overlay(aboutOverlay)`):

```swift
        .overlay(hotkeyRecorderOverlay)
```

b) Add this computed property after the `aboutOverlay` property (after line 84):

```swift
    /// Hotkey recorder overlay — captures a new global shortcut.
    @ViewBuilder
    private var hotkeyRecorderOverlay: some View {
        if modeStore.isHotkeyRecorderShown {
            HotkeyRecorderView(
                currentConfig: ConfigStore().load(),
                onSave: { newConfig in
                    ConfigStore().save(newConfig)
                    NotificationCenter.default.post(
                        name: .hotkeyConfigChanged,
                        object: nil,
                        userInfo: ["config": newConfig]
                    )
                    modeStore.isHotkeyRecorderShown = false
                },
                onCancel: {
                    modeStore.isHotkeyRecorderShown = false
                }
            )
            .transition(.opacity)
        }
    }
```

c) Add at the bottom of the file (outside the struct):

```swift
extension Notification.Name {
    static let hotkeyConfigChanged = Notification.Name("hotkeyConfigChanged")
}
```

- [ ] **Step 3: Wire the notification in AppDelegate**

In `Sources/ZackEyes/AppDelegate.swift`, add after the hotkey registration block (after `hotKeyManager = hk`):

```swift
        // Listen for hotkey config changes from the recorder UI
        NotificationCenter.default.addObserver(
            forName: .hotkeyConfigChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let config = notification.userInfo?["config"] as? HotKeyConfig else { return }
            self?.hotKeyManager?.reregister(
                keyCode: config.keyCode,
                modifiers: config.modifiers.carbonFlags
            )
        }
```

- [ ] **Step 4: Build to verify everything compiles**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds

- [ ] **Step 5: Run all tests**

Run: `swift test 2>&1 | tail -20`
Expected: All tests PASS

- [ ] **Step 6: Commit**

```bash
git add Sources/AppLib/Notch/HotkeyRecorderView.swift \
       Sources/AppLib/SimulatedNotch/SimulatedNotchFullView.swift \
       Sources/ZackEyes/AppDelegate.swift
git commit -m "feat(hotkey): add key recorder overlay and wire to HotKeyManager"
```

---

### Task 6: Build + manual test

- [ ] **Step 1: Full build**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds

- [ ] **Step 2: Run all tests**

Run: `swift test 2>&1 | tail -20`
Expected: All tests PASS

- [ ] **Step 3: Build .app bundle**

Run: `make app 2>&1 | tail -5`
Expected: `.build/ZackEyes.app` created

- [ ] **Step 4: Update ARCHITECTURE.md**

In `Sources/AppLib/` module table, add the Config module entry:

```
| `ConfigStore` | `Sources/AppLib/Config/ConfigStore.swift` | 读写 `~/.zackeyes/config.json` |
| `HotKeyConfig` | `Sources/AppLib/Config/HotKeyConfig.swift` | 快捷键配置模型 + modifier 转换 |
```

Update `HotKeyManager` row to note it's now parameterized.

Add `HotkeyRecorderView` to the Notch UI section.

- [ ] **Step 5: Commit docs update**

```bash
git add ARCHITECTURE.md
git commit -m "docs: add Config module and HotkeyRecorderView to ARCHITECTURE.md"
```
