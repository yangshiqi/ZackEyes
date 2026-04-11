# Custom Hotkey Design

## Goal

Let users change the global toggle hotkey (default `Cmd+Shift+Z`) via a key recorder UI in the gear menu, persisted to `~/.zackeyes/config.json`.

## Scope

Only the global panel toggle hotkey. No other settings.

## Data Model & Persistence

### Config file: `~/.zackeyes/config.json`

```json
{
  "hotkey": {
    "keyCode": 6,
    "modifiers": ["command", "shift"]
  }
}
```

- `keyCode`: Carbon virtual key code integer (`kVK_ANSI_Z` = 6)
- `modifiers`: human-readable string array — valid values: `"command"`, `"shift"`, `"option"`, `"control"`
- File missing or parse failure → fall back to default `Cmd+Shift+Z`, no error shown
- Config directory `~/.zackeyes/` already exists (used by launcher script)

### ConfigStore (`Sources/AppLib/Config/ConfigStore.swift`)

- `load() -> HotKeyConfig` — reads and decodes JSON, returns default on any failure
- `save(_ config: HotKeyConfig)` — encodes and writes atomically
- Path: `~/.zackeyes/config.json`
- No caching — reads from disk each time (called once at startup, once on save)

### HotKeyConfig (`Sources/AppLib/Config/HotKeyConfig.swift`)

```swift
struct HotKeyConfig: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: HotKeyModifiers
    static let `default` = HotKeyConfig(keyCode: UInt32(kVK_ANSI_Z), modifiers: [.command, .shift])
}

struct HotKeyModifiers: OptionSet, Codable, Equatable {
    let rawValue: UInt32
    static let command  = HotKeyModifiers(rawValue: 1 << 0)
    static let shift    = HotKeyModifiers(rawValue: 1 << 1)
    static let option   = HotKeyModifiers(rawValue: 1 << 2)
    static let control  = HotKeyModifiers(rawValue: 1 << 3)

    /// Convert to Carbon modifier flags (cmdKey, shiftKey, optionKey, controlKey)
    var carbonFlags: UInt32 { ... }

    /// Encode as ["command", "shift"] string array
    /// Decode from same format
}
```

## Key Recorder UI

### Entry point

Gear menu in `SimulatedNotchFullView` gets a new item: **"Change Hotkey…"** between "About" and "Quit ZackEyes".

### Overlay: `HotkeyRecorderView`

Displayed as an overlay in `SimulatedNotchFullView`, same pattern as the About overlay.

Layout:
- Current hotkey display (e.g. `⌘⇧Z`) — large, centered
- "Press new shortcut…" prompt text
- Live preview of captured key combo during recording
- **Save** and **Cancel** buttons

### Key capture

- `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` — starts when overlay appears
- Monitor removed when overlay dismissed
- Captures `event.keyCode` + `event.modifierFlags`
- Validation: must include at least one modifier (Cmd/Opt/Ctrl/Shift) — reject bare letter keys with a shake or hint text

### State

`NotchModeStore` gains `isHotkeyRecorderShown: Bool`, same pattern as `isAboutShown`.

`GearMenuTarget` gains a `hotkeyClicked()` handler.

## HotKeyManager Changes

Current API:
```swift
func register(onTrigger: @escaping () -> Void)
```

New API:
```swift
func register(keyCode: UInt32, modifiers: UInt32, onTrigger: @escaping () -> Void)
func reregister(keyCode: UInt32, modifiers: UInt32)
func unregister()  // unchanged
```

- `reregister` calls `unregister()` then re-registers with new key/modifiers, preserving the existing `onTrigger` callback
- No app restart needed

## AppDelegate Changes

Startup sequence change:

```
// Before:
hk.register(onTrigger: toggleCallback)

// After:
let config = ConfigStore().load()
hk.register(keyCode: config.keyCode, modifiers: config.modifiers.carbonFlags, onTrigger: toggleCallback)
```

## Interaction Flow

### Startup
```
AppDelegate
  → ConfigStore.load()
  → HotKeyManager.register(keyCode, modifiers, onTrigger)
```

### User changes hotkey
```
Gear menu "Change Hotkey…"
  → isHotkeyRecorderShown = true
  → overlay appears, NSEvent monitor starts
  → user presses key combo → live preview
  → user clicks Save
  → ConfigStore.save(newConfig)
  → HotKeyManager.reregister(keyCode, modifiers)
  → isHotkeyRecorderShown = false
```

### User cancels
```
Clicks Cancel or presses Escape → overlay dismissed, no changes
```

## Files Changed

| File | Change |
|------|--------|
| **New** `Sources/AppLib/Config/ConfigStore.swift` | Read/write `~/.zackeyes/config.json` |
| **New** `Sources/AppLib/Config/HotKeyConfig.swift` | `HotKeyConfig` + `HotKeyModifiers` types |
| **New** `Sources/AppLib/Notch/HotkeyRecorderView.swift` | SwiftUI key recorder overlay |
| **Mod** `Sources/AppLib/HotKey/HotKeyManager.swift` | Parameterized register, add reregister |
| **Mod** `Sources/AppLib/SimulatedNotch/SimulatedNotchFullView.swift` | Gear menu + overlay |
| **Mod** `Sources/AppLib/SimulatedNotch/SimulatedNotchRoot.swift` | `isHotkeyRecorderShown` state |
| **Mod** `Sources/AppLib/SimulatedNotch/GearMenuTarget.swift` | `hotkeyClicked()` handler |
| **Mod** `Sources/ZackEyes/AppDelegate.swift` | Load config at startup |

## Display Formatting

Modifier symbols for UI display:
- Command → `⌘`
- Shift → `⇧`
- Option → `⌥`
- Control → `⌃`

Key name from `keyCode` via a lookup table (A-Z, 0-9, F1-F12, common special keys).

## Edge Cases

- **Config file corrupt** → fall back to default, overwrite on next save
- **Conflicting hotkey** (another app already registered it) → Carbon `RegisterEventHotKey` returns error, keep old hotkey, show brief error text in overlay
- **User sets same key as current** → no-op, just close overlay
- **Modifier-only combo** (e.g. just Cmd+Shift without a letter) → don't accept, wait for a key
