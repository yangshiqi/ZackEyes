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
        // --- Claude subscriber data (StatusLine hook rate_limits) ---
        public var fiveHourUsedPct: Double?
        public var fiveHourResetsAt: Date?
        public var sevenDayUsedPct: Double?
        public var sevenDayResetsAt: Date?

        // --- Codex rate limits (parsed from session jsonl `event_msg.token_count`) ---
        // Codex emits the same conceptual primary/secondary windows (5h / 7d)
        // but in its own field shape — we map them onto the same axes.
        public var codexFiveHourUsedPct: Double?
        public var codexFiveHourResetsAt: Date?
        public var codexSevenDayUsedPct: Double?
        public var codexSevenDayResetsAt: Date?

        // Fallback estimates from transcript scanning (Claude-only)
        public var tokens5h: Int
        public var tokens7d: Int
        public var messages5h: Int
        public var messages7d: Int

        // Last time we received fresh rate_limits data from any source
        public var lastUpdated: Date?

        public static let empty = Snapshot(
            fiveHourUsedPct: nil,
            fiveHourResetsAt: nil,
            sevenDayUsedPct: nil,
            sevenDayResetsAt: nil,
            codexFiveHourUsedPct: nil,
            codexFiveHourResetsAt: nil,
            codexSevenDayUsedPct: nil,
            codexSevenDayResetsAt: nil,
            tokens5h: 0,
            tokens7d: 0,
            messages5h: 0,
            messages7d: 0,
            lastUpdated: nil
        )

        public var hasClaudeData: Bool {
            fiveHourUsedPct != nil || sevenDayUsedPct != nil
        }

        public var hasCodexData: Bool {
            codexFiveHourUsedPct != nil || codexSevenDayUsedPct != nil
        }

        public var hasRealData: Bool { hasClaudeData || hasCodexData }

        /// 5h-window used-percentage for the given agent, or nil if no data.
        /// Lets call sites avoid the `agent == .codex ? codex... : ...` ternary.
        public func fiveHourUsedPct(for agent: AgentKind) -> Double? {
            switch agent {
            case .claude: return fiveHourUsedPct
            case .codex:  return codexFiveHourUsedPct
            }
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

    /// Update Codex rate limit data from a `event_msg.token_count.rate_limits`
    /// payload (parses the same shape codex writes to its session jsonl).
    /// Codex doesn't fire hooks, so this is only called by tests + the
    /// background scanner via the nonisolated decoder below.
    public func updateFromCodexRateLimits(_ rateLimits: [String: Any]) {
        applyCodexObservation(Self.decodeCodexObservation(from: rateLimits))
    }

    private let projectsDir: URL
    private let codexSessionsDir: URL?
    private var refreshTask: Task<Void, Never>?

    public init(
        projectsDir: URL = URL(fileURLWithPath: NSHomeDirectory() + "/.claude/projects"),
        codexSessionsDir: URL? = URL(fileURLWithPath: NSHomeDirectory() + "/.codex/sessions")
    ) {
        self.projectsDir = projectsDir
        self.codexSessionsDir = codexSessionsDir
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

    /// Sendable observation of a codex `rate_limits` snapshot. We decode out
    /// of the dynamic JSON into this fixed-shape struct in the background
    /// task so the cross-actor return value is Sendable.
    public struct CodexRateLimitObservation: Sendable {
        public var fiveHourUsedPct: Double?
        public var fiveHourResetsAt: Date?
        public var sevenDayUsedPct: Double?
        public var sevenDayResetsAt: Date?
    }

    /// Rescan all recent JSONL files and update the snapshot.
    /// Preserves real rate-limit data captured from hook events.
    public func refresh() async {
        let dir = projectsDir
        let codexDir = codexSessionsDir
        let estimated = await Task.detached(priority: .utility) {
            Self.computeSnapshot(projectsDir: dir)
        }.value
        let codexObservation = await Task.detached(priority: .utility) { () -> CodexRateLimitObservation? in
            guard let codexDir else { return nil }
            return Self.scanLatestCodexRateLimits(rootDir: codexDir)
        }.value

        var merged = snapshot
        merged.tokens5h = estimated.tokens5h
        merged.tokens7d = estimated.tokens7d
        merged.messages5h = estimated.messages5h
        merged.messages7d = estimated.messages7d
        self.snapshot = merged

        if let obs = codexObservation {
            applyCodexObservation(obs)
        } else {
            // No codex rollout written within the active window → user is
            // not currently using codex. Clear the codex fields so the bar
            // disappears instead of pinning to whatever historical or cached
            // value last landed in the snapshot.
            clearCodexData()
        }
    }

    private func clearCodexData() {
        var s = snapshot
        // Skip the Published mutation + cache write when nothing changes.
        if s.codexFiveHourUsedPct == nil
            && s.codexFiveHourResetsAt == nil
            && s.codexSevenDayUsedPct == nil
            && s.codexSevenDayResetsAt == nil { return }
        s.codexFiveHourUsedPct = nil
        s.codexFiveHourResetsAt = nil
        s.codexSevenDayUsedPct = nil
        s.codexSevenDayResetsAt = nil
        snapshot = s
        saveToCache()
    }

    private func applyCodexObservation(_ obs: CodexRateLimitObservation) {
        var s = snapshot
        s.lastUpdated = Date()
        if let v = obs.fiveHourUsedPct { s.codexFiveHourUsedPct = v }
        if let v = obs.fiveHourResetsAt { s.codexFiveHourResetsAt = v }
        if let v = obs.sevenDayUsedPct { s.codexSevenDayUsedPct = v }
        if let v = obs.sevenDayResetsAt { s.codexSevenDayResetsAt = v }
        snapshot = s
        saveToCache()
    }

    /// Codex rollout-mtime window for "is codex actively running right now".
    /// A rollout file's mtime advances on every event_msg write, so anything
    /// older than this is taken as "the user is not currently using codex" —
    /// we hide the codex usage bar in that case so it tracks current activity
    /// instead of historical state. 15 min mirrors the codex idle prune in
    /// AppDelegate.runLivenessSweep.
    public nonisolated static let codexActiveWindowSeconds: TimeInterval = 15 * 60

    /// Walk the date-partitioned codex sessions tree and return the
    /// `rate_limits` payload from the most recent `event_msg.token_count`
    /// event, decoded into a Sendable observation. Returns `nil` if no
    /// rollout has been written within `recentSeconds` (default
    /// `codexActiveWindowSeconds` = 15 min). Bounded — only reads the tail
    /// of each candidate file.
    nonisolated static func scanLatestCodexRateLimits(
        rootDir: URL,
        recentSeconds: TimeInterval = codexActiveWindowSeconds
    ) -> CodexRateLimitObservation? {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-recentSeconds)
        struct Candidate {
            let url: URL
            let mtime: Date
        }
        var candidates: [Candidate] = []
        // Walk every YYYY/MM/DD dir, not just the ones whose UTC name
        // intersects the cutoff. `codex --resume` keeps appending to the
        // resumed session's original date dir, which can be arbitrarily
        // old — pruning by dir name silently drops those rollouts even when
        // their files are mtime-fresh. Filter on the file's own mtime below.
        for day in SessionScanner.allDateDirs(under: rootDir) {
            guard let files = try? fm.contentsOfDirectory(
                at: day,
                includingPropertiesForKeys: [.contentModificationDateKey]
            ) else { continue }
            for file in files where file.pathExtension == "jsonl" {
                // Pre-fetched mtime via URL.resourceValues — avoids an
                // extra stat() per file.
                guard let mod = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                      mod >= cutoff else { continue }
                candidates.append(Candidate(url: file, mtime: mod))
            }
        }
        // Walk newest-first; first file with a token_count event wins.
        let sorted = candidates.sorted { $0.mtime > $1.mtime }
        for c in sorted {
            if let obs = lastTokenCountObservation(in: c.url) {
                return obs
            }
        }
        return nil
    }

    /// Tail-scan a codex rollout jsonl for the last `event_msg` line whose
    /// payload type is `token_count`, and decode its `rate_limits` into a
    /// Sendable observation.
    private nonisolated static func lastTokenCountObservation(in url: URL) -> CodexRateLimitObservation? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let fileSize: UInt64
        do {
            fileSize = try handle.seekToEnd()
        } catch {
            return nil
        }
        // 256KB tail covers many turns of token_count payloads (each ~500B).
        let readSize: UInt64 = 262_144
        let offset = fileSize > readSize ? fileSize - readSize : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return nil }

        var observation: CodexRateLimitObservation? = nil
        for line in text.split(separator: "\n") {
            guard let lineData = line.data(using: .utf8) else { continue }
            guard let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }
            guard obj["type"] as? String == "event_msg" else { continue }
            guard let payload = obj["payload"] as? [String: Any] else { continue }
            guard payload["type"] as? String == "token_count" else { continue }
            guard let rl = payload["rate_limits"] as? [String: Any] else { continue }
            observation = decodeCodexObservation(from: rl)
        }
        return observation
    }

    /// Decode codex rate_limits dict into the Sendable observation struct.
    /// Codex schema (verified 2026-05-03):
    ///   primary:   {used_percent, window_minutes=300,   resets_at}  → 5h
    ///   secondary: {used_percent, window_minutes=10080, resets_at}  → 7d
    /// `resets_at` is unix seconds (integer or double).
    nonisolated static func decodeCodexObservation(from rl: [String: Any]) -> CodexRateLimitObservation {
        var obs = CodexRateLimitObservation()

        if let primary = rl["primary"] as? [String: Any] {
            if let used = primary["used_percent"] as? Double {
                obs.fiveHourUsedPct = used
            } else if let used = primary["used_percent"] as? Int {
                obs.fiveHourUsedPct = Double(used)
            }
            if let resets = primary["resets_at"] as? Double {
                obs.fiveHourResetsAt = Date(timeIntervalSince1970: resets > 1e12 ? resets / 1000 : resets)
            } else if let resets = primary["resets_at"] as? Int {
                let secs = resets > 1_000_000_000_000 ? Double(resets) / 1000 : Double(resets)
                obs.fiveHourResetsAt = Date(timeIntervalSince1970: secs)
            }
        }
        if let secondary = rl["secondary"] as? [String: Any] {
            if let used = secondary["used_percent"] as? Double {
                obs.sevenDayUsedPct = used
            } else if let used = secondary["used_percent"] as? Int {
                obs.sevenDayUsedPct = Double(used)
            }
            if let resets = secondary["resets_at"] as? Double {
                obs.sevenDayResetsAt = Date(timeIntervalSince1970: resets > 1e12 ? resets / 1000 : resets)
            } else if let resets = secondary["resets_at"] as? Int {
                let secs = resets > 1_000_000_000_000 ? Double(resets) / 1000 : Double(resets)
                obs.sevenDayResetsAt = Date(timeIntervalSince1970: secs)
            }
        }
        return obs
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
