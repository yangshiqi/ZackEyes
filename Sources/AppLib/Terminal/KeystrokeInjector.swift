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
///
/// **Targeting** — events are delivered to the terminal *emulator*'s pid
/// via `CGEvent.postToPid`, not to the system-wide HID tap. This keeps
/// the keystrokes stuck to the right app even if the user happens to
/// switch focus during the inter-key gap. The agent process (claude /
/// codex) doesn't read keyboard events directly — its host terminal does
/// and writes them to the agent's pty. So we resolve agentPid → owning
/// terminal app via the existing `TerminalLocator.findTerminalApp` and
/// post to the terminal app's pid.
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
    ) async -> Bool {
        guard let setup = await prepare(agentPid: agentPid, cwd: cwd, sessionId: sessionId) else {
            return false
        }
        for _ in 0..<max(0, optionIndex) {
            postKey(src: setup.src, key: KeyCode.downArrow, toPid: setup.terminalPid)
            try? await Task.sleep(for: .milliseconds(20))
        }
        postKey(src: setup.src, key: KeyCode.returnKey, toPid: setup.terminalPid)
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
    ) async -> Bool {
        guard let setup = await prepare(agentPid: agentPid, cwd: cwd, sessionId: sessionId) else {
            return false
        }
        var cursor = 0
        for idx in selectedIndices.sorted() where idx >= 0 {
            let moves = idx - cursor
            for _ in 0..<moves {
                postKey(src: setup.src, key: KeyCode.downArrow, toPid: setup.terminalPid)
                try? await Task.sleep(for: .milliseconds(20))
            }
            cursor = idx
            postKey(src: setup.src, key: KeyCode.space, toPid: setup.terminalPid)
            try? await Task.sleep(for: .milliseconds(20))
        }
        postKey(src: setup.src, key: KeyCode.returnKey, toPid: setup.terminalPid)
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

    /// Pre-flight: AX permission, activate terminal tab, resolve terminal pid,
    /// build CGEventSource, then yield once so the activated app has had a
    /// runloop tick to actually take key focus before we start posting.
    private static func prepare(
        agentPid: Int,
        cwd: String?,
        sessionId: String?
    ) async -> (src: CGEventSource, terminalPid: pid_t)? {
        guard ensureAccessibilityTrusted() else { return nil }
        guard activateTerminal(pid: agentPid, cwd: cwd, sessionId: sessionId) else {
            return nil
        }
        guard let termApp = TerminalLocator.findTerminalApp(startingFromPid: agentPid) else {
            return nil
        }
        try? await Task.sleep(for: .milliseconds(120))
        guard let src = CGEventSource(stateID: .hidSystemState) else { return nil }
        return (src, termApp.processIdentifier)
    }

    private static func postKey(src: CGEventSource, key: CGKeyCode, toPid pid: pid_t) {
        CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true)?
            .postToPid(pid)
        CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false)?
            .postToPid(pid)
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
