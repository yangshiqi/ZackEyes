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
        level = .screenSaver
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
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
