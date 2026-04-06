import AppKit

/// NSPanel subclass that overlays the MacBook notch region.
/// - Never activates (nonactivatingPanel) — does not steal focus from Claude Code or any other app.
/// - Sits above full-screen content (screenSaver level) but never enters the window cycle.
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
            styleMask: [.borderless, .nonactivatingPanel],
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
        level = .screenSaver
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false

        isMovable = false
        ignoresMouseEvents = true

        collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .fullScreenAuxiliary,
            .ignoresCycle,
        ]
    }
}
