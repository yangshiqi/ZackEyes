import Foundation
import UserNotifications
import AppKit

/// Manages macOS user notifications for session events.
@MainActor
public final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {

    public static let shared = NotificationManager()

    /// Called when the user taps a notification. Payload is the session ID.
    public var onSessionTap: ((String) -> Void)?

    /// Called when the user taps an update notification. Payload is the release URL.
    public var onUpdateTap: ((URL) -> Void)?

    /// Cache of loaded NSSound objects keyed by filename. Populated
    /// lazily when a theme's soundFile is first requested.
    private var soundCache: [String: NSSound] = [:]

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    /// Load and play the selected notification sound for the current theme.
    /// Returns true if a custom sound was played; false means the caller
    /// should fall back to the system notification sound.
    private func playThemeSound() -> Bool {
        let config = ConfigStore()
        let theme = config.loadTheme()
        // User-selected sound, or theme default
        let file = config.loadNotificationSound() ?? theme.defaultSoundFile
        guard let file else { return false }
        // "none" = explicit silence
        if file == "none" { return true }
        // Verify the sound belongs to the current theme's available set
        guard theme.availableSounds.contains(where: { $0.file == file }) else {
            if let fallback = theme.defaultSoundFile, fallback != "none" {
                return playFile(fallback)
            }
            return false
        }
        return playFile(file)
    }

    private func playFile(_ file: String) -> Bool {
        if soundCache[file] == nil {
            guard let url = Bundle.main.url(forResource: file, withExtension: "mp3") else {
                return false
            }
            soundCache[file] = NSSound(contentsOf: url, byReference: true)
        }
        soundCache[file]?.play()
        return true
    }

    /// Request permission on app startup.
    public func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                NSLog("ZackEyes: notification auth error: %@", error.localizedDescription)
            }
            NSLog("ZackEyes: notification auth granted=%@", granted ? "true" : "false")
        }
    }

    /// Post a critical notification when Claude hits an API error / rate limit.
    public func notifyError(sessionId: String, projectName: String, errorLabel: String, detail: String?) {
        let content = UNMutableNotificationContent()
        content.title = "⚠️ \(projectName) — \(errorLabel)"
        content.body = Self.sanitizePrompt(detail, fallback: "Claude Code hit an API error. Click to jump to the terminal.", maxLength: 140)
        if playThemeSound() {
            content.sound = nil
        } else {
            content.sound = .defaultCritical
        }
        content.interruptionLevel = .timeSensitive
        content.userInfo = ["sessionId": sessionId]

        let request = UNNotificationRequest(
            identifier: "session-error-\(sessionId)-\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                NSLog("ZackEyes: error notification post failed: %@", error.localizedDescription)
            }
        }
    }

    /// Post a notification when a session finishes its turn.
    public func notifySessionFinished(sessionId: String, projectName: String, lastPrompt: String?) {
        let content = UNMutableNotificationContent()
        content.title = "\(projectName) — done"
        let body = Self.sanitizePrompt(lastPrompt)
        content.body = body
        if playThemeSound() {
            content.sound = nil
        } else {
            content.sound = .default
        }
        content.userInfo = ["sessionId": sessionId]

        let request = UNNotificationRequest(
            identifier: "session-done-\(sessionId)-\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                NSLog("ZackEyes: notification post error: %@", error.localizedDescription)
            }
        }
    }

    /// Post a notification for a new app version. Only sends once per version
    /// (tracked via UserDefaults).
    public func notifyUpdateAvailable(version: String, releaseURL: URL) {
        let lastNotified = UserDefaults.standard.string(forKey: "lastNotifiedVersion")
        guard lastNotified != version else { return }

        let content = UNMutableNotificationContent()
        content.title = "ZackEyes Update Available"
        content.body = "Version \(version) is available. Click to download."
        content.sound = .default
        content.categoryIdentifier = "update"
        content.userInfo = ["releaseURL": releaseURL.absoluteString]

        let request = UNNotificationRequest(
            identifier: "update-\(version)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                NSLog("ZackEyes: update notification failed: %@", error.localizedDescription)
            }
        }
        UserDefaults.standard.set(version, forKey: "lastNotifiedVersion")
    }

    // MARK: - Sanitize

    /// Clean up a prompt/detail string for notification display.
    /// Strips system messages (XML tags like <task-notification>, <system-reminder>)
    /// that leak into lastUserPrompt when Claude Code processes subagent results.
    static func sanitizePrompt(
        _ text: String?,
        fallback: String = "Claude finished its turn",
        maxLength: Int = 100
    ) -> String {
        guard let text = text, !text.isEmpty else { return fallback }
        // System/internal messages start with < and contain XML-like tags
        if text.hasPrefix("<") && text.contains("</") { return fallback }
        let clipped = text.count > maxLength ? String(text.prefix(maxLength)) + "..." : text
        return clipped
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Show banner even when app is foreground
        completionHandler([.banner, .sound])
    }

    nonisolated public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let sessionId = userInfo["sessionId"] as? String
        let releaseURLString = userInfo["releaseURL"] as? String
        completionHandler()
        Task { @MainActor [weak self] in
            if let releaseURLString, let url = URL(string: releaseURLString) {
                self?.onUpdateTap?(url)
            } else if let sessionId {
                self?.onSessionTap?(sessionId)
            }
        }
    }
}
