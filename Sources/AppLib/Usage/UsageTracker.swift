import Foundation
import Shared

/// Tracks Claude Code subscriber rate limits + token usage.
///
/// **Primary source**: hook event JSON contains a `rate_limits` field with
/// real `used_percentage` and `resets_at` values for `five_hour` / `seven_day`
/// windows. We capture these whenever any session reports them.
///
/// **Fallback**: when no live rate_limits data is available yet, we estimate
/// from transcript token counts (rough — only used as a placeholder).
@MainActor
public final class UsageTracker: ObservableObject {

    public struct Snapshot: Sendable, Codable {
        // Real subscriber data from hook rate_limits (preferred)
        public var fiveHourUsedPct: Double?
        public var fiveHourResetsAt: Date?
        public var sevenDayUsedPct: Double?
        public var sevenDayResetsAt: Date?

        // Fallback estimates from transcript scanning
        public var tokens5h: Int
        public var tokens7d: Int
        public var messages5h: Int
        public var messages7d: Int

        // Last time we received fresh rate_limits data from a hook
        public var lastUpdated: Date?

        public static let empty = Snapshot(
            fiveHourUsedPct: nil,
            fiveHourResetsAt: nil,
            sevenDayUsedPct: nil,
            sevenDayResetsAt: nil,
            tokens5h: 0,
            tokens7d: 0,
            messages5h: 0,
            messages7d: 0,
            lastUpdated: nil
        )

        public var hasRealData: Bool {
            fiveHourUsedPct != nil || sevenDayUsedPct != nil
        }
    }

    @Published public private(set) var snapshot: Snapshot = .empty

    /// Path where we persist the last received rate_limits snapshot so the UI
    /// can show meaningful data immediately on next launch instead of "no data".
    private let cacheURL: URL = {
        URL(fileURLWithPath: NSHomeDirectory() + "/.zackeyes/usage-cache.json")
    }()

    /// Update real subscriber rate limit data from a hook event.
    /// Call whenever a `BridgeEvent` arrives with non-nil `rateLimits`.
    public func updateFromHook(rateLimits: [String: AnyCodable]) {
        var s = snapshot
        s.lastUpdated = Date()

        if let fh = rateLimits["five_hour"]?.value as? [String: Any] {
            if let used = fh["used_percentage"] as? Double {
                s.fiveHourUsedPct = used
            } else if let used = fh["used_percentage"] as? Int {
                s.fiveHourUsedPct = Double(used)
            }
            if let resets = fh["resets_at"] as? Double {
                s.fiveHourResetsAt = Date(timeIntervalSince1970: resets > 1e12 ? resets / 1000 : resets)
            } else if let resets = fh["resets_at"] as? Int {
                let secs = resets > 1_000_000_000_000 ? Double(resets) / 1000 : Double(resets)
                s.fiveHourResetsAt = Date(timeIntervalSince1970: secs)
            }
        }

        if let sd = rateLimits["seven_day"]?.value as? [String: Any] {
            if let used = sd["used_percentage"] as? Double {
                s.sevenDayUsedPct = used
            } else if let used = sd["used_percentage"] as? Int {
                s.sevenDayUsedPct = Double(used)
            }
            if let resets = sd["resets_at"] as? Double {
                s.sevenDayResetsAt = Date(timeIntervalSince1970: resets > 1e12 ? resets / 1000 : resets)
            } else if let resets = sd["resets_at"] as? Int {
                let secs = resets > 1_000_000_000_000 ? Double(resets) / 1000 : Double(resets)
                s.sevenDayResetsAt = Date(timeIntervalSince1970: secs)
            }
        }

        snapshot = s
        saveToCache()
    }

    private let projectsDir: URL
    private var refreshTask: Task<Void, Never>?

    public init(projectsDir: URL = URL(fileURLWithPath: NSHomeDirectory() + "/.claude/projects")) {
        self.projectsDir = projectsDir
    }

    /// Start periodic refresh every N seconds.
    /// Restores the cached snapshot from disk first (so the UI doesn't show
    /// "no data" while waiting for the first live event).
    public func start(intervalSeconds: Int = 30) {
        loadFromCache()
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(intervalSeconds))
            }
        }
    }

    /// Load the last persisted rate_limits snapshot.
    private func loadFromCache() {
        guard let data = try? Data(contentsOf: cacheURL),
              let cached = try? JSONDecoder().decode(Snapshot.self, from: data) else {
            return
        }
        snapshot = cached
    }

    /// Persist the snapshot's rate_limits fields so we can restore them on next launch.
    private func saveToCache() {
        let dir = cacheURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }

    public func stop() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    /// Rescan all recent JSONL files and update the snapshot.
    /// Preserves real rate-limit data captured from hook events.
    public func refresh() async {
        let dir = projectsDir
        let estimated = await Task.detached(priority: .utility) {
            Self.computeSnapshot(projectsDir: dir)
        }.value
        var merged = snapshot
        merged.tokens5h = estimated.tokens5h
        merged.tokens7d = estimated.tokens7d
        merged.messages5h = estimated.messages5h
        merged.messages7d = estimated.messages7d
        self.snapshot = merged
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

        return Snapshot(
            fiveHourUsedPct: nil,
            fiveHourResetsAt: nil,
            sevenDayUsedPct: nil,
            sevenDayResetsAt: nil,
            tokens5h: tokens5h,
            tokens7d: tokens7d,
            messages5h: msgs5h,
            messages7d: msgs7d
        )
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
