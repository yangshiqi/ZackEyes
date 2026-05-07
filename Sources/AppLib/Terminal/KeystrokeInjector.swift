import AppKit
import ApplicationServices
import Shared

/// Injects keystrokes into the agent's terminal so the AskUserQuestion
/// popup can drive CC's *native* terminal AskUQ UI instead of replacing it.
///
/// Required because the hook protocol is one-shot — once the bridge exits
/// without responding, CC opens its own terminal UI, and the popup loses
/// its old "auto-answer via socket" path. To still let users click the
/// popup, we activate the agent's terminal tab and post the same key
/// sequence a human would use to navigate + confirm: arrow-down N times,
/// then Return. (For multi-select: arrow-down to each chosen index +
/// Space to toggle, then Return.)
///
/// Requires Accessibility permission (System Settings > Privacy &
/// Security > Accessibility). Without it, `CGEvent.post` silently
/// no-ops; we surface this by returning `false` so callers can show a
/// "answer in terminal" reminder instead of leaving the popup pointing
/// at nothing.
@MainActor
public enum KeystrokeInjector {

    /// Send keystrokes to answer a single-select AskUQ question by index.
    /// `optionIndex` is 0-based — option 0 means "press Return immediately
    /// (cursor already on first row)".
    public static func sendSingleSelect(
        agentPid: Int,
        cwd: String?,
        sessionId: String?,
        optionIndex: Int
    ) -> Bool {
        guard ensureAccessibilityTrusted() else { return false }
        guard activateTerminal(pid: agentPid, cwd: cwd, sessionId: sessionId) else {
            return false
        }
        // Brief breather so the activated app actually has key focus
        // before we post events. Without this, the first keystroke
        // sometimes lands on the previously-focused window.
        Thread.sleep(forTimeInterval: 0.12)

        guard let src = CGEventSource(stateID: .hidSystemState) else { return false }
        for _ in 0..<max(0, optionIndex) {
            postKey(src: src, key: KeyCode.downArrow)
            Thread.sleep(forTimeInterval: 0.02)
        }
        postKey(src: src, key: KeyCode.returnKey)
        return true
    }

    /// Multi-select variant. Walks the cursor down through `selectedIndices`
    /// (assumed to start at row 0), pressing Space at each, then Return.
    /// Indices are toggled in ascending order — keeps the implementation
    /// trivial; CC's AskUQ doesn't care about toggle order.
    public static func sendMultiSelect(
        agentPid: Int,
        cwd: String?,
        sessionId: String?,
        selectedIndices: [Int]
    ) -> Bool {
        guard ensureAccessibilityTrusted() else { return false }
        guard activateTerminal(pid: agentPid, cwd: cwd, sessionId: sessionId) else {
            return false
        }
        Thread.sleep(forTimeInterval: 0.12)

        guard let src = CGEventSource(stateID: .hidSystemState) else { return false }
        var cursor = 0
        for idx in selectedIndices.sorted() where idx >= 0 {
            let moves = idx - cursor
            for _ in 0..<moves {
                postKey(src: src, key: KeyCode.downArrow)
                Thread.sleep(forTimeInterval: 0.02)
            }
            cursor = idx
            postKey(src: src, key: KeyCode.space)
            Thread.sleep(forTimeInterval: 0.02)
        }
        postKey(src: src, key: KeyCode.returnKey)
        return true
    }

    // MARK: - Internals

    /// macOS virtual key codes. Stable across keyboard layouts (these are
    /// hardware-position codes, not character codes).
    public enum KeyCode {
        public static let returnKey: CGKeyCode = 0x24
        public static let space: CGKeyCode = 0x31
        public static let downArrow: CGKeyCode = 0x7D
    }

    private static func postKey(src: CGEventSource, key: CGKeyCode) {
        CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true)?
            .post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false)?
            .post(tap: .cghidEventTap)
    }

    private static func ensureAccessibilityTrusted() -> Bool {
        // Same prompt-on-first-need pattern TerminalLocator uses, so the
        // user only sees one dialog the first time either path needs it.
        let key = "AXTrustedCheckOptionPrompt" as CFString
        let opts = [key: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    private static func activateTerminal(
        pid: Int,
        cwd: String?,
        sessionId: String?
    ) -> Bool {
        if let sid = sessionId {
            return TerminalLocator.activateTerminal(
                containingPid: pid, cwd: cwd, sessionId: sid
            )
        }
        return TerminalLocator.activateTerminal(containingPid: pid, cwd: cwd)
    }
}
