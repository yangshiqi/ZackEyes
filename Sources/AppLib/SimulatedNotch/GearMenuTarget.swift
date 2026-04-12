import AppKit

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
    var releaseURL: URL?
    private var previewSound: NSSound?

    @objc func aboutClicked(_ sender: Any?) {
        modeStore?.isMenuOpen = false
        modeStore?.isAboutShown = true
    }

    @objc func hotkeyClicked(_ sender: Any?) {
        modeStore?.isMenuOpen = false
        modeStore?.isHotkeyRecorderShown = true
    }

    @objc func updateClicked(_ sender: Any?) {
        modeStore?.isMenuOpen = false
        guard let url = releaseURL else { return }
        NSWorkspace.shared.open(url)
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
