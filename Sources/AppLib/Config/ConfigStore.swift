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
        updateConfig { $0.theme = theme }
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
        updateConfig { $0.notificationSound = sound }
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
        guard let data = try? Self.makeEncoder().encode(wrapper) else { return }
        persist(data)
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
        guard let data = try? Self.makeEncoder().encode(wrapper) else { return }
        persist(data)
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
        guard let data = try? Self.makeEncoder().encode(wrapper) else { return }
        persist(data)
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
        guard let data = try? Self.makeEncoder().encode(wrapper) else { return }
        persist(data)
    }

    /// Load the elapsed-window presentation. Existing installs default to Off.
    public func loadTimeProgressMode() -> TimeProgressMode {
        guard let data = FileManager.default.contents(atPath: configPath),
              let wrapper = try? JSONDecoder().decode(ConfigWrapper.self, from: data),
              let raw = wrapper.timeProgressMode,
              let mode = TimeProgressMode(rawValue: raw) else {
            return .off
        }
        return mode
    }

    /// Save the elapsed-window presentation without touching other config keys.
    public func saveTimeProgressMode(_ mode: TimeProgressMode) {
        updateConfig { $0.timeProgressMode = mode.rawValue }
    }

    /// Load whether quota bars show used or remaining capacity.
    public func loadProgressMode() -> ProgressMode {
        guard let data = FileManager.default.contents(atPath: configPath),
              let wrapper = try? JSONDecoder().decode(ConfigWrapper.self, from: data),
              let raw = wrapper.progressMode else {
            return .used
        }
        // Keep accepting the prerelease value while all new saves use `used`.
        if raw == "spent" { return .used }
        return ProgressMode(rawValue: raw) ?? .used
    }

    public func saveProgressMode(_ mode: ProgressMode) {
        updateConfig { $0.progressMode = mode.rawValue }
    }

    /// Load the retained fill direction used by Left mode.
    public func loadLeftProgressDirection() -> LeftProgressDirection {
        guard let data = FileManager.default.contents(atPath: configPath),
              let wrapper = try? JSONDecoder().decode(ConfigWrapper.self, from: data),
              let raw = wrapper.leftProgressDirection,
              let direction = LeftProgressDirection(rawValue: raw) else {
            return .leftToRight
        }
        return direction
    }

    public func saveLeftProgressDirection(_ direction: LeftProgressDirection) {
        updateConfig { $0.leftProgressDirection = direction.rawValue }
    }

    /// Load the time-overlay opacity as a normalized tenth-step value.
    public func loadTimeOverlayOpacity() -> Double {
        guard let data = FileManager.default.contents(atPath: configPath),
              let wrapper = try? JSONDecoder().decode(ConfigWrapper.self, from: data),
              let opacity = wrapper.timeOverlayOpacity else {
            return TimeOverlayOpacity.defaultValue
        }
        return TimeOverlayOpacity.normalized(opacity)
    }

    public func saveTimeOverlayOpacity(_ opacity: Double) {
        let normalized = TimeOverlayOpacity.normalized(opacity)
        updateConfig { $0.timeOverlayOpacity = normalized }
    }

    /// Load whether to chime/notify when an agent blocks waiting on the user
    /// (a permission prompt or an AskUserQuestion choice). Defaults to `true`. See #169.
    public func loadNotifyWaitingForInput() -> Bool {
        guard let data = FileManager.default.contents(atPath: configPath),
              let wrapper = try? JSONDecoder().decode(ConfigWrapper.self, from: data) else {
            return true
        }
        return wrapper.notifyWaitingForInput ?? true
    }

    /// Save the waiting-notification preference. Same defensive contract as
    /// `saveShowTodayConsumption` (skip on parse failure; preserve other keys).
    public func saveNotifyWaitingForInput(_ enabled: Bool) {
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
        wrapper.notifyWaitingForInput = enabled
        guard let data = try? Self.makeEncoder().encode(wrapper) else { return }
        persist(data)
    }

    /// Save the hotkey config atomically. Preserves other keys.
    /// Creates directory if needed.
    public func save(_ config: HotKeyConfig) {
        updateConfig { $0.hotkey = config }
    }

    /// Stable key order. Without it every save re-encodes to different bytes,
    /// so the unchanged-content check never fires: config.json is rewritten on
    /// each launch and the one backup we keep gets rotated to a copy of the
    /// current value — losing the previous one, which is the whole point of
    /// keeping it.
    ///
    /// Built per call rather than shared: `ConfigStore` is `Sendable` and
    /// `JSONEncoder` is a mutable class, so one instance across concurrent saves
    /// is a data race for no gain — these writes are rare and tiny.
    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    /// Single exit for every config write.
    ///
    /// Six call sites each did their own `write(options: .atomic)`, which gets
    /// the rename right but leaves the bytes in the page cache, and config.json
    /// had no backup at all — settings.json has had timestamped ones for a while
    /// (#205). Keeping one backup here rather than a series: config.json is small
    /// and rewritten often, so a per-change history would be noise, but having
    /// *something* to fall back on costs one file.
    private func persist(_ data: Data) {
        let backupPath = configPath + ".backup"
        if let current = FileManager.default.contents(atPath: configPath), current != data {
            // If we cannot keep a copy, do not take the original away. Mirrors
            // HookInstaller, which has aborted on backup failure since
            // #129/F-014 — losing the save is recoverable, losing the config is
            // not.
            guard (try? AtomicFileWriter.write(current, to: backupPath)) != nil else { return }
        }
        do {
            _ = try AtomicFileWriter.write(data, to: configPath)
        } catch {
            // Callers are fire-and-forget setters with nowhere to show an error,
            // but a full disk or a permission problem should not be completely
            // invisible — without this the save simply appears not to have
            // happened. The app is running: NSLog here is fine (unlike in the
            // bridge, where it would reach the agent's terminal).
            NSLog("ZackEyes: could not save config.json — %@", "\(error)")
        }
    }

    private func updateConfig(_ update: (inout ConfigWrapper) -> Void) {
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
        update(&wrapper)
        guard let data = try? Self.makeEncoder().encode(wrapper) else { return }
        persist(data)
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
    var timeProgressMode: String?       // nil = off (elapsed quota-window presentation)
    var progressMode: String?           // nil = used (quota presentation)
    var leftProgressDirection: String?  // nil = leftToRight (Left-mode fill anchor)
    var timeOverlayOpacity: Double?     // nil = 0.4 (elapsed overlay opacity)
    var notifyWaitingForInput: Bool?    // nil = true (default — chime/notify when an agent blocks waiting on the user, #169)
}
