# Notch Visibility Toggle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a persistent/hidden toggle for the Dynamic Island panel (both real-notch and simulated-notch paths), persisted in `~/.zackeyes/config.json`, with menu-bar entry and global-hotkey / menu-click / event-driven recall. Tag-along: swap menu-bar icon from `sparkles` to `star.fill` to match app logo.

**Architecture:** `NotchVisibility` enum read/written by `ConfigStore`; a new `.notchVisibilityChanged` NotificationCenter notification fires on menu toggle; both `NotchWindowController` and `SimulatedNotchController` gain an `applyVisibility(_:)` method that calls `panel.orderOut(nil)` / `panel.orderFrontRegardless()` to respect the setting. `forceUiExpand()` and the hotkey / menu-bar click paths unconditionally call `orderFrontRegardless()` before expanding, so events always bypass the setting. Hover-to-expand is short-circuited in hidden mode. Controllers receive initial visibility via init to avoid a startup flash.

**Tech Stack:** Swift 6, AppKit, SwiftUI, Swift Package Manager, XCTest.

**Spec:** `docs/superpowers/specs/2026-04-21-notch-visibility-toggle-design.md`

---

## File Structure

**Create:**
- `Sources/AppLib/Config/NotchVisibility.swift` — the enum
- `Tests/AppLibTests/ConfigStoreTests.swift` — roundtrip + default + preserve-other-fields tests

**Modify:**
- `Sources/AppLib/Config/ConfigStore.swift` — add field to wrapper, load/save methods
- `Sources/AppLib/SimulatedNotch/SimulatedNotchFullView.swift` — add `.notchVisibilityChanged` next to `.hotkeyConfigChanged` at bottom (follows existing convention)
- `Sources/AppLib/SimulatedNotch/SimulatedNotchController.swift` — initial visibility init param, `applyVisibility`, hover guard, compact-tail orderOut, pre-expand orderFront, guard `orderFrontRegardless` in `createPanel`
- `Sources/AppLib/Notch/NotchWindowController.swift` — same treatment
- `Sources/AppLib/MenuBar/StatusBarMenu.swift` — new menu item + action
- `Sources/AppLib/MenuBar/MenuBarFallback.swift` — icon `sparkles` → `star.fill`
- `Sources/ZackEyes/AppDelegate.swift` — load visibility at startup, pass to controller inits, observe `.notchVisibilityChanged`

---

## Task 1: Add `NotchVisibility` enum

**Files:**
- Create: `Sources/AppLib/Config/NotchVisibility.swift`

No test — trivial enum. Consumers are tested downstream.

- [ ] **Step 1: Create the enum**

Write `Sources/AppLib/Config/NotchVisibility.swift`:

```swift
import Foundation

/// Controls whether the Dynamic Island panel is persistently visible
/// (compact pill always on screen) or only appears on demand (hotkey,
/// menu-bar click, permission request, error).
///
/// `.hidden` does NOT suppress event-driven expansion (`forceUiExpand`)
/// — PermissionRequest and errors always show the panel to avoid leaving
/// the user locked out of their running Claude Code commands.
public enum NotchVisibility: String, Codable, Sendable {
    case always   // Default: compact pill always visible
    case hidden   // Panel off-screen unless recalled by hotkey / menu / event
}
```

- [ ] **Step 2: Verify it builds**

Run: `swift build`
Expected: build succeeds (no tests run yet).

- [ ] **Step 3: Commit**

```bash
git add Sources/AppLib/Config/NotchVisibility.swift
git commit -m "$(cat <<'EOF'
feat: add NotchVisibility enum

Introduces the two-value visibility setting for the Dynamic Island
panel. Consumers (ConfigStore, controllers, menu) land in later
commits.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Add `loadNotchVisibility` / `saveNotchVisibility` to `ConfigStore` (TDD)

**Files:**
- Create: `Tests/AppLibTests/ConfigStoreTests.swift`
- Modify: `Sources/AppLib/Config/ConfigStore.swift` (add field to `ConfigWrapper`, add two methods)

- [ ] **Step 1: Write the failing tests**

Write `Tests/AppLibTests/ConfigStoreTests.swift`:

```swift
import XCTest
@testable import AppLib

