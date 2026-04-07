import AppKit
import SwiftUI

/// A floating "notch-like" NSPanel that sits centered at the top of the primary screen.
/// Used on Macs without a physical notch to provide a persistent Dynamic Island-style
/// indicator of Claude Code state + usage.
class SimulatedNotchPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        // CRITICAL: set `level` AFTER `isFloatingPanel`. Setting
        // `isFloatingPanel = true` clobbers `level` back to `.floating`
        // (raw value 3), which sits below third-party menu-bar items
        // (iStat Menus, Stats, Bartender, etc.) — they bleed through
        // the panel's notch shape at the top of the screen.
        // CGShieldingWindowLevel() (the level the system uses for the
        // login shield) sits above anything a user app can draw.
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = false
        ignoresMouseEvents = false
        collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .fullScreenAuxiliary,
            .ignoresCycle,
        ]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// AppKit's default `constrainFrameRect(_:to:)` pushes any window whose
    /// top edge sits above the menu bar down by 30pt so it's clear of the
    /// menu bar. We *want* the panel to live in the menu bar area — that's
    /// the whole point of a simulated notch — so return the frame unchanged.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        return frameRect
    }
}
