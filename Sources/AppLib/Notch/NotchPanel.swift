import AppKit

/// NSPanel subclass that overlays the MacBook notch region.
/// - Never activates (nonactivatingPanel) — does not steal focus from Claude Code or any other app.
/// - Anchored above the menu bar (`level = .mainMenu + 3`) with the utilityWindow +
///   hudWindow style-mask combo. This is the proven configuration used by
///   NotchNook / Boring Notch / DynamicIsland_Mac — lower style-mask counts
///   (e.g. just borderless + nonactivatingPanel) or higher levels like
///   `.screenSaver` trigger AppKit's default panel layout, which re-positions
///   the window off the menu-bar row on some macOS versions.
public final class NotchPanel: NSPanel {

    public override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        // Force the correct style mask regardless of caller arguments.
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow, .hudWindow],
            backing: .buffered,
            defer: true
        )
        configure()
    }

    // MARK: - NSWindow overrides

    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { false }

    // MARK: - Private

    private func configure() {
        level = .mainMenu + 3
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true

        titleVisibility = .hidden
        titlebarAppearsTransparent = true

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false

        isMovable = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false

        collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .fullScreenAuxiliary,
            .ignoresCycle,
        ]
    }
}
