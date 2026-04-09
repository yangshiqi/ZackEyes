import Foundation

/// Resolve the tty path for a process by shelling out to `ps -p PID -o tty=`.
/// Split into a pure parser (`parseTTYOutput`) and the IO wrapper (`ttyPath`)
/// so the parsing rules can be unit-tested without running a subprocess.
public enum TTYUtil {

    /// Pure: transform the raw `ps -o tty=` output into a `/dev/ttys…` path.
    /// Returns nil for empty, whitespace-only, or `?` (no controlling tty).
    public static func parseTTYOutput(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "?" else { return nil }
        if trimmed.hasPrefix("/dev/") { return trimmed }
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
