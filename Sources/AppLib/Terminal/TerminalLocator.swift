import AppKit
import Darwin

/// Walks the process tree from a given PID to find the containing terminal app,
/// then activates it (brings to foreground).
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
        "com.todesktop.230313mzl4w4u92",  // Cursor
    ]

    /// Walk up the process tree from `startingPid`, return the first ancestor
    /// that is a known GUI terminal app.
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

            guard let parent = parentPid(of: currentPid), parent != currentPid else {
                return nil
            }
            currentPid = parent
        }
        return nil
    }

    /// Activate (focus) the terminal app containing the given process.
    @discardableResult
    public static func activateTerminal(containingPid pid: Int) -> Bool {
        guard let app = findTerminalApp(startingFromPid: pid) else {
            NSLog("ZackEyes: no terminal found for pid %d", pid)
            return false
        }
        NSLog("ZackEyes: activating terminal %@ for pid %d", app.bundleIdentifier ?? "?", pid)
        return app.activate(options: [])
    }

    // MARK: - sysctl helper

    /// Get parent PID of a given process using sysctl.
    private static func parentPid(of pid: Int32) -> Int32? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]

        let result = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
        guard result == 0 else { return nil }

        return info.kp_eproc.e_ppid
    }
}
