import Foundation
import Shared

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

    /// Load the active theme. Defaults to `.rock`.
    public func loadTheme() -> BuddyTheme {
        guard let data = FileManager.default.contents(atPath: configPath),
              let wrapper = try? JSONDecoder().decode(ConfigWrapper.self, from: data) else {
            return .rock
        }
        return wrapper.theme ?? .rock
    }

    /// Save the active theme. Preserves other keys.
    public func saveTheme(_ theme: BuddyTheme) {
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
        wrapper.theme = theme
        guard let data = try? JSONEncoder().encode(wrapper) else { return }
        try? data.write(to: URL(fileURLWithPath: configPath), options: .atomic)
    }

    /// Load the selected notification sound filename. Returns nil if none
    /// explicitly set (caller should use theme default).
    public func loadNotificationSound() -> String? {
        guard let data = FileManager.default.contents(atPath: configPath),
              let wrapper = try? JSONDecoder().decode(ConfigWrapper.self, from: data) else {
            return nil
        }
        return wrapper.notificationSound
    }

    /// Save the selected notification sound. Preserves other keys.
    public func saveNotificationSound(_ sound: String?) {
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
        wrapper.notificationSound = sound
        guard let data = try? JSONEncoder().encode(wrapper) else { return }
        try? data.write(to: URL(fileURLWithPath: configPath), options: .atomic)
    }

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
    ///
    /// Safety: if `config.json` exists but cannot be decoded (e.g. corrupt
    /// JSON), abort the save instead of seeding defaults. Seeding defaults
    /// would overwrite `theme` / `notificationSound` the user can still
    /// recover if we leave the file untouched. Asymmetric with sibling saves
    /// for now; unifying that pattern is a follow-up.
    public func saveNotchVisibility(_ visibility: NotchVisibility) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory) {
            try? fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
        var wrapper: ConfigWrapper
        if fm.fileExists(atPath: configPath) {
            guard let data = fm.contents(atPath: configPath),
                  let existing = try? JSONDecoder().decode(ConfigWrapper.self, from: data) else {
                return  // corrupt file — don't clobber other fields
            }
            wrapper = existing
        } else {
            wrapper = ConfigWrapper(hotkey: .default)
        }
        wrapper.notchVisibility = visibility.rawValue
        guard let data = try? JSONEncoder().encode(wrapper) else { return }
        try? data.write(to: URL(fileURLWithPath: configPath), options: .atomic)
    }

    /// Load which agent's quota the collapsed simulated notch should
    /// display. Defaults to `.claude` (preserves the pre-existing UX for
    /// any user who hasn't picked a side yet).
    public func loadCompactAgent() -> AgentKind {
        guard let data = FileManager.default.contents(atPath: configPath),
              let wrapper = try? JSONDecoder().decode(ConfigWrapper.self, from: data),
              let raw = wrapper.compactAgent,
              let agent = AgentKind(rawValue: raw) else {
            return .claude
        }
        return agent
    }

    /// Save the compact-notch agent preference. Same defensive contract as
    /// `saveNotchVisibility` — bail rather than clobber a corrupt file.
    public func saveCompactAgent(_ agent: AgentKind) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory) {
            try? fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
        var wrapper: ConfigWrapper
        if fm.fileExists(atPath: configPath) {
            guard let data = fm.contents(atPath: configPath),
                  let existing = try? JSONDecoder().decode(ConfigWrapper.self, from: data) else {
                return
            }
            wrapper = existing
        } else {
            wrapper = ConfigWrapper(hotkey: .default)
        }
        wrapper.compactAgent = agent.rawValue
        guard let data = try? JSONEncoder().encode(wrapper) else { return }
        try? data.write(to: URL(fileURLWithPath: configPath), options: .atomic)
    }

    /// Load the simulated-notch horizontal offset from screen-center, in
    /// points (positive = right of center, negative = left). Returns 0
    /// (centered — the original fixed position) on any failure or when the
    /// field is absent (pre-existing installs).
    public func loadNotchOffsetX() -> CGFloat {
        guard let data = FileManager.default.contents(atPath: configPath),
              let wrapper = try? JSONDecoder().decode(ConfigWrapper.self, from: data),
              let x = wrapper.notchOffsetX else {
            return 0
        }
        return CGFloat(x)
    }

    /// Save the simulated-notch horizontal offset. Same defensive contract as
    /// `saveNotchVisibility` — bail rather than clobber a corrupt file.
    public func saveNotchOffsetX(_ offset: CGFloat) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory) {
            try? fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
        var wrapper: ConfigWrapper
        if fm.fileExists(atPath: configPath) {
            guard let data = fm.contents(atPath: configPath),
                  let existing = try? JSONDecoder().decode(ConfigWrapper.self, from: data) else {
                return  // corrupt file — don't clobber other fields
            }
            wrapper = existing
        } else {
            wrapper = ConfigWrapper(hotkey: .default)
        }
        wrapper.notchOffsetX = Double(offset)
        guard let data = try? JSONEncoder().encode(wrapper) else { return }
        try? data.write(to: URL(fileURLWithPath: configPath), options: .atomic)
    }

    /// Load whether the expanded Today consumption row is shown. Defaults to `true`.
    public func loadShowTodayConsumption() -> Bool {
        guard let data = FileManager.default.contents(atPath: configPath),
              let wrapper = try? JSONDecoder().decode(ConfigWrapper.self, from: data) else {
            return true
        }
        return wrapper.showTodayConsumption ?? true
    }

    /// Save the Today-row preference. Same defensive contract as `saveCompactAgent`.
    public func saveShowTodayConsumption(_ enabled: Bool) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory) {
            try? fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
        var wrapper: ConfigWrapper
        if fm.fileExists(atPath: configPath) {
            guard let data = fm.contents(atPath: configPath),
                  let existing = try? JSONDecoder().decode(ConfigWrapper.self, from: data) else {
                return
            }
            wrapper = existing
        } else {
            wrapper = ConfigWrapper(hotkey: .default)
        }
        wrapper.showTodayConsumption = enabled
        guard let data = try? JSONEncoder().encode(wrapper) else { return }
        try? data.write(to: URL(fileURLWithPath: configPath), options: .atomic)
    }

    /// Save the hotkey config atomically. Preserves other keys.
    /// Creates directory if needed.
    public func save(_ config: HotKeyConfig) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory) {
            try? fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
        // Read existing config to preserve other keys
        var wrapper: ConfigWrapper
        if let data = fm.contents(atPath: configPath),
           let existing = try? JSONDecoder().decode(ConfigWrapper.self, from: data) {
            wrapper = existing
        } else {
            wrapper = ConfigWrapper(hotkey: .default)
        }
        wrapper.hotkey = config
        guard let data = try? JSONEncoder().encode(wrapper) else { return }
        try? data.write(to: URL(fileURLWithPath: configPath), options: .atomic)
    }
}

/// Top-level JSON wrapper for ~/.zackeyes/config.json.
/// All known keys are modeled here so save() preserves them.
private struct ConfigWrapper: Codable {
    var hotkey: HotKeyConfig
    var theme: BuddyTheme?              // nil = .rock (default)
    var notificationSound: String?      // nil = theme default sound
    var notchVisibility: String?        // nil = .always (default)
    var compactAgent: String?           // nil = .claude (default — agent shown in collapsed simulated notch)
    var notchOffsetX: Double?           // nil = 0 (centered — simulated notch horizontal offset from screen-center)
    var showTodayConsumption: Bool?     // nil = true (default — show the #84 Today row)
}
