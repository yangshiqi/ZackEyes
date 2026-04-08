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

    @objc func aboutClicked(_ sender: Any?) {
        modeStore?.isMenuOpen = false
        modeStore?.isAboutShown = true
    }
}
