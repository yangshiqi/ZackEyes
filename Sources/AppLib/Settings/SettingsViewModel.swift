import AppKit
import Combine
import Foundation
import Shared

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published private(set) var visibility: NotchVisibility
    @Published private(set) var compactAgent: AgentKind
    @Published private(set) var showTodayConsumption: Bool
    @Published private(set) var timeProgressMode: TimeProgressMode
    @Published private(set) var progressMode: ProgressMode
    @Published private(set) var leftProgressDirection: LeftProgressDirection
    @Published private(set) var timeOverlayOpacity: Double
    @Published private(set) var hotkey: HotKeyConfig
    @Published private(set) var theme: BuddyTheme
    @Published private(set) var notificationSound: String
    @Published private(set) var notifyWaitingForInput: Bool
    @Published private(set) var notchOffsetX: CGFloat
    @Published private(set) var hookHealth: HookHealthReport

    @Published private(set) var hasPhysicalNotch: Bool

    private let configStore: ConfigStore
    private let usageTracker: UsageTracker
    private let hookHealthProvider: () -> HookHealthReport
    private let notificationCenter: NotificationCenter
    private var previewSound: NSSound?

    init(
        configStore: ConfigStore = ConfigStore(),
        usageTracker: UsageTracker,
        hasPhysicalNotch: Bool = NSScreen.hasAnyNotch,
        hookHealthProvider: @escaping () -> HookHealthReport = { HookHealth().check() },
        notificationCenter: NotificationCenter = .default
    ) {
        self.configStore = configStore
        self.usageTracker = usageTracker
        self.hasPhysicalNotch = hasPhysicalNotch
        self.hookHealthProvider = hookHealthProvider
        self.notificationCenter = notificationCenter

        let loadedTheme = configStore.loadTheme()
        visibility = configStore.loadNotchVisibility()
        compactAgent = configStore.loadCompactAgent()
        showTodayConsumption = configStore.loadShowTodayConsumption()
        timeProgressMode = configStore.loadTimeProgressMode()
        progressMode = configStore.loadProgressMode()
        leftProgressDirection = configStore.loadLeftProgressDirection()
        timeOverlayOpacity = configStore.loadTimeOverlayOpacity()
        hotkey = configStore.load()
        theme = loadedTheme
        notificationSound = configStore.loadNotificationSound()
            ?? loadedTheme.defaultSoundFile
            ?? "none"
        notifyWaitingForInput = configStore.loadNotifyWaitingForInput()
        notchOffsetX = configStore.loadNotchOffsetX()
        hookHealth = hookHealthProvider()
    }

    func setVisibility(_ value: NotchVisibility) {
        guard value != visibility else { return }
        configStore.saveNotchVisibility(value)
        visibility = value
        notificationCenter.post(
            name: .notchVisibilityChanged,
            object: nil,
            userInfo: ["visibility": value]
        )
    }

    func setCompactAgent(_ value: AgentKind) {
        guard value != compactAgent else { return }
        configStore.saveCompactAgent(value)
        compactAgent = value
        notificationCenter.post(
            name: .compactAgentChanged,
            object: nil,
            userInfo: ["agent": value]
        )
    }

    func setShowTodayConsumption(_ enabled: Bool) {
        guard enabled != showTodayConsumption else { return }
        configStore.saveShowTodayConsumption(enabled)
        showTodayConsumption = enabled
        usageTracker.showTodayConsumption = enabled
    }

    func setTimeProgressMode(_ mode: TimeProgressMode) {
        guard mode != timeProgressMode else { return }
        configStore.saveTimeProgressMode(mode)
        timeProgressMode = mode
        usageTracker.timeProgressMode = mode
    }

    func setProgressMode(_ mode: ProgressMode) {
        guard mode != progressMode else { return }
        configStore.saveProgressMode(mode)
        progressMode = mode
        usageTracker.progressMode = mode
    }

    func setLeftProgressDirection(_ direction: LeftProgressDirection) {
        guard direction != leftProgressDirection else { return }
        configStore.saveLeftProgressDirection(direction)
        leftProgressDirection = direction
        usageTracker.leftProgressDirection = direction
    }

    func setTimeOverlayOpacity(_ opacity: Double) {
        let normalized = TimeOverlayOpacity.normalized(opacity)
        guard normalized != timeOverlayOpacity else { return }
        configStore.saveTimeOverlayOpacity(normalized)
        timeOverlayOpacity = normalized
        usageTracker.timeOverlayOpacity = normalized
    }

    func setTheme(_ value: BuddyTheme) {
        guard value != theme else { return }
        configStore.saveTheme(value)
        configStore.saveNotificationSound(nil)
        theme = value
        notificationSound = value.defaultSoundFile ?? "none"
        notificationCenter.post(name: .settingsAppearanceChanged, object: nil)
    }

    func setNotificationSound(_ value: String) {
        guard value != notificationSound else { return }
        configStore.saveNotificationSound(value)
        notificationSound = value
        previewNotificationSound()
    }

    func setNotifyWaitingForInput(_ enabled: Bool) {
        guard enabled != notifyWaitingForInput else { return }
        configStore.saveNotifyWaitingForInput(enabled)
        notifyWaitingForInput = enabled
    }

    func refreshHotkey() {
        hotkey = configStore.load()
    }

    func refreshDisplayConfiguration(hasPhysicalNotch: Bool = NSScreen.hasAnyNotch) {
        self.hasPhysicalNotch = hasPhysicalNotch
    }

    func beginNotchRepositioning() {
        notificationCenter.post(name: .notchMoveModeRequested, object: nil)
    }

    func resetNotchPosition() {
        configStore.saveNotchOffsetX(0)
        notchOffsetX = 0
        notificationCenter.post(name: .notchResetPositionRequested, object: nil)
    }

    func refreshHookHealth() {
        hookHealth = hookHealthProvider()
    }

    func repairHooks() {
        HookRepair.run(appPath: Bundle.main.bundlePath)
        refreshHookHealth()
    }

    func previewNotificationSound() {
        previewSound?.stop()
        guard notificationSound != "none",
              let url = Bundle.main.url(forResource: notificationSound, withExtension: "mp3") else {
            return
        }
        let sound = NSSound(contentsOf: url, byReference: true)
        sound?.play()
        previewSound = sound
    }
}

public extension Notification.Name {
    static let settingsWindowRequested = Notification.Name("settingsWindowRequested")
    static let settingsAppearanceChanged = Notification.Name("settingsAppearanceChanged")
}