final class ConfigStoreTests: XCTestCase {

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
```

Note: `BuddyTheme` has cases `.rock` (default) and `.f1`. The theme-preservation test uses `.f1` so it differs from the default. If you find a third theme case later, either is fine.

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ConfigStoreTests`
Expected: compile error, `loadNotchVisibility` / `saveNotchVisibility` not defined on `ConfigStore`.

- [ ] **Step 3: Add field to `ConfigWrapper`**

Modify `Sources/AppLib/Config/ConfigStore.swift`, at the `ConfigWrapper` struct near the bottom of the file:

```swift
/// Top-level JSON wrapper for ~/.zackeyes/config.json.
/// All known keys are modeled here so save() preserves them.
private struct ConfigWrapper: Codable {
    var hotkey: HotKeyConfig
    var githubToken: String?
    var theme: BuddyTheme?              // nil = .rock (default)
    var notificationSound: String?      // nil = theme default sound
    var notchVisibility: String?        // nil = .always (default)
}
```

- [ ] **Step 4: Add load/save methods**

Add these two methods inside the `ConfigStore` class, next to `loadTheme` / `saveTheme`:

```swift
/// Load the notch visibility setting. Returns `.always` on any failure
/// or when the field is absent (new installs / pre-visibility configs).
public func loadNotchVisibility() -> NotchVisibility {
    guard let data = FileManager.default.contents(atPath: configPath),
          let wrapper = try? JSONDecoder().decode(ConfigWrapper.self, from: data),
          let raw = wrapper.notchVisibility,
          let v = NotchVisibility(rawValue: raw) else {
        return .always
    }
    return v
}

/// Save the notch visibility setting. Preserves other keys.
public func saveNotchVisibility(_ visibility: NotchVisibility) {
    let fm = FileManager.default
    if !fm.fileExists(atPath: directory) {
        try? fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }
    var wrapper: ConfigWrapper
    if let data = fm.contents(atPath: configPath),
       let existing = try? JSONDecoder().decode(ConfigWrapper.self, from: data) {
        wrapper = existing
    } else {
        wrapper = ConfigWrapper(hotkey: .default)
    }
    wrapper.notchVisibility = visibility.rawValue
    guard let data = try? JSONEncoder().encode(wrapper) else { return }
    try? data.write(to: URL(fileURLWithPath: configPath), options: .atomic)
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter ConfigStoreTests`
Expected: all pass.

Also run: `swift test --filter HotKeyConfigTests`
Expected: existing tests still pass (no regression on shared config file).

- [ ] **Step 6: Commit**

```bash
git add Sources/AppLib/Config/ConfigStore.swift Tests/AppLibTests/ConfigStoreTests.swift
git commit -m "$(cat <<'EOF'
feat: persist NotchVisibility via ConfigStore

Adds loadNotchVisibility / saveNotchVisibility with nil-safe default of
.always, matching the existing theme/sound preservation pattern.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Add `.notchVisibilityChanged` Notification.Name

**Files:**
- Modify: `Sources/AppLib/SimulatedNotch/SimulatedNotchFullView.swift` (bottom-of-file extension block)

- [ ] **Step 1: Add to the existing Notification.Name extension**

Open `Sources/AppLib/SimulatedNotch/SimulatedNotchFullView.swift`. At the very bottom there is:

```swift
public extension Notification.Name {
    static let hotkeyConfigChanged = Notification.Name("hotkeyConfigChanged")
}
```

Change to:

```swift
public extension Notification.Name {
    static let hotkeyConfigChanged = Notification.Name("hotkeyConfigChanged")
    static let notchVisibilityChanged = Notification.Name("notchVisibilityChanged")
}
```

- [ ] **Step 2: Verify it builds**

Run: `swift build`
Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/AppLib/SimulatedNotch/SimulatedNotchFullView.swift
git commit -m "$(cat <<'EOF'
feat: add .notchVisibilityChanged notification name

Follows the existing bottom-of-file convention where .hotkeyConfigChanged
is defined. Consumers (AppDelegate, StatusBarMenu) land in later commits.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Wire visibility into `SimulatedNotchController`

**Files:**
- Modify: `Sources/AppLib/SimulatedNotch/SimulatedNotchController.swift`

Changes: add `visibility` stored property with init injection, gate `orderFrontRegardless` in `createPanel`, add `applyVisibility(_:)`, gate hover in `handleMouseMove`, order out at tail of compact transition, pre-expand ordering for `forceExpand` / `toggleFull`.

- [ ] **Step 1: Add visibility property + inject via init**

Near the top of the class (next to `private var modeStore = NotchModeStore()`), add:

```swift
private var visibility: NotchVisibility
```

Change the `init` signature. Existing:

```swift
public init(viewModel: NotchViewModel, usageTracker: UsageTracker, updateChecker: UpdateChecker) {
    self.viewModel = viewModel
    self.usageTracker = usageTracker
    self.updateChecker = updateChecker
}
```

Replace with:

```swift
public init(
    viewModel: NotchViewModel,
    usageTracker: UsageTracker,
    updateChecker: UpdateChecker,
    initialVisibility: NotchVisibility = .always
) {
    self.viewModel = viewModel
    self.usageTracker = usageTracker
    self.updateChecker = updateChecker
    self.visibility = initialVisibility
}
```

- [ ] **Step 2: Gate `orderFrontRegardless` in `createPanel`**

In `createPanel()`, find this line:

```swift
panel.orderFrontRegardless()
```

Replace with:

```swift
if visibility == .always {
    panel.orderFrontRegardless()
}
// Hidden: stay off-screen. forceExpand / hotkey / menu click / events
// will order the panel front when needed.
```

- [ ] **Step 3: Add `applyVisibility(_:)` method**

Add at the end of the class (after `observeScreenChanges`, before the closing `}`):

```swift
/// Respond to a runtime visibility change from the menu toggle.
/// - `.hidden` + currently compact → order the panel off-screen immediately
/// - `.always` → order the panel back on-screen, leave mode untouched
/// - `.hidden` + currently full → leave on-screen; next collapse will
///   naturally `orderOut` via the tail of `setMode(.compact)`
public func applyVisibility(_ v: NotchVisibility) {
    visibility = v
    guard let panel = panel else { return }
    if v == .hidden && mode != .full {
        panel.orderOut(nil)
    } else if v == .always && !panel.isVisible {
        panel.orderFrontRegardless()
    }
}
```

- [ ] **Step 4: Guard hover handling when hidden**

In `handleMouseMove(_:)`, find the first line after `guard let panel = panel else { return }`. Add a visibility guard right after:

```swift
private func handleMouseMove(_ location: NSPoint) {
    guard let panel = panel else { return }
    // In hidden mode the panel should not react to hover — only hotkey /
    // menu click / explicit event triggers may bring it back.
    if visibility == .hidden { return }

    // Hover area depends on current mode — for compact pill it's a small
    // ...
```

- [ ] **Step 5: Order out at the tail of compact transitions**

In `setMode(_:)`, find the `if newMode == .full { … } else { … }` block. The `else` branch calls `stopOutsideClickMonitoring()` and conditionally flips `allowsKeyStatus`. Append an ordering step:

```swift
if newMode == .full {
    startOutsideClickMonitoring()
} else {
    stopOutsideClickMonitoring()
    // Revert key status when collapsing (unless hotkey recorder is open)
    if !modeStore.isHotkeyRecorderShown {
        panel.allowsKeyStatus = false
    }
    // Hidden: once collapsed, immediately remove the panel from screen.
    if visibility == .hidden {
        panel.orderOut(nil)
    }
}
```

- [ ] **Step 6: Order front before expanding**

In `forceExpand()`, current body:

```swift
public func forceExpand() {
    setMode(.full)
    panel?.allowsKeyStatus = true
    panel?.makeKey()
}
```

Replace with:

```swift
public func forceExpand() {
    if let panel, !panel.isVisible {
        panel.orderFrontRegardless()
    }
    setMode(.full)
    panel?.allowsKeyStatus = true
    panel?.makeKey()
}
```

In `toggleFull()`, current body:

```swift
public func toggleFull() {
    setMode(mode == .full ? .compact : .full)
}
```

Replace with:

```swift
public func toggleFull() {
    // If we were hidden and off-screen, the panel needs to come back
    // before any mode animation, otherwise the user's menu-bar click
    // toggles a panel they can't see.
    if let panel, !panel.isVisible {
        panel.orderFrontRegardless()
        setMode(.full)
        return
    }
    setMode(mode == .full ? .compact : .full)
}
```

- [ ] **Step 7: Verify build**

Run: `swift build`
Expected: build succeeds.

- [ ] **Step 8: Commit**

```bash
git add Sources/AppLib/SimulatedNotch/SimulatedNotchController.swift
git commit -m "$(cat <<'EOF'
feat(simulated-notch): respect NotchVisibility

Panel is off-screen when visibility == .hidden; hotkey, menu-bar click,
forceExpand, and toggleFull all recall it before expanding. Hover is
short-circuited. Compact collapses order the panel out again.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Wire visibility into `NotchWindowController`

**Files:**
- Modify: `Sources/AppLib/Notch/NotchWindowController.swift`

- [ ] **Step 1: Add visibility property + inject via init**

Near the existing private properties (next to `private var collapseWorkItem: DispatchWorkItem?`), add:

```swift
private var visibility: NotchVisibility
```

Change the init. Existing:

```swift
public init(viewModel: NotchViewModel, usageTracker: UsageTracker) {
    self.viewModel = viewModel
    self.usageTracker = usageTracker
}
```

Replace with:

```swift
public init(
    viewModel: NotchViewModel,
    usageTracker: UsageTracker,
    initialVisibility: NotchVisibility = .always
) {
    self.viewModel = viewModel
    self.usageTracker = usageTracker
    self.visibility = initialVisibility
}
```

- [ ] **Step 2: Gate `orderFrontRegardless` in `createPanel`**

In `createPanel()`, find the line:

```swift
newPanel.orderFrontRegardless()
```

Replace with:

```swift
if visibility == .always {
    newPanel.orderFrontRegardless()
}
// Hidden: stay off-screen. forceExpand / hotkey / menu click / events
// will order the panel front when needed.
```

- [ ] **Step 3: Add `applyVisibility(_:)` method**

Add near the other `public` state-control methods (e.g. after `forceExpand`):

```swift
/// Respond to a runtime visibility change from the menu toggle.
/// - `.hidden` + currently compact → order the panel off-screen immediately
/// - `.always` → order the panel back on-screen
/// - `.hidden` + currently expanded → leave on-screen; next collapse
///   naturally orders out via the tail of `updatePanelState(.compact)`
public func applyVisibility(_ v: NotchVisibility) {
    visibility = v
    guard let panel = panel else { return }
    if v == .hidden && currentState != .expanded {
        panel.orderOut(nil)
    } else if v == .always && !panel.isVisible {
        panel.orderFrontRegardless()
    }
}
```

- [ ] **Step 4: Guard hover when hidden**

In `handleMouseMoved(_:)`, find the `.compact` case:

```swift
case .compact:
    // Expand the moment the cursor enters the menu-bar row within
    // our horizontal pill span.
    let pill = compactPillRect(on: screen, notchHeight: notchHeight)
    if pill.contains(mouse) {
        cancelCollapseWorkItem()
        updatePanelState(.expanded)
    }
```

Add the guard:

```swift
case .compact:
    // In hidden mode the panel is off-screen and should not auto-expand
    // on hover — only hotkey / menu click / explicit event triggers bring
    // it back.
    if visibility == .hidden { return }
    // Expand the moment the cursor enters the menu-bar row within
    // our horizontal pill span.
    let pill = compactPillRect(on: screen, notchHeight: notchHeight)
    if pill.contains(mouse) {
        cancelCollapseWorkItem()
        updatePanelState(.expanded)
    }
```

- [ ] **Step 5: Order out at tail of compact transition**

In `updatePanelState(_:)`, current body (paraphrased):

```swift
public func updatePanelState(_ newState: PanelState) {
    guard newState != currentState || panel == nil else { return }

    currentState = newState
    viewModel.panelState = newState

    panel?.ignoresMouseEvents = (newState != .expanded)

    NSLog("ZackEyes[notch]: updatePanelState →%@", "\(newState)")
}
```

Append a hidden-mode orderOut:

```swift
public func updatePanelState(_ newState: PanelState) {
    guard newState != currentState || panel == nil else { return }

    currentState = newState
    viewModel.panelState = newState

    panel?.ignoresMouseEvents = (newState != .expanded)

    // Hidden: once collapsed, immediately remove the panel from screen.
    if newState == .compact && visibility == .hidden {
        panel?.orderOut(nil)
    }

    NSLog("ZackEyes[notch]: updatePanelState →%@", "\(newState)")
}
```

- [ ] **Step 6: Order front before expanding in `forceExpand`**

Current:

```swift
public func forceExpand() {
    updatePanelState(.expanded)
}
```

Replace with:

```swift
public func forceExpand() {
    if let panel, !panel.isVisible {
        panel.orderFrontRegardless()
    }
    updatePanelState(.expanded)
}
```

- [ ] **Step 7: Verify build**

Run: `swift build`
Expected: build succeeds.

- [ ] **Step 8: Commit**

```bash
git add Sources/AppLib/Notch/NotchWindowController.swift
git commit -m "$(cat <<'EOF'
feat(real-notch): respect NotchVisibility

Panel is off-screen when visibility == .hidden; hover-to-expand is
short-circuited; forceExpand orders the panel back before expanding.
Compact collapses order the panel out again.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Wire `AppDelegate` — load at startup + observe changes

**Files:**
- Modify: `Sources/ZackEyes/AppDelegate.swift`

- [ ] **Step 1: Load visibility at startup + pass to controller inits**

In `applicationDidFinishLaunching`, find the block that loads hotkey config and creates the two controller paths. Right before the `if NSScreen.main?.hasNotch == true` branch, read visibility once:

Before (current, lines ~85-112 in original file):

```swift
if NSScreen.main?.hasNotch == true {
    let wc = NotchWindowController(viewModel: viewModel, usageTracker: usageTracker)
    // Gear in the expanded panel pops the same StatusBarMenu as
    ...
    wc.setup()
    windowController = wc
    mb.onIconClick = { [weak wc] in wc?.forceExpand() }
} else {
    // Simulated Dynamic Island at top center
    let sn = SimulatedNotchController(
        viewModel: viewModel,
        usageTracker: usageTracker,
        updateChecker: uc
    )
    sn.setup()
    simulatedNotch = sn
    mb.onIconClick = { [weak sn] in sn?.toggleFull() }
}
```

Replace with:

```swift
// Load persisted visibility up front — passing it into the controller
// init avoids a first-frame flash where the panel would orderFront then
// immediately orderOut again on a .hidden startup.
let initialVisibility = ConfigStore().loadNotchVisibility()

if NSScreen.main?.hasNotch == true {
    let wc = NotchWindowController(
        viewModel: viewModel,
        usageTracker: usageTracker,
        initialVisibility: initialVisibility
    )
    wc.showMenu = { [weak statusMenu] view in
        guard let menu = statusMenu?.build() else { return }
        let anchor = NSPoint(x: view.bounds.minX, y: view.bounds.minY - 2)
        menu.popUp(positioning: nil, at: anchor, in: view)
    }
    wc.setup()
    windowController = wc
    mb.onIconClick = { [weak wc] in wc?.forceExpand() }
} else {
    let sn = SimulatedNotchController(
        viewModel: viewModel,
        usageTracker: usageTracker,
        updateChecker: uc,
        initialVisibility: initialVisibility
    )
    sn.setup()
    simulatedNotch = sn
    mb.onIconClick = { [weak sn] in sn?.toggleFull() }
}
```

- [ ] **Step 2: Add `.notchVisibilityChanged` observer**

Find the existing `.hotkeyConfigChanged` observer block (around line 135-148 in original):

```swift
// Listen for hotkey config changes from the recorder UI
NotificationCenter.default.addObserver(
    forName: .hotkeyConfigChanged,
    object: nil,
    queue: .main
) { [weak self] notification in
    let config = notification.userInfo?["config"] as? HotKeyConfig
    Task { @MainActor in
        guard let self, let config else { return }
        self.hotKeyManager?.reregister(
            keyCode: config.keyCode,
            modifiers: config.modifiers.carbonFlags
        )
    }
}
```

Add immediately after it:

```swift
// Listen for visibility changes from the menu toggle.
NotificationCenter.default.addObserver(
    forName: .notchVisibilityChanged,
    object: nil,
    queue: .main
) { [weak self] notification in
    let visibility = notification.userInfo?["visibility"] as? NotchVisibility ?? .always
    Task { @MainActor in
        guard let self else { return }
        self.windowController?.applyVisibility(visibility)
        self.simulatedNotch?.applyVisibility(visibility)
    }
}
```

- [ ] **Step 3: Verify build**

Run: `swift build`
Expected: build succeeds.

- [ ] **Step 4: Commit**

```bash
git add Sources/ZackEyes/AppDelegate.swift
git commit -m "$(cat <<'EOF'
feat(app): load NotchVisibility at startup and observe changes

Passes initial visibility into controller inits so hidden-mode launches
don't flash the panel on screen before ordering out. Installs a
NotificationCenter observer that forwards .notchVisibilityChanged to
both controller paths.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Add "Show Dynamic Island" toggle to `StatusBarMenu`

**Files:**
- Modify: `Sources/AppLib/MenuBar/StatusBarMenu.swift`

- [ ] **Step 1: Add menu item to `build()`**

Find the section in `build()` that adds About / Change Hotkey / Theme. Current:

```swift
let about = NSMenuItem(
    title: "About",
    action: #selector(aboutClicked(_:)),
    keyEquivalent: ""
)
about.target = self
menu.addItem(about)

let hotkey = NSMenuItem(
    title: "Change Hotkey…",
    action: #selector(hotkeyClicked(_:)),
    keyEquivalent: ""
)
hotkey.target = self
menu.addItem(hotkey)

menu.addItem(themeSubmenuItem())
menu.addItem(.separator())
```

Replace with:

```swift
let about = NSMenuItem(
    title: "About",
    action: #selector(aboutClicked(_:)),
    keyEquivalent: ""
)
about.target = self
menu.addItem(about)

let hotkey = NSMenuItem(
    title: "Change Hotkey…",
    action: #selector(hotkeyClicked(_:)),
    keyEquivalent: ""
)
hotkey.target = self
menu.addItem(hotkey)

let visibility = ConfigStore().loadNotchVisibility()
let showIsland = NSMenuItem(
    title: "Show Dynamic Island",
    action: #selector(toggleVisibilityClicked(_:)),
    keyEquivalent: ""
)
showIsland.target = self
showIsland.state = (visibility == .always) ? .on : .off
menu.addItem(showIsland)

menu.addItem(themeSubmenuItem())
menu.addItem(.separator())
```

- [ ] **Step 2: Add the `@objc` action handler**

Add as a new method alongside the other `@objc private func` actions (e.g. after `hotkeyClicked`):

```swift
@objc private func toggleVisibilityClicked(_ sender: Any?) {
    let store = ConfigStore()
    let current = store.loadNotchVisibility()
    let next: NotchVisibility = (current == .always) ? .hidden : .always
    store.saveNotchVisibility(next)
    NotificationCenter.default.post(
        name: .notchVisibilityChanged,
        object: nil,
        userInfo: ["visibility": next]
    )
}
```

- [ ] **Step 3: Verify build**

Run: `swift build`
Expected: build succeeds.

- [ ] **Step 4: Commit**

```bash
git add Sources/AppLib/MenuBar/StatusBarMenu.swift
git commit -m "$(cat <<'EOF'
feat(menu): add Show Dynamic Island toggle

Checkmark reflects current visibility; click flips it, persists via
ConfigStore, and broadcasts .notchVisibilityChanged so both controller
paths can react. Covered by the shared StatusBarMenu.build() so menu-bar
right-click, real-notch gear, and simulated-notch gear all gain the item.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Swap menu-bar icon `sparkles` → `star.fill`

**Files:**
- Modify: `Sources/AppLib/MenuBar/MenuBarFallback.swift`

- [ ] **Step 1: Change the SF Symbol**

In `updateIcon(for:)`, find:

```swift
guard let image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "ZackEyes") else {
    return
}
```

Replace with:

```swift
guard let image = NSImage(systemSymbolName: "star.fill", accessibilityDescription: "ZackEyes") else {
    return
}
```

Nothing else in the method needs to change — `isTemplate = true`, state-based tinting, and the return path are all icon-agnostic.

- [ ] **Step 2: Verify build**

Run: `swift build`
Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/AppLib/MenuBar/MenuBarFallback.swift
git commit -m "$(cat <<'EOF'
feat(menu): swap status-bar icon to star.fill

Aligns the menu-bar icon with the app logo's five-point star. Remains a
template image; state tinting (.waiting orange, .working teal, .idle
untinted) is unchanged.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: Full build + test sweep

- [ ] **Step 1: Full test run**

Run: `swift test`
Expected: all tests pass (including new `ConfigStoreTests` and untouched existing suites).

- [ ] **Step 2: Full build**

Run: `make app`
Expected: `.app` bundle assembled successfully.

- [ ] **Step 3: Launch the app**

Run: `make run`
Expected: ZackEyes launches, menu-bar star icon appears.

---

## Task 10: Manual verification (end-to-end)

> This task has no commits — it's a sign-off checklist. Report any failures and stop.

- [ ] **Menu appearance**: Right-click the menu-bar star icon. Menu shows `About` / `Change Hotkey…` / `✓ Show Dynamic Island` / `Theme ▶` / `Quit ZackEyes`.

- [ ] **Icon is star**: Confirm the menu-bar icon is a filled star (not sparkles). Verify on both light and dark menu bars (switch macOS appearance).

- [ ] **State tint still works**: Trigger a session (run `claude` in a test cwd). Icon goes teal during work. Trigger a permission request. Icon goes orange. Resolve. Icon returns to untinted.

- [ ] **Toggle to hidden (simulated notch)**: On a notchless Mac (or external display configured as primary), click `Show Dynamic Island` to remove the ✓. The 220×32 pill disappears from the screen top immediately.

- [ ] **Toggle to hidden (real notch)**: On a MacBook with a physical notch, click the toggle. The panel disappears — content that normally shows in the notch row (buddy avatar, usage dots) is no longer visible.

- [ ] **Hover does NOT recall**: In hidden mode, move the mouse to the top-center of the screen (simulated) or into the physical notch row (real). Nothing happens.

- [ ] **Hotkey recalls**: Press `⌘⇧/` (or the configured hotkey). Panel expands to full. Move mouse away / click outside. Panel collapses and immediately orders off-screen.

- [ ] **Menu-bar click recalls**: Left-click the star icon. Panel expands. Click away. Collapses + off-screen.

- [ ] **PermissionRequest recalls**: In a separate terminal run:
  ```bash
  echo '{"hook_event_name":"PermissionRequest","session_id":"test-vis","cwd":"/tmp","tool_name":"Bash","tool_input":{"command":"ls"}}' | \
    $(swift build --show-bin-path)/bridge --event PermissionRequest
  ```
  Panel expands with the permission prompt. Click Allow/Deny. Panel collapses + off-screen.

- [ ] **Error recalls**: Trigger a session error (e.g. invalid tool call via bridge), panel auto-expands, collapses back to hidden.

- [ ] **Persistence**: Quit app, relaunch (`make run`). Visibility is still hidden. Toggle back to `✓ Show Dynamic Island`. Quit + relaunch. State is restored to always.

- [ ] **Welcome onboarding one-shot**: `defaults delete com.riseunion.zackeyes ZEWelcomeShownForVersion 2>/dev/null` (or whatever key the WelcomeTrigger uses — check its source). Relaunch with visibility `.hidden`. Welcome expands, 3s later collapses, panel returns to hidden.

- [ ] **Multi-screen**: With hidden + multiple displays, disconnect and reconnect an external monitor. Panel should not reappear — still off-screen on the recreated primary screen.

- [ ] **No regressions**: With `.always` (default), all prior behaviors (hover expand / compact pill visible / gear menus / welcome) work as before.

---

## Self-Review Notes

- **Spec coverage**: Tasks 1–8 cover every section of the spec (data model, behavior, UI entry, propagation, menu-bar icon). Tasks 9–10 cover the testing section. Known Risks item "first launch flash" is addressed by init-injection in Tasks 4, 5, 6.
- **Placeholder check**: No TBDs. Every code step contains full code. One test in Task 2 notes a conditional case substitution for `BuddyTheme`; implementer can read `Sources/AppLib/Notch/` or wherever BuddyTheme lives to pick a valid non-default case.
- **Type consistency**: `NotchVisibility` / `loadNotchVisibility` / `saveNotchVisibility` / `applyVisibility` / `.notchVisibilityChanged` used identically everywhere. `initialVisibility` parameter name consistent across both controllers. `userInfo["visibility"]` key used in both post and observer.
