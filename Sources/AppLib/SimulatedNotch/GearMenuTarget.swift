import AppKit
import Shared

/// Tiny @objc target for the gear NSMenu items. We use a single shared
/// instance so each menu item can wire its action via `#selector` without
/// needing per-item @objc subclasses or closure bridging.
///
/// `modeStore` is bound right before the menu is popped so the About
/// handler flips `isAboutShown` on the same store the SwiftUI view
/// observes.
@MainActor
final class GearMenuTarget: NSObject {
    static let shared = GearMenuTarget()
    weak var modeStore: NotchModeStore?
    weak var usageTracker: UsageTracker?
    weak var updateChecker: UpdateChecker?
    var releaseURL: URL?
    var dmgURL: URL?
    var downloader: UpdateDownloader?
    private var previewSound: NSSound?
    private var hookStatusWindow: HookStatusWindow?
    private var uninstallWindow: UninstallWindow?

    @objc func aboutClicked(_ sender: Any?) {
        modeStore?.isMenuOpen = false
        modeStore?.isAboutShown = true
    }

    @objc func hotkeyClicked(_ sender: Any?) {
        modeStore?.isMenuOpen = false
        modeStore?.isHotkeyRecorderShown = true
    }

    @objc func hookStatusClicked(_ sender: Any?) {
        // Standalone window (not an in-panel overlay): the status card needs
        // to outlive the notch's hover-collapse, and one implementation can
        // then serve both menu surfaces.
        modeStore?.isMenuOpen = false
        if hookStatusWindow == nil {
            hookStatusWindow = HookStatusWindow()
        }
        hookStatusWindow?.show()
    }

    @objc func uninstallClicked(_ sender: Any?) {
        modeStore?.isMenuOpen = false
        if uninstallWindow == nil {
            uninstallWindow = UninstallWindow()
        }
        uninstallWindow?.show()
    }

    @objc func updateClicked(_ sender: Any?) {
        modeStore?.isMenuOpen = false
        if let dmgURL, let downloader {
            Task { @MainActor in await downloader.download(from: dmgURL) }
        } else if let releaseURL {
            // No DMG yet — fall back to opening the release page.
            NSWorkspace.shared.open(releaseURL)
        }
    }

    @objc func visibilityOptionClicked(_ sender: Any?) {
        modeStore?.isMenuOpen = false
        guard let item = sender as? NSMenuItem,
              let raw = item.representedObject as? String,
              let v = NotchVisibility(rawValue: raw) else { return }
        ConfigStore().saveNotchVisibility(v)
        NotificationCenter.default.post(
            name: .notchVisibilityChanged, object: nil,
            userInfo: ["visibility": v]
        )
        // Update checkmarks on the visibility submenu
        for sibling in item.menu?.items ?? [] {
            sibling.state = (sibling.representedObject as? String == raw) ? .on : .off
        }
    }

    @objc func repairHooksClicked(_ sender: Any?) {
        modeStore?.isMenuOpen = false
        Task.detached(priority: .utility) {
            HookRepair.run(appPath: Bundle.main.bundlePath)
        }
    }

    @objc func checkUpdatesClicked(_ sender: Any?) {
        modeStore?.isMenuOpen = false
        updateChecker?.checkNow()
    }

    @objc func moveNotchClicked(_ sender: Any?) {
        // Match sibling handlers: clear the menu-open sticky flag so the
        // controller's mouse-out collapse isn't blocked, then ask the
        // controller (which owns panel geometry) to enter reposition mode.
        modeStore?.isMenuOpen = false
        NotificationCenter.default.post(name: .notchMoveModeRequested, object: nil)
    }

    @objc func resetPositionClicked(_ sender: Any?) {
        // Sibling of moveNotchClicked: jump straight back to centered without
        // entering drag mode. Controller owns geometry, so just post.
        modeStore?.isMenuOpen = false
        NotificationCenter.default.post(name: .notchResetPositionRequested, object: nil)
    }

    @objc func themeClicked(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
              let rawValue = item.representedObject as? String,
              let theme = BuddyTheme(rawValue: rawValue) else { return }
        let config = ConfigStore()
        config.saveTheme(theme)
        // Reset sound selection so the new theme uses its default
        config.saveNotificationSound(nil)
        // Update checkmarks for theme items only (before the separator)
        for sibling in item.menu?.items ?? [] {
            if sibling.isSeparatorItem { break }
            sibling.state = (sibling.representedObject as? String == rawValue) ? .on : .off
        }
    }

    @objc func compactAgentClicked(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
              let raw = item.representedObject as? String,
              let agent = AgentKind(rawValue: raw) else { return }
        ConfigStore().saveCompactAgent(agent)
        modeStore?.compactAgent = agent
        // Update checkmarks on the Compact display submenu
        for sibling in item.menu?.items ?? [] {
            sibling.state = (sibling.representedObject as? String == raw) ? .on : .off
        }
    }

    @objc func toggleTodayConsumptionClicked(_ sender: Any?) {
        modeStore?.isMenuOpen = false
        let next = !(usageTracker?.showTodayConsumption ?? true)
        ConfigStore().saveShowTodayConsumption(next)
        usageTracker?.showTodayConsumption = next
        (sender as? NSMenuItem)?.state = next ? .on : .off
    }

    @objc func soundClicked(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
              let file = item.representedObject as? String else { return }
        ConfigStore().saveNotificationSound(file)
        // Update checkmarks for sound items only (after the separator)
        guard let menu = item.menu else { return }
        var pastSeparator = false
        for sibling in menu.items {
            if sibling.isSeparatorItem { pastSeparator = true; continue }
            if pastSeparator {
                sibling.state = (sibling.representedObject as? String == file) ? .on : .off
            }
        }
        // Preview the selected sound (stop any previous preview first)
        previewSound?.stop()
        if file != "none", let url = Bundle.main.url(forResource: file, withExtension: "mp3") {
            let sound = NSSound(contentsOf: url, byReference: true)
            sound?.play()
            previewSound = sound
        }
    }
}
