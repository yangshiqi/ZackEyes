import Foundation

/// Resolve the tty path for a process by shelling out to `ps -p PID -o tty=`.
/// Split into a pure parser (`parseTTYOutput`) and the IO wrapper (`ttyPath`)
/// so the parsing rules can be unit-tested without running a subprocess.
public enum TTYUtil {

    /// Pure: transform the raw `ps -o tty=` output into a canonical `/dev/`
    /// pty path (`/dev/ttysN` or `/dev/pts/N`).
    /// Returns nil unless the output names a real pty slave.
    ///
    /// A process with no controlling terminal prints `??` on macOS — measured,
    /// not assumed — which the previous `!= "?"` guard let through and turned
    /// into `/dev/??` (#204). Rather than chase each sentinel, accept only the
    /// two shapes a pty slave actually has. That also keeps the value safe for
    /// the AppleScript interpolation in `TerminalLocator`, which embeds it into
    /// source text.
    public static func parseTTYOutput(_ raw: String) -> String? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/dev/") { trimmed.removeFirst("/dev/".count) }
        let isPtySlave = trimmed.range(of: #"^(ttys[0-9]+|pts/[0-9]+)$"#, options: .regularExpression) != nil
        guard isPtySlave else { return nil }
        return "/dev/\(trimmed)"
    }

    /// Lookup the controlling tty of `pid` via `/bin/ps`. Returns nil on any error.
    public static func ttyPath(pid: Int32) -> String? {
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
        return parseTTYOutput(raw)
    }
}
