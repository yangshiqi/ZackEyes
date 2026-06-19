import AppKit

/// NSPanel subclass that overlays the MacBook notch region.
/// - Never activates (nonactivatingPanel) — does not steal focus from Claude
///   Code or any other app (`canBecomeMain == false`).
/// - Rendered ABOVE the menu bar so its top edge can sit flush with the
///   physical screen top and merge with the hardware notch. This mirrors the
///   proven `SimulatedNotchPanel` configuration, which is the only window setup
///   verified to render flush in the menu-bar/notch row on real hardware.
public final class NotchPanel: NSPanel {

    public override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        // Force the correct style mask regardless of caller arguments. Match
        // SimulatedNotchPanel: borderless + nonactivating only. The extra
        // .utilityWindow/.hudWindow masks used previously added a title-bar
        // inset and bought nothing.
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

    /// AppKit's default `constrainFrameRect(_:to:)` pushes any window whose top
    /// edge sits above the menu bar *down* so its top clears the menu bar. For a
    /// notch overlay that's exactly wrong: we need the top edge flush with the
    /// physical screen top so the black pill merges with the hardware notch.
    /// `SimulatedNotchPanel` overrides this for the same reason (issue #64).
    public override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    // MARK: - Private

    private func configure() {
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        // CRITICAL: set `level` AFTER `isFloatingPanel`. Setting
        // `isFloatingPanel = true` clobbers `level` back to `.floating`
        // (raw value 3), which sits BELOW the menu bar — so the panel renders
        // one menu-bar row *below* the notch instead of merging with it
        // (issue #64). `CGShieldingWindowLevel()` (the level the system uses for
        // the login shield) sits above the menu bar, so the panel's top edge can
        // occupy the notch row. Same value SimulatedNotchPanel relies on.
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))

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
