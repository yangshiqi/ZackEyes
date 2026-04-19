import Foundation

/// Pure logic for the first-launch welcome animation gating. Driven by the
/// app's `CFBundleShortVersionString`: fires once per version, persisted via
/// `UserDefaults`.
///
/// Injecting `UserDefaults` and the version string (rather than reading
/// `Bundle.main` directly) keeps this type unit-testable without touching
/// the user's real defaults.
public enum WelcomeTrigger {
    /// Key used in `UserDefaults` to persist the last version that played
    /// the welcome animation. Exposed so tests can read/write directly.
    public static let storageKey = "welcomeShownForVersion"

    /// Returns true when the welcome animation should play on this launch.
    /// - An unreadable bundle version (`nil`) is treated as "already shown"
    ///   so a degraded startup path never spams the user.
    public static func shouldShowWelcome(
        defaults: UserDefaults,
        currentVersion: String?
    ) -> Bool {
        guard let currentVersion else { return false }
        let stored = defaults.string(forKey: storageKey)
        return stored != currentVersion
    }

    /// Writes the current version to `UserDefaults` so future launches skip
    /// the welcome until the bundle version changes again. Nil is a no-op.
    public static func markShown(
        defaults: UserDefaults,
        currentVersion: String?
    ) {
        guard let currentVersion else { return }
        defaults.set(currentVersion, forKey: storageKey)
    }
}
