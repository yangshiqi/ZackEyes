import AppKit
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
    /// falls back to plain app activation for unsupported terminals.
    @discardableResult
    public static func activateTerminal(containingPid pid: Int) -> Bool {
        guard let app = findTerminalApp(startingFromPid: pid) else {
            NSLog("ZackEyes: no terminal found for pid %d", pid)
            return false
        }

        let tty = ttyPath(of: Int32(pid))
        NSLog("ZackEyes: activating terminal %@ (tty=%@) for pid %d",
              app.bundleIdentifier ?? "?", tty ?? "nil", pid)

        // Always activate the app first (quick feedback even if scripting fails)
        _ = app.activate(options: [])

        // Try terminal-specific tab focus
        guard let tty = tty else { return true }
        switch app.bundleIdentifier {
        case "com.googlecode.iterm2":
            return focusITerm2(tty: tty)
        case "com.apple.Terminal":
            return focusAppleTerminal(tty: tty)
        default:
            // No specific handler — app activation is the best we can do
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
