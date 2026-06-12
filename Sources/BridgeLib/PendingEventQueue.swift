import Foundation

/// Write-side spool for fire-and-forget hook events that couldn't reach the
/// app's socket (#89). The bridge calls `enqueueIfEligible` only after a
/// failed `sendFireAndForget`; the app replays and deletes the files at next
/// startup via `PendingEventReplayer`.
///
/// Bridge invariant #2 applies in full: every operation here is best-effort
/// and silent. A failed directory creation, a full disk, a permission error —
/// all are swallowed; the caller still exits 0 with no output.
///
/// Only low-frequency lifecycle events are spooled. StatusLine ticks every
/// few seconds and its rate-limit payload is worthless when stale; tool
/// events (PreToolUse/PostToolUse) can number in the hundreds per session and
/// are reconstructed from transcripts by SessionScanner anyway;
/// PermissionRequest is blocking and meaningless to replay.
public struct PendingEventQueue: Sendable {

    public static let replayableEvents: Set<String> = [
        "SessionStart", "SessionEnd", "Stop", "UserPromptSubmit",
        "Notification", "PreCompact", "PostCompact",
        "SubagentStart", "SubagentStop",
    ]

    private let directory: String
    private let maxCount: Int

    public init(
        directory: String = NSHomeDirectory() + "/.zackeyes/pending",
        maxCount: Int = 200
    ) {
        self.directory = directory
        self.maxCount = maxCount
    }

    /// Best-effort spool of one newline-terminated JSON event payload.
    /// File name `<unix-ms>-<pid>-<uuid>.json` — the fixed-width millisecond
    /// prefix makes lexicographic order chronological for the replayer.
    public func enqueueIfEligible(event: String, payload: Data, now: Date = Date()) {
        guard Self.replayableEvents.contains(event) else { return }
        let fm = FileManager.default
        guard (try? fm.createDirectory(
            atPath: directory, withIntermediateDirectories: true)) != nil
        else { return }

        let ms = Int(now.timeIntervalSince1970 * 1000)
        let name = "\(ms)-\(getpid())-\(UUID().uuidString).json"
        let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
        guard (try? payload.write(to: url, options: .atomic)) != nil else { return }

        pruneOverCap()
    }

    /// Evict oldest files beyond `maxCount`. Newer events win: a SessionEnd
    /// from five minutes ago beats a SessionStart from last week.
    private func pruneOverCap() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory) else { return }
        let sorted = names.filter { $0.hasSuffix(".json") }.sorted()
        guard sorted.count > maxCount else { return }
        for name in sorted.prefix(sorted.count - maxCount) {
            try? fm.removeItem(atPath: directory + "/" + name)
        }
    }
}
