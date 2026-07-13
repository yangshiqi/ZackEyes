import Foundation
import Shared
import Testing
@testable import AppLib

@MainActor
struct SettingsViewModelTests {
    private final class NotificationRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var notifications: [Notification] = []

        func record(_ notification: Notification) {
            lock.lock()
            notifications.append(notification)
            lock.unlock()
        }
    }

    @Test
    func generalSettingsPersistAndUpdateLiveUsage() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zackeyes-settings-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ConfigStore(directory: directory.path)
        let usage = UsageTracker(projectsDir: directory, codexSessionsDir: nil)
        let model = SettingsViewModel(
            configStore: store,
            usageTracker: usage,
            hasPhysicalNotch: false,
            hookHealthProvider: healthyReport
        )

        model.setVisibility(.whenActive)
        model.setCompactAgent(.codex)
        model.setShowTodayConsumption(false)
        model.setTimeProgressMode(.overlap)
        model.setProgressMode(.left)
        model.setLeftProgressDirection(.rightToLeft)
        model.setTimeOverlayOpacity(0.44)
        model.setNotifyWaitingForInput(false)

        #expect(store.loadNotchVisibility() == .whenActive)
        #expect(store.loadCompactAgent() == .codex)
        #expect(store.loadShowTodayConsumption() == false)
        #expect(usage.showTodayConsumption == false)
        #expect(store.loadTimeProgressMode() == .overlap)
        #expect(usage.timeProgressMode == .overlap)
        #expect(store.loadProgressMode() == .left)
        #expect(usage.progressMode == .left)
        #expect(store.loadLeftProgressDirection() == .rightToLeft)
        #expect(usage.leftProgressDirection == .rightToLeft)
        #expect(store.loadTimeOverlayOpacity() == 0.4)
        #expect(usage.timeOverlayOpacity == 0.4)
        #expect(store.loadNotifyWaitingForInput() == false)
    }

    @Test
    func appearanceChangesPersistAndThemeResetsSound() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zackeyes-settings-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ConfigStore(directory: directory.path)
        store.saveNotificationSound("none")
        let model = SettingsViewModel(
            configStore: store,
            usageTracker: UsageTracker(projectsDir: directory, codexSessionsDir: nil),
            hookHealthProvider: healthyReport
        )

        model.setTheme(.f1)
        #expect(store.loadTheme() == .f1)
        #expect(store.loadNotificationSound() == nil)
        #expect(model.notificationSound == BuddyTheme.f1.defaultSoundFile)

        model.setNotificationSound("none")
        #expect(store.loadNotificationSound() == "none")
    }

    @Test
    func runtimeNotificationsCarryUpdatedValues() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zackeyes-settings-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let center = NotificationCenter()
        let recorder = NotificationRecorder()
        let names: [Notification.Name] = [
            .notchVisibilityChanged,
            .compactAgentChanged,
            .settingsAppearanceChanged,
        ]
        let tokens = names.map { name in
            center.addObserver(forName: name, object: nil, queue: nil) {
                recorder.record($0)
            }
        }
        defer { tokens.forEach(center.removeObserver) }

        let model = SettingsViewModel(
            configStore: ConfigStore(directory: directory.path),
            usageTracker: UsageTracker(projectsDir: directory, codexSessionsDir: nil),
            hasPhysicalNotch: false,
            hookHealthProvider: healthyReport,
            notificationCenter: center
        )

        model.setVisibility(.whenActive)
        model.setCompactAgent(.codex)
        model.setTheme(.f1)

        #expect(recorder.notifications.map(\.name) == names)
        #expect(recorder.notifications[0].userInfo?["visibility"] as? NotchVisibility == .whenActive)
        #expect(recorder.notifications[1].userInfo?["agent"] as? AgentKind == .codex)
        #expect(recorder.notifications[2].userInfo == nil)
    }

    @Test
    func displayConfigurationCanRefreshAfterScreenChanges() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zackeyes-settings-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let model = SettingsViewModel(
            configStore: ConfigStore(directory: directory.path),
            usageTracker: UsageTracker(projectsDir: directory, codexSessionsDir: nil),
            hasPhysicalNotch: false,
            hookHealthProvider: healthyReport
        )

        model.refreshDisplayConfiguration(hasPhysicalNotch: true)
        #expect(model.hasPhysicalNotch)
    }

    private func healthyReport() -> HookHealthReport {
        HookHealthReport(
            claudeHooks: .installed,
            codexHooks: .installed,
            bridgeLauncher: true,
            launcherResolvesApp: true,
            socketReachable: true,
            statusLine: .direct
        )
    }
}
