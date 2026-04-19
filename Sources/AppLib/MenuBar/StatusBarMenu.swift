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
    private var hotkeyWindow: HotkeyRecorderWindow?

    public init(updateChecker: UpdateChecker) {
        self.updateChecker = updateChecker
        super.init()
    }

    public func build() -> NSMenu {
        let menu = NSMenu()
        GearMenuTarget.shared.releaseURL = updateChecker.releaseURL

        if let version = updateChecker.availableVersion {
            let item = NSMenuItem(
                title: "Update Available (v\(version))",
                action: #selector(updateClicked(_:)),
                keyEquivalent: ""
            )
            item.target = self
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
        guard let url = updateChecker.releaseURL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func aboutClicked(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "ZackEyes"
        alert.informativeText = "Version \(appVersion)"
        if let icon = NSImage(named: "AppIcon") {
            alert.icon = icon
        }
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
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

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }
}
