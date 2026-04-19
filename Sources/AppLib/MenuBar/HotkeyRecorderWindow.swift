import AppKit
import SwiftUI

/// Standalone window that hosts `HotkeyRecorderView`. Used by the real-notch
/// status-bar right-click menu; the simulated-notch path has its own in-panel
/// overlay and does not need this.
///
/// The inner `HotkeyRecorderView` walks the app's windows looking for a
/// `SimulatedNotchPanel` in `activatePanel()`. When hosted here that walk
/// turns into a no-op and we become key on our own (see `KeyablePanel`).
@MainActor
final class HotkeyRecorderWindow: NSObject, NSWindowDelegate {
    private var panel: KeyablePanel?

    func show() {
        // Reuse an already-open recorder instead of stacking a second
        // window on top. Guarantees only one key-event monitor runs at a
        // time (two recorders would both swallow keypresses).
        if let existing = panel {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let currentConfig = ConfigStore().load()
        let rootView = HotkeyRecorderView(
            currentConfig: currentConfig,
            onSave: { [weak self] newConfig in
                ConfigStore().save(newConfig)
                NotificationCenter.default.post(
                    name: .hotkeyConfigChanged,
                    object: nil,
                    userInfo: ["config": newConfig]
                )
                self?.dismiss()
            },
            onCancel: { [weak self] in
                self?.dismiss()
            }
        )

        // Borderless + nonactivating: no system title bar / close button,
        // no chrome that clashes with the dark recorder card. Generous
        // size so the backdrop (tap-outside-to-cancel) has room around
        // the 280×220 inner card.
        let size = NSSize(width: 380, height: 300)
        let screenFrame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        let origin = NSPoint(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.midY - size.height / 2
        )
        let hosting = NSHostingView(rootView: rootView)
        hosting.frame = NSRect(origin: .zero, size: size)

        let p = KeyablePanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        p.contentView = hosting
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .floating
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        // Delegate lets us observe any close path (e.g., orderOut from
        // an outside actor) so the next show() re-creates the panel
        // instead of early-returning against a stale reference.
        p.delegate = self
        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        panel = p
    }

    private func dismiss() {
        // close() removes the window from NSApp.windows so ARC can reclaim it.
        // orderOut() alone only hides — NSApp would keep a strong reference,
        // leaking the window on every open/dismiss cycle.
        panel?.close()
        panel = nil
    }

    // MARK: - NSWindowDelegate

    nonisolated func windowWillClose(_ notification: Notification) {
        // Runs on main; hop through MainActor to mutate @MainActor state.
        Task { @MainActor [weak self] in
            self?.panel = nil
        }
    }
}

// KeyablePanel: see MenuBar/KeyablePanel.swift (shared with AboutWindow).
