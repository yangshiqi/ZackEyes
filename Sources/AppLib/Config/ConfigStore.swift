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
        try? data.write(to: URL(fileURLWithPath: configPath), options: .atomic)
    }
}

/// Top-level JSON wrapper so config.json has `{ "hotkey": { ... } }` structure,
/// leaving room for future settings keys without breaking the file format.
private struct ConfigWrapper: Codable {
    var hotkey: HotKeyConfig
}
