import AppKit
import ApplicationServices
import Darwin
import Foundation

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

        let tty = ttyPath(of: Int32(pid))
        NSLog("ZackEyes: activating terminal %@ (tty=%@, cwd=%@) for pid %d",
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

    // MARK: - tty lookup (via sysctl + ps fallback)

    /// Get the tty path of a process, e.g. "/dev/ttys003"
    static func ttyPath(of pid: Int32) -> String? {
        // Use `ps -p PID -o tty=` to get the tty name
        let task = Process()
        task.launchPath = "/bin/ps"
        task.arguments = ["-p", "\(pid)", "-o", "tty="]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let raw = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "?" else { return nil }
        // `ps` returns e.g. "ttys003" — prepend /dev/
        if trimmed.hasPrefix("/dev/") { return trimmed }
        return "/dev/\(trimmed)"
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

        // Prompt for Accessibility permission on first use
        // Literal key avoids Swift 6 concurrency warning on the CFString global
        let options = ["AXTrustedCheckOptionPrompt" as CFString: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        guard trusted else {
            NSLog("ZackEyes: accessibility permission not granted — tab focus unavailable")
            return false
        }

        let appRef = AXUIElementCreateApplication(app.processIdentifier)

        var windowsRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &windowsRef)
        guard result == .success, let windows = windowsRef as? [AXUIElement] else {
            NSLog("ZackEyes: no windows accessible for %@", app.bundleIdentifier ?? "?")
            return false
        }

        let basename = (cwd as NSString).lastPathComponent

        // Find the best match: prefer exact cwd, then basename
        var bestMatch: AXUIElement?
        var bestScore = 0
        for window in windows {
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
            guard let title = titleRef as? String else { continue }

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
            NSLog("ZackEyes: no window title matched cwd=%@", cwd)
            return false
        }

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
}
