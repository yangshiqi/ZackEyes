import AppKit

/// Builds the right-click context menu for the status-bar icon. Used by
/// both paths: on simulated-notch Macs this menu duplicates parts of the
/// gear menu (redundant, harmless), on real-notch Macs it is the ONLY
/// entry point to About / Change Hotkey / Theme / Quit — the real-notch
/// expanded panel has no gear button.
///
/// Theme + Sound actions are delegated to the existing `GearMenuTarget`
/// which only touches `ConfigStore` (no dependency on `NotchModeStore`),
/// so they work regardless of which path built the menu. About and
/// Change Hotkey are handled locally because the simulated-notch variants
/// of those require in-panel overlays this surface does not have.
@MainActor
public final class StatusBarMenu: NSObject {
    private let updateChecker: UpdateChecker
    private let downloader: UpdateDownloader
    private var hotkeyWindow: HotkeyRecorderWindow?
    private var aboutWindow: AboutWindow?
    private var hookStatusWindow: HookStatusWindow?

    public init(updateChecker: UpdateChecker, downloader: UpdateDownloader) {
        self.updateChecker = updateChecker
        self.downloader = downloader
        super.init()
    }

    public func build() -> NSMenu {
        let menu = NSMenu()
        // No side effect on GearMenuTarget.shared.releaseURL — our local
        // updateClicked reads updateChecker.releaseURL directly. The
        // simulated-notch gear menu path keeps that shared assignment
        // because it routes Update through GearMenuTarget.updateClicked.

        if let version = updateChecker.availableVersion {
            let (title, enabled) = Self.updateMenuLabel(
                version: version,
                state: downloader.state
            )
            let item = NSMenuItem(
                title: title,
                action: enabled ? #selector(updateClicked(_:)) : nil,
                keyEquivalent: ""
            )
            item.target = enabled ? self : nil
            item.isEnabled = enabled
            menu.addItem(item)
            menu.addItem(.separator())
        }

        let about = NSMenuItem(
            title: "About",
            action: #selector(aboutClicked(_:)),
            keyEquivalent: ""
        )
        about.target = self
        menu.addItem(about)

        let hotkey = NSMenuItem(
            title: "Change Hotkey…",
            action: #selector(hotkeyClicked(_:)),
            keyEquivalent: ""
        )
        hotkey.target = self
        menu.addItem(hotkey)

        let hookStatus = NSMenuItem(
            title: "Hook Status…",
            action: #selector(hookStatusClicked(_:)),
            keyEquivalent: ""
        )
        hookStatus.target = self
        menu.addItem(hookStatus)

        let visibility = ConfigStore().loadNotchVisibility()
        let showIsland = NSMenuItem(
            title: "Show Dynamic Island",
            action: #selector(toggleVisibilityClicked(_:)),
            keyEquivalent: ""
        )
        showIsland.target = self
        showIsland.state = (visibility == .always) ? .on : .off
        menu.addItem(showIsland)

        menu.addItem(themeSubmenuItem())
        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit ZackEyes",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quit.target = NSApp
        menu.addItem(quit)

        return menu
    }

    // MARK: - Actions

    @objc private func updateClicked(_ sender: Any?) {
        if let dmgURL = updateChecker.dmgURL {
            Task { @MainActor in await downloader.download(from: dmgURL) }
        } else if let url = updateChecker.releaseURL {
            // No DMG asset attached (in-flight release, or manual gh release
            // without --asset) — fall back to opening the release page.
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func aboutClicked(_ sender: Any?) {
        // Non-blocking AboutWindow instead of NSAlert.runModal(): a modal
        // alert would block the main thread, starving the @MainActor
        // socket handler. On a slow user (> 15s on the alert) this could
        // trip the bridge's socket timeout and drop a permission request.
        if aboutWindow == nil {
            aboutWindow = AboutWindow()
        }
        aboutWindow?.show()
    }

    @objc private func hotkeyClicked(_ sender: Any?) {
        // Lazily create once and reuse. HotkeyRecorderWindow.show() is
        // idempotent — brings an existing panel to front instead of
        // stacking a second one.
        if hotkeyWindow == nil {
            hotkeyWindow = HotkeyRecorderWindow()
        }
        hotkeyWindow?.show()
    }

    @objc private func hookStatusClicked(_ sender: Any?) {
        // Lazily create once and reuse — same pattern as aboutWindow.
        if hookStatusWindow == nil {
            hookStatusWindow = HookStatusWindow()
        }
        hookStatusWindow?.show()
    }

    @objc private func toggleVisibilityClicked(_ sender: Any?) {
        let store = ConfigStore()
        let current = store.loadNotchVisibility()
        let next: NotchVisibility = (current == .always) ? .hidden : .always
        store.saveNotchVisibility(next)
        NotificationCenter.default.post(
            name: .notchVisibilityChanged,
            object: nil,
            userInfo: ["visibility": next]
        )
    }

    /// Map (availableVersion, downloader.state) → menu item title + enabled flag.
    /// Pure function so it's trivially testable and shared with the simulated-notch
    /// gear menu in Task 8.
    public static func updateMenuLabel(
        version: String,
        state: UpdateDownloader.State
    ) -> (title: String, enabled: Bool) {
        switch state {
        case .idle:
            return ("Update Available (v\(version))", true)
        case .downloading:
            return ("Downloading v\(version)…", false)
        case .ready:
            // After a successful download Finder is already showing the DMG.
            // Keep the menu offering a re-open in case the user dismissed it.
            return ("Update Ready (v\(version)) — Click to Open", true)
        case .failed:
            return ("Update Failed — Click to Retry", true)
        }
    }

    // MARK: - Theme submenu

    private func themeSubmenuItem() -> NSMenuItem {
        let themeMenu = NSMenu()
        let config = ConfigStore()
        let currentTheme = config.loadTheme()
        let currentSound = config.loadNotificationSound() ?? currentTheme.defaultSoundFile

        for theme in BuddyTheme.allCases {
            let item = NSMenuItem(
                title: theme.displayName,
                action: #selector(GearMenuTarget.themeClicked(_:)),
                keyEquivalent: ""
            )
            item.target = GearMenuTarget.shared
            item.representedObject = theme.rawValue
            item.state = (theme == currentTheme) ? .on : .off
            themeMenu.addItem(item)
        }

        let sounds = currentTheme.availableSounds
        if !sounds.isEmpty {
            themeMenu.addItem(.separator())
            for sound in sounds {
                let item = NSMenuItem(
                    title: sound.name,
                    action: #selector(GearMenuTarget.soundClicked(_:)),
                    keyEquivalent: ""
                )
                item.target = GearMenuTarget.shared
                item.representedObject = sound.file
                item.state = (sound.file == currentSound) ? .on : .off
                themeMenu.addItem(item)
            }
        }

        let themeItem = NSMenuItem(title: "Theme", action: nil, keyEquivalent: "")
        themeItem.submenu = themeMenu
        return themeItem
    }
}
