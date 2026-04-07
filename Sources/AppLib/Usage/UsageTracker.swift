import Foundation

/// Aggregates Claude Code token usage across recent sessions by time window.
///
/// Reads all JSONL transcripts in `~/.claude/projects/`, sums `message.usage`
/// fields (input + output + cache tokens) within 5h and 7d sliding windows.
///
/// Note: we don't have subscriber quota limits from Claude Code directly,
/// so we show raw token counts rather than percentages. If Claude Code later
/// exposes quota info via hook metadata, we can layer that on top.
@MainActor
public final class UsageTracker: ObservableObject {

    public struct Snapshot: Sendable {
        public var tokens5h: Int
        public var tokens7d: Int
        public var messages5h: Int
        public var messages7d: Int

        public static let empty = Snapshot(tokens5h: 0, tokens7d: 0, messages5h: 0, messages7d: 0)
    }

    @Published public private(set) var snapshot: Snapshot = .empty

    private let projectsDir: URL
    private var refreshTask: Task<Void, Never>?

    public init(projectsDir: URL = URL(fileURLWithPath: NSHomeDirectory() + "/.claude/projects")) {
        self.projectsDir = projectsDir
    }

    /// Start periodic refresh every N seconds.
    public func start(intervalSeconds: Int = 30) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(intervalSeconds))
            }
        }
    }

    public func stop() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    /// Rescan all recent JSONL files and update the snapshot.
    public func refresh() async {
        let dir = projectsDir
        let newSnapshot = await Task.detached(priority: .utility) {
            Self.computeSnapshot(projectsDir: dir)
        }.value
        self.snapshot = newSnapshot
    }

    // MARK: - Computation

    private nonisolated static func computeSnapshot(projectsDir: URL) -> Snapshot {
        let now = Date()
        let cutoff5h = now.addingTimeInterval(-5 * 3600)
        let cutoff7d = now.addingTimeInterval(-7 * 86400)

        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(
            at: projectsDir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return .empty }

        var tokens5h = 0, tokens7d = 0, msgs5h = 0, msgs7d = 0

        for projectDir in projectDirs {
            guard let files = try? fm.contentsOfDirectory(
                at: projectDir,
                includingPropertiesForKeys: [.contentModificationDateKey]
            ) else { continue }

            for file in files where file.pathExtension == "jsonl" {
                // Quick filter: skip files whose mtime is older than the 7d window
                if let attrs = try? fm.attributesOfItem(atPath: file.path),
                   let mod = attrs[.modificationDate] as? Date,
                   mod < cutoff7d {
                    continue
                }

                parseFile(at: file, cutoff5h: cutoff5h, cutoff7d: cutoff7d,
                          tokens5h: &tokens5h, tokens7d: &tokens7d,
                          msgs5h: &msgs5h, msgs7d: &msgs7d)
            }
        }

        return Snapshot(tokens5h: tokens5h, tokens7d: tokens7d,
                        messages5h: msgs5h, messages7d: msgs7d)
    }

    private nonisolated static func parseFile(
        at url: URL,
        cutoff5h: Date, cutoff7d: Date,
        tokens5h: inout Int, tokens7d: inout Int,
        msgs5h: inout Int, msgs7d: inout Int
    ) {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoNoFrac = ISO8601DateFormatter()

        for line in text.split(separator: "\n") {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }

            // Parse timestamp — JSONL entries usually have "timestamp" at the top level
            guard let tsString = obj["timestamp"] as? String,
                  let ts = iso.date(from: tsString) ?? isoNoFrac.date(from: tsString) else {
                continue
            }
            if ts < cutoff7d { continue }

            // Only count assistant messages (they carry usage data)
            guard (obj["type"] as? String) == "assistant",
                  let msg = obj["message"] as? [String: Any],
                  let usage = msg["usage"] as? [String: Any] else { continue }

            let input = (usage["input_tokens"] as? Int) ?? 0
            let output = (usage["output_tokens"] as? Int) ?? 0
            let cacheRead = (usage["cache_read_input_tokens"] as? Int) ?? 0
            let cacheCreate = (usage["cache_creation_input_tokens"] as? Int) ?? 0
            let total = input + output + cacheRead + cacheCreate

            tokens7d += total
            msgs7d += 1
            if ts >= cutoff5h {
                tokens5h += total
                msgs5h += 1
            }
        }
    }
}
