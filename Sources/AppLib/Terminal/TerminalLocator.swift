import AppKit
import ApplicationServices
import Darwin
import Foundation
import Shared

/// Walks the process tree from a given PID to find the containing terminal app,
/// then activates the correct tab/window via terminal-specific AppleScript.
public enum TerminalLocator {

    /// Known terminal app bundle IDs
    private static let knownTerminals: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable",
        "dev.warp.Warp",
        "com.github.wez.wezterm",
        "net.kovidgoyal.kitty",
        "io.alacritty",
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92",
    ]

    /// Prompt the user for Accessibility permission ONLY if not already trusted.
    /// Once granted (under a stable code signature), we never prompt again.
    public static func promptAccessibilityIfNeeded() {
        if AXIsProcessTrusted() { return }  // already authorized — no prompt
        let options = ["AXTrustedCheckOptionPrompt" as CFString: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Find the claude process PID for a session. Tries multiple strategies:
    /// 1. Use `lsof` on the transcript file (most accurate — file has exactly one writer)
    /// 2. Scan running claude processes and match by cwd
    public static func findClaudePid(transcriptPath: String?, cwd: String?) -> Int? {
        NSLog("ZackEyes: findClaudePid transcriptPath=%{public}@ cwd=%{public}@",
              transcriptPath ?? "nil", cwd ?? "nil")
        if let path = transcriptPath, let pid = lsofPid(file: path) {
            NSLog("ZackEyes: found via lsof pid=%d", pid)
            return pid
        }
        if let cwd = cwd, let pid = claudePidByCwd(cwd) {
            NSLog("ZackEyes: found via cwd match pid=%d", pid)
            return pid
        }
        NSLog("ZackEyes: no claude pid found")
        return nil
    }

    private static func lsofPid(file: String) -> Int? {
        guard let out = runWithTimeout("/usr/sbin/lsof", args: ["-t", file], timeoutSeconds: 3) else { return nil }
        for line in out.split(separator: "\n") {
            if let pid = Int(line.trimmingCharacters(in: .whitespaces)), pid > 0 {
                return pid
            }
        }
        return nil
    }

    /// Run a subprocess with a timeout. Returns stdout or nil on error/timeout.
    private static func runWithTimeout(_ path: String, args: [String], timeoutSeconds: Int) -> String? {
        let task = Process()
        task.launchPath = path
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do { try task.run() } catch { return nil }

        // Poll for completion
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while task.isRunning {
            if Date() >= deadline {
                task.terminate()
                Thread.sleep(forTimeInterval: 0.05)
                if task.isRunning {
                    kill(task.processIdentifier, SIGKILL)
                }
                return nil
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }

    private static func claudePidByCwd(_ targetCwd: String) -> Int? {
        guard let out = runWithTimeout("/bin/ps", args: ["-ax", "-o", "pid=,comm="], timeoutSeconds: 3) else {
            NSLog("ZackEyes: ps command failed or timed out")
            return nil
        }
        var candidateCount = 0
        for line in out.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }
            let comm = String(parts[1])
            let base = (comm as NSString).lastPathComponent
            guard base == "claude" || base == "node" else { continue }
            guard let pid = Int(parts[0]) else { continue }

            candidateCount += 1
            let pidCwd = processCwd(pid: pid)
            NSLog("ZackEyes: candidate pid=%d comm=%{public}@ cwd=%{public}@ (target=%{public}@)",
                  pid, comm, pidCwd ?? "nil", targetCwd)
            if pidCwd == targetCwd {
                return pid
            }
        }
        NSLog("ZackEyes: scanned %d claude candidates, no cwd match", candidateCount)
        return nil
    }

    private static func processCwd(pid: Int) -> String? {
        guard let out = runWithTimeout(
            "/usr/sbin/lsof",
            args: ["-p", "\(pid)", "-a", "-d", "cwd", "-Fn"],
            timeoutSeconds: 2
        ) else { return nil }
        for line in out.split(separator: "\n") where line.hasPrefix("n") {
            return String(line.dropFirst())
        }
        return nil
    }

    /// Walk up the process tree, return the first ancestor that is a known terminal app.
    public static func findTerminalApp(startingFromPid startingPid: Int) -> NSRunningApplication? {
        var currentPid = Int32(startingPid)
        var steps = 0
        while currentPid > 1 && steps < 20 {
            steps += 1
            if let app = NSRunningApplication(processIdentifier: currentPid),
               let bundleId = app.bundleIdentifier,
               knownTerminals.contains(bundleId) {
                return app
            }
            guard let parent = parentPid(of: currentPid), parent != currentPid else { return nil }
            currentPid = parent
        }
        return nil
    }

    /// Activate the terminal tab/window containing the given process.
    /// Uses terminal-specific AppleScript to focus the exact session where possible;
    /// falls back to Accessibility API window-title matching by cwd for others.
    @discardableResult
    public static func activateTerminal(containingPid pid: Int, cwd: String? = nil) -> Bool {
        guard let app = findTerminalApp(startingFromPid: pid) else {
            NSLog("ZackEyes: no terminal found for pid %d", pid)
            return false
        }

        let tty = TTYUtil.ttyPath(pid: Int32(pid))
        NSLog("ZackEyes: activating terminal %{public}@ (tty=%{public}@, cwd=%{public}@) for pid %d",
              app.bundleIdentifier ?? "?", tty ?? "nil", cwd ?? "nil", pid)

        // Always activate the app first (quick feedback)
        _ = app.activate(options: [])

        // Try terminal-specific tab focus
        switch app.bundleIdentifier {
        case "com.googlecode.iterm2":
            if let tty = tty { return focusITerm2(tty: tty) }
            return true
        case "com.apple.Terminal":
            if let tty = tty { return focusAppleTerminal(tty: tty) }
            return true
        case "com.mitchellh.ghostty",
             "dev.warp.Warp-Stable", "dev.warp.Warp",
             "io.alacritty",
             "net.kovidgoyal.kitty":
            // No AppleScript tab control — use Accessibility window-title matching
            return focusByAccessibility(app: app, cwd: cwd)
        default:
            return true
        }
    }

    /// Variant that knows the session id — enables Ghostty Layer A matching.
    /// Non-Ghostty terminals behave identically to
    /// `activateTerminal(containingPid:cwd:)`.
    @discardableResult
    public static func activateTerminal(
        containingPid pid: Int,
        cwd: String? = nil,
        sessionId: String
    ) -> Bool {
        guard let app = findTerminalApp(startingFromPid: pid) else {
            NSLog("ZackEyes: no terminal found for pid %d", pid)
            return false
        }

        let tty = TTYUtil.ttyPath(pid: Int32(pid))
        NSLog("ZackEyes: activating terminal %{public}@ (tty=%{public}@, cwd=%{public}@, sid=%{public}@) for pid %d",
              app.bundleIdentifier ?? "?", tty ?? "nil", cwd ?? "nil", sessionId, pid)

        _ = app.activate(options: [])

        switch app.bundleIdentifier {
        case "com.googlecode.iterm2":
            if let tty = tty { return focusITerm2(tty: tty) }
            return true
        case "com.apple.Terminal":
            if let tty = tty { return focusAppleTerminal(tty: tty) }
            return true
        case "com.mitchellh.ghostty":
            if focusGhosttySession(app: app, sessionId: sessionId, cwd: cwd) { return true }
            // Final fallback: existing AX window-title raise
            return focusByAccessibility(app: app, cwd: cwd)
        case "dev.warp.Warp-Stable", "dev.warp.Warp",
             "io.alacritty",
             "net.kovidgoyal.kitty":
            return focusByAccessibility(app: app, cwd: cwd)
        default:
            return true
        }
    }

    // MARK: - AppleScript focus handlers

    private static func focusITerm2(tty: String) -> Bool {
        let script = """
        tell application "iTerm2"
            activate
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is "\(tty)" then
                            tell w to select
                            select t
                            select s
                            return "ok"
                        end if
                    end repeat
                end repeat
            end repeat
            return "not found"
        end tell
        """
        return runAppleScript(script)
    }

    private static func focusAppleTerminal(tty: String) -> Bool {
        let script = """
        tell application "Terminal"
            activate
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(tty)" then
                        set selected of t to true
                        set frontmost of w to true
                        return "ok"
                    end if
                end repeat
            end repeat
            return "not found"
        end tell
        """
        return runAppleScript(script)
    }

    // MARK: - Accessibility API fallback (for Ghostty, Warp, Alacritty, Kitty)

    /// Find a window of the given app whose title contains the cwd basename, then raise it.
    /// Requires Accessibility permission (System Settings > Privacy > Accessibility).
    private static func focusByAccessibility(app: NSRunningApplication, cwd: String?) -> Bool {
        guard let cwd = cwd, !cwd.isEmpty else { return false }

        // Check without prompting. If we've already requested once and the user denied,
        // we don't want to keep nagging them on every click.
        guard AXIsProcessTrusted() else {
            // Prompt ONCE per app launch via the promptIfNeeded() call at startup
            NSLog("ZackEyes: accessibility permission not granted — tab focus unavailable for %{public}@",
                  app.bundleIdentifier ?? "?")
            return false
        }

        let appRef = AXUIElementCreateApplication(app.processIdentifier)

        var windowsRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &windowsRef)
        guard result == .success, let windows = windowsRef as? [AXUIElement] else {
            NSLog("ZackEyes: no windows accessible for %{public}@", app.bundleIdentifier ?? "?")
            return false
        }

        let basename = (cwd as NSString).lastPathComponent
        NSLog("ZackEyes: scanning %d windows for cwd=%{public}@ basename=%{public}@",
              windows.count, cwd, basename)

        // Find the best match: prefer exact cwd, then basename
        var bestMatch: AXUIElement?
        var bestScore = 0
        for window in windows {
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
            guard let title = titleRef as? String else { continue }
            NSLog("ZackEyes: window title=%{public}@", title)

            var score = 0
            if title.contains(cwd) { score = 3 }
            else if title.contains(basename) { score = 2 }
            else if title.lowercased().contains("claude") { score = 1 }

            if score > bestScore {
                bestScore = score
                bestMatch = window
            }
        }

        guard let window = bestMatch else {
            NSLog("ZackEyes: no window title matched cwd=%{public}@", cwd)
            return false
        }
        NSLog("ZackEyes: matched window with score=%d", bestScore)

        // Raise + make main + focused
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        return true
    }

    private static func runAppleScript(_ source: String) -> Bool {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return false }
        let result = script.executeAndReturnError(&error)
        if let error = error {
            NSLog("ZackEyes: AppleScript error: %@", error)
            return false
        }
        let out = result.stringValue ?? ""
        return out == "ok"
    }

    // MARK: - sysctl helper

    private static func parentPid(of pid: Int32) -> Int32? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let result = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
        guard result == 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    // MARK: - AX attribute helpers (used by Ghostty Layer A / A')

    /// Read a string-valued AX attribute. Returns nil if the attribute
    /// is missing or not a String.
    static func axStringAttr(_ el: AXUIElement, _ attr: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success
        else { return nil }
        return ref as? String
    }

    /// Read the children of an AX element. Returns an empty array if
    /// the attribute is missing or not an array.
    static func axChildren(of el: AXUIElement) -> [AXUIElement] {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            el, kAXChildrenAttribute as CFString, &ref
        ) == .success else { return [] }
        return (ref as? [AXUIElement]) ?? []
    }

    /// Find the first direct child of `el` whose `AXRole` equals `role`.
    static func axFirstChild(of el: AXUIElement, whereRole role: String) -> AXUIElement? {
        for child in axChildren(of: el) {
            if axStringAttr(child, kAXRoleAttribute as String) == role {
                return child
            }
        }
        return nil
    }

    // MARK: - Ghostty Layer A: AXTabButton title match

    /// Primary Ghostty fast path. Enumerates AXTabGroup children, finds
    /// the AXTabButton whose title contains `marker`, AXPresses it.
    /// Returns true on success.
    static func focusGhosttyTabByMarker(
        appRef: AXUIElement,
        marker: String
    ) -> Bool {
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appRef, kAXWindowsAttribute as CFString, &windowsRef
        ) == .success,
              let windows = windowsRef as? [AXUIElement] else { return false }

        for window in windows {
            guard let tabGroup = axFirstChild(of: window, whereRole: "AXTabGroup")
            else { continue }

            for button in axChildren(of: tabGroup) {
                guard axStringAttr(button, kAXSubroleAttribute as String) == "AXTabButton",
                      let title = axStringAttr(button, kAXTitleAttribute as String),
                      title.contains(marker) else { continue }

                if AXUIElementPerformAction(button, kAXPressAction as CFString) == .success {
                    return true
                }
            }
        }
        return false
    }

    /// Entry point called from `activateTerminal` for Ghostty. Calls
    /// Layer A first (fast match on AXTabButton titles); on miss, falls
    /// through. Layer A' (brute-force cycling) is added in Task 7 — for
    /// now, Layer A miss returns false immediately.
    static func focusGhosttySession(
        app: NSRunningApplication,
        sessionId: String,
        cwd: String?
    ) -> Bool {
        guard AXIsProcessTrusted() else {
            NSLog("ZackEyes: focusGhostty skip=noPermission sid=%{public}@", sessionId)
            return false
        }
        let marker = String(sessionId.prefix(8))
        let appRef = AXUIElementCreateApplication(app.processIdentifier)
        let start = Date()

        // Layer A — fast path: AXTabButton title contains sid marker
        if focusGhosttyTabByMarker(appRef: appRef, marker: marker) {
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            NSLog("ZackEyes: focusGhostty layer=A sid=%{public}@ hit=1 elapsed=%dms", sessionId, ms)
            return true
        }

        let ms = Int(Date().timeIntervalSince(start) * 1000)
        NSLog("ZackEyes: focusGhostty layer=A sid=%{public}@ hit=0 elapsed=%dms", sessionId, ms)

        // Layer A' — targeted: find the ONE tab matching cwd basename,
        // switch to it, then cycle panes looking for the sid marker.
        // Only 1 tab switch + up to 4 pane cycles — no "乱跳".
        if let cwd = cwd {
            let cycleStart = Date()
            if focusGhosttyByCwdThenCyclePanes(
                appRef: appRef, marker: marker, cwd: cwd
            ) {
                let cycleMs = Int(Date().timeIntervalSince(cycleStart) * 1000)
                NSLog("ZackEyes: focusGhostty layer=A' sid=%{public}@ hit=1 elapsed=%dms",
                      sessionId, cycleMs)
                return true
            }
            let cycleMs = Int(Date().timeIntervalSince(cycleStart) * 1000)
            NSLog("ZackEyes: focusGhostty layer=A' sid=%{public}@ hit=0 elapsed=%dms",
                  sessionId, cycleMs)
        }
        return false
    }

    // MARK: - Ghostty Layer A': targeted tab + AX pane focus

    /// Recursively collect all AXTextArea elements within `element`.
    /// Each Ghostty pane contains one AXTextArea (the terminal surface).
    private static func findAllTextAreas(
        in element: AXUIElement,
        depth: Int = 0,
        maxDepth: Int = 6
    ) -> [AXUIElement] {
        if depth > maxDepth { return [] }
        var results: [AXUIElement] = []
        if axStringAttr(element, kAXRoleAttribute as String) == "AXTextArea" {
            results.append(element)
        }
        for child in axChildren(of: element) {
            results.append(contentsOf: findAllTextAreas(in: child, depth: depth + 1, maxDepth: maxDepth))
        }
        return results
    }

    /// Targeted Layer A' fallback. Finds the ONE tab whose title contains
    /// the `cwd` basename, switches to it, then focuses each AXTextArea
    /// (pane) in turn via `kAXFocusedAttribute` until the window title
    /// contains the sid marker.
    ///
    /// Pure AX — no synthetic keystrokes, no menu bar flash.
    static func focusGhosttyByCwdThenCyclePanes(
        appRef: AXUIElement,
        marker: String,
        cwd: String
    ) -> Bool {
        let basename = (cwd as NSString).lastPathComponent
        guard !basename.isEmpty else { return false }

        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appRef, kAXWindowsAttribute as CFString, &windowsRef
        ) == .success,
              let windows = windowsRef as? [AXUIElement],
              let window = windows.first else { return false }

        guard let tabGroup = axFirstChild(of: window, whereRole: "AXTabGroup")
        else { return false }

        // Find the tab whose title contains the cwd basename
        var targetButton: AXUIElement?
        for button in axChildren(of: tabGroup) {
            guard axStringAttr(button, kAXSubroleAttribute as String) == "AXTabButton",
                  let title = axStringAttr(button, kAXTitleAttribute as String),
                  title.contains(basename) else { continue }
            targetButton = button
            break
        }

        guard let button = targetButton else { return false }

        // Switch to that tab
        _ = AXUIElementPerformAction(button, kAXPressAction as CFString)
        Thread.sleep(forTimeInterval: 0.03)

        // Check if the window title already has the marker
        if let title = axStringAttr(window, kAXTitleAttribute as String),
           title.contains(marker) {
            return true
        }

        // Cycle panes by focusing each AXTextArea in turn
        let textAreas = findAllTextAreas(in: window)
        for textArea in textAreas {
            AXUIElementSetAttributeValue(
                textArea, kAXFocusedAttribute as CFString, kCFBooleanTrue
            )
            Thread.sleep(forTimeInterval: 0.03)

            if let title = axStringAttr(window, kAXTitleAttribute as String),
               title.contains(marker) {
                return true
            }
        }
        return false
    }
}
