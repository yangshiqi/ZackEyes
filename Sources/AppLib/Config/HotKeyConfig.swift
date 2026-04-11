import AppKit
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
private func keyName(for keyCode: UInt32) -> String {
    switch Int(keyCode) {
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
