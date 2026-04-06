import Foundation
import UserNotifications
import AppKit

/// Manages macOS user notifications for session events.
@MainActor
public final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {

    public static let shared = NotificationManager()

    /// Called when the user taps a notification. Payload is the session ID.
    public var onSessionTap: ((String) -> Void)?

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
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

    /// Post a notification when a session finishes its turn.
    public func notifySessionFinished(sessionId: String, projectName: String, lastPrompt: String?) {
        let content = UNMutableNotificationContent()
        content.title = "\(projectName) — done"
        if let prompt = lastPrompt, !prompt.isEmpty {
            let clipped = prompt.count > 100 ? String(prompt.prefix(100)) + "..." : prompt
            content.body = clipped
        } else {
            content.body = "Claude finished its turn"
        }
        content.sound = .default
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
        let sessionId = response.notification.request.content.userInfo["sessionId"] as? String
        // Call completion immediately — we don't need to block the framework
        completionHandler()
        Task { @MainActor [weak self] in
            if let sessionId = sessionId {
                self?.onSessionTap?(sessionId)
            }
        }
    }
}
