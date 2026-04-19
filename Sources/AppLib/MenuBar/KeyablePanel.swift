import AppKit

/// Minimal `NSPanel` subclass that opts in to key-window status while
/// staying out of the main-window cycle. Used by the standalone
/// `AboutWindow` and `HotkeyRecorderWindow` — both need keyboard focus
/// (Escape to cancel, Enter to confirm, local key-event monitors) but
/// must not take over the main-window role from actual app windows.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
