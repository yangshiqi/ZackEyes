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

    /// Snapshot of currently-running Claude Code processes, keyed by cwd,
    /// valued by count of distinct PIDs.
    ///
    /// Used as the authoritative liveness signal: Claude Code does NOT keep
    /// its JSONL transcript open between writes (open-append-close), so
    /// `lsof <transcript>` returns nothing. The only reliable signal is
    /// "is there a claude process whose cwd matches this session's cwd".
    /// Two same-cwd sessions are disambiguated by the caller (typically
    /// by lastActiveAt / lastModified ordering).
    ///
    /// Returns:
    /// - `nil` when the underlying `ps` invocation fails outright. Callers
    ///   must treat this as "snapshot unavailable, do nothing" — never as
    ///   "no claudes are running".
    /// - empty dict when `ps` succeeded but found zero claude processes.
    ///   Callers can act on this (e.g. the sweep prunes everything past
    ///   the grace window).
    ///
    /// Matching reads full `argv` (via `ps -o args`) instead of `comm`.
    /// We can't just match `comm == "node"` because every Vue/webpack/vite
    /// dev server in a project subdirectory would then masquerade as a
    /// Claude session. See `isClaudeProcess` for the matching rules.
    public static func runningClaudeCwds() -> [String: Int]? {
        guard let pids = runningClaudePids() else { return nil }
        let cwdMap = batchProcessCwds(pids: pids)
        var counts: [String: Int] = [:]
        for cwd in cwdMap.values {
            counts[Self.canonicalize(cwd), default: 0] += 1
        }
        return counts
    }

    /// Returns PIDs of all currently-running Claude Code processes via
    /// `ps -o args` + `isClaudeProcess`. Returns `nil` on subprocess
    /// failure (transient ps error, missing entitlement). Returns empty
    /// array if ps succeeded with zero matches.
    private static func runningClaudePids() -> [Int]? {
        guard let out = runWithTimeout(
            "/bin/ps", args: ["-ax", "-o", "pid=,args="], timeoutSeconds: 3
        ) else { return nil }
        var pids: [Int] = []
        for line in out.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let firstSpace = trimmed.firstIndex(of: " ") else { continue }
            guard let pid = Int(trimmed[..<firstSpace]) else { continue }
            let argsStr = String(trimmed[trimmed.index(after: firstSpace)...])
                .trimmingCharacters(in: .whitespaces)
            guard isClaudeProcess(args: argsStr) else { continue }
            pids.append(pid)
        }
        return pids
    }

    /// True iff `args` (as printed by `ps -o args`) belongs to a real
    /// Claude Code process — either the native `claude` binary or a
    /// node interpreter running the Claude Code CLI script. Excludes
    /// every other node-based tool that might share a project cwd.
    ///
    /// Rules:
    /// - `argv[0]` basename is `claude` → native binary install. Match.
    /// - `argv[0]` basename is `node` **and** any subsequent token contains
    ///   `/claude` → npm install (covers `…/claude-code/cli.js`,
    ///   `…/claude.js`, etc.). The "any subsequent token" rule survives
    ///   node interpreter flags like `--inspect`, `--max-old-space-size`,
    ///   etc., which would otherwise push the script path past `argv[1]`.
    /// - Anything else → skip. A `node` process running vue-cli-service,
    ///   vite, jest, webpack, etc. is not Claude Code.
    static func isClaudeProcess(args: String) -> Bool {
        let argv = args.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let first = argv.first else { return false }
        let argv0Base = (first as NSString).lastPathComponent
        if argv0Base == "claude" { return true }
        if argv0Base == "node" {
            return argv.dropFirst().contains { $0.contains("/claude") }
        }
        return false
    }

    /// Batch lsof: get cwd for many PIDs in a single subprocess. Returns
    /// `[pid: cwd]`. PIDs that lsof can't resolve (already exited, EPERM,
    /// etc.) are absent from the result. Empty input → empty output (no
    /// subprocess spawned).
    private static func batchProcessCwds(pids: [Int]) -> [Int: String] {
        guard !pids.isEmpty else { return [:] }
        let pidArgs = pids.map(String.init).joined(separator: ",")
        guard let out = runWithTimeout(
            "/usr/sbin/lsof",
            args: ["-p", pidArgs, "-a", "-d", "cwd", "-Fpn"],
            timeoutSeconds: 5
        ) else { return [:] }

        var result: [Int: String] = [:]
        var currentPid: Int?
        for line in out.split(separator: "\n") {
            if line.hasPrefix("p"), let pid = Int(line.dropFirst()) {
                currentPid = pid
            } else if line.hasPrefix("n"), let pid = currentPid {
                result[pid] = String(line.dropFirst())
            }
        }
        return result
    }

    /// Normalize a filesystem path so two strings naming the same directory
    /// compare equal: resolves symlinks (e.g. `/Users/foo` vs an Apple
    /// `/private/Users/foo` style chain) and standardizes (`..`, `~`,
    /// trailing slashes). Used by the cwd-matching liveness path because
    /// `lsof` and the JSONL `cwd` field are both raw kernel/user input
    /// and may disagree on form even when they name the same directory.
    public static func canonicalize(_ path: String) -> String {
        ((path as NSString).resolvingSymlinksInPath as NSString).standardizingPath
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
    ///
    /// **Why the background drain matters**: macOS pipe buffers are 16-64KB.
    /// If the subprocess writes more than that and we don't read concurrently,
    /// it blocks on the next write and `task.isRunning` stays true forever.
    /// The previous polling-only implementation deadlocked silently for any
    /// command with non-trivial output (e.g. `ps -ax` with 1000+ processes).
    ///
    /// stderr is redirected to /dev/null — same deadlock applies to stderr,
    /// and we never look at stderr from any caller.
    private static func runWithTimeout(_ path: String, args: [String], timeoutSeconds: Int) -> String? {
        let task = Process()
        task.launchPath = path
        task.arguments = args
        let stdoutPipe = Pipe()
        task.standardOutput = stdoutPipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return nil }

        // Drain stdout on a background queue so the subprocess can flush
        // freely. Without this, large outputs deadlock the wait below.
        // The DataHolder is its own synchronization barrier — captured
        // closures only touch it via lock-protected accessors so reads
        // after `drainGroup.wait` see a consistent value.
        let holder = DataHolder()
        let drainGroup = DispatchGroup()
        drainGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            holder.set(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            drainGroup.leave()
        }

        // Schedule a kill if the process overruns its budget. Cancelled
        // immediately on normal exit so we don't fire after success.
        // The `holder.markTimedOut()` only fires when we actually terminate
        // the task — that lets the caller distinguish a real timeout
        // (return nil) from "ran cleanly with empty output" (return "").
        let killer = DispatchWorkItem { [task, holder] in
            guard task.isRunning else { return }
            holder.markTimedOut()
            task.terminate()
            Thread.sleep(forTimeInterval: 0.05)
            if task.isRunning { kill(task.processIdentifier, SIGKILL) }
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + .seconds(timeoutSeconds), execute: killer
        )

        task.waitUntilExit()
        killer.cancel()

        // Drain finishes when the pipe closes — should be near-instant.
        _ = drainGroup.wait(timeout: .now() + 1.0)

        if holder.isTimedOut() { return nil }
        return String(data: holder.get(), encoding: .utf8)
    }

    /// Lock-protected `Data` holder + timeout flag so the background drain
    /// and the timer-driven killer in `runWithTimeout` can both hand state
    /// back to the caller without a data race. Marked `@unchecked Sendable`
    /// because we provide our own synchronization (NSLock) and never expose
    /// the inner storage.
    ///
    /// `markTimedOut` is called by the killer ONLY when it actually
    /// terminates a still-running task — so it accurately reflects "we
    /// killed it because the deadline passed", not "the killer's
    /// `DispatchWorkItem` happened to dequeue after the task naturally
    /// exited". `runWithTimeout` checks this before turning the buffered
    /// stdout into a String, so callers can distinguish a real timeout
    /// (return `nil`) from "ran cleanly with no output" (return `""`).
    private final class DataHolder: @unchecked Sendable {
        private var storage = Data()
        private var timedOut = false
        private let lock = NSLock()
        func set(_ value: Data) {
            lock.lock(); storage = value; lock.unlock()
        }
        func get() -> Data {
            lock.lock(); defer { lock.unlock() }
            return storage
        }
        func markTimedOut() {
            lock.lock(); timedOut = true; lock.unlock()
        }
        func isTimedOut() -> Bool {
            lock.lock(); defer { lock.unlock() }
            return timedOut
        }
    }

    private static func claudePidByCwd(_ targetCwd: String) -> Int? {
        guard let pids = runningClaudePids() else {
            NSLog("ZackEyes: ps command failed or timed out")
            return nil
        }
        let cwdMap = batchProcessCwds(pids: pids)
        let target = canonicalize(targetCwd)
        for (pid, cwd) in cwdMap where canonicalize(cwd) == target {
            return pid
        }
        NSLog("ZackEyes: scanned %d claude candidates, no cwd match for %{public}@",
              pids.count, targetCwd)
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

    /// PID-less Ghostty jump for idle/detected sessions. Finds Ghostty
    /// by bundle ID and runs Layer A (sid marker) → Layer A' (cwd basename).
    /// Does nothing if Ghostty isn't running.
    @discardableResult
    public static func activateGhosttyDirectly(
        sessionId: String,
        cwd: String?
    ) -> Bool {
        guard let app = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.mitchellh.ghostty"
        ).first else { return false }
        _ = app.activate(options: [])
        if focusGhosttySession(app: app, sessionId: sessionId, cwd: cwd) {
            return true
        }
        return focusByAccessibility(app: app, cwd: cwd)
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

        // Tab was matched by basename and switched to — good enough for
        // idle sessions that have no sid marker. Precise pane matching
        // only works when the marker is present (live sessions).
        return true
    }
}
