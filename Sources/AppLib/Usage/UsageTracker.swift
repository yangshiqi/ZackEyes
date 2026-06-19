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

        // #84 — per-local-day consumption (tokens + cost), 7 entries oldest→today.
        // NOT trusted from cache (cleared on load, rebuilt by refresh) to avoid a
        // stale "today" after midnight.
        public var dailyUsage: [DayUsage] = []

        // #86 — predicted time until the 5h window reaches 100%, extrapolated
        // from successive `used%` readings. Recomputed on every update and aged
        // out when idle; excluded from Codable so a stale ETA never restores
        // across launches.
        public var fiveHourETA: CapETA? = nil
        public var codexFiveHourETA: CapETA? = nil

        // `dailyUsage` is intentionally excluded from Codable: it is rebuilt on
        // every refresh and must never restore a stale "today" — and omitting it
        // keeps pre-#84 usage-cache.json (without this key) decodable on upgrade.
        private enum CodingKeys: String, CodingKey {
            case fiveHourUsedPct, fiveHourResetsAt, sevenDayUsedPct, sevenDayResetsAt
            case codexFiveHourUsedPct, codexFiveHourResetsAt, codexSevenDayUsedPct, codexSevenDayResetsAt
            case tokens5h, tokens7d, messages5h, messages7d, lastUpdated
        }

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

        /// True when any of the 7 daily buckets has nonzero consumption — drives
        /// whether the #84 Today row is shown at all (hidden on fresh installs).
        public var hasConsumption: Bool {
            dailyUsage.contains { $0.totalTokens > 0 }
        }

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

    /// User preference (#84): whether the expanded "Today" consumption row is
    /// shown. Default true; seeded from `ConfigStore` by `AppDelegate`, toggled
    /// from the gear menu. Both expanded notch headers observe this.
    @Published public var showTodayConsumption: Bool = true

    /// Pricing source for daily cost (both `@MainActor`; read after the detached
    /// scan returns). Weak so it never extends the store's lifetime.
    public weak var pricingStore: PricingStore?

    /// Per-file Codex daily-scan parse cache, keyed by file path. Lives on the
    /// main actor; passed by value into the detached scan and replaced on return.
    private var codexDailyCache: [String: FileTally] = [:]

    /// Per-file Claude transcript parse cache, keyed by resolved path. Same
    /// lifecycle as `codexDailyCache` — passed by value into the detached scan
    /// and replaced on return. Bounds the cost of the recursive #116 scan: in
    /// steady state only the actively-written file is re-parsed.
    private var claudeFileCache: [String: ClaudeFileCache] = [:]

    /// #86 — rolling burn-rate estimators, one per agent. Fed `(now, used%)`
    /// readings as they arrive; queried for the 5h cap ETA. Plain value types,
    /// so they're confined to this @MainActor instance.
    private var claudeEstimator = BurnRateEstimator()
    private var codexEstimator = BurnRateEstimator()

    /// #116 — anchor for between-hook 5h% interpolation: the real used% and the
    /// transcript 5h-token total captured at the last rate-limit update. Lets
    /// refresh() scale the displayed % up as tokens burn during a long turn
    /// (e.g. a Workflow fan-out) instead of freezing until the next hook.
    private var fiveHourAnchorPct: Double?
    private var fiveHourAnchorTokens: Int?

    /// Path where we persist the last received rate_limits snapshot so the UI
    /// can show meaningful data immediately on next launch instead of "no data".
    private let cacheURL: URL = {
        URL(fileURLWithPath: NSHomeDirectory() + "/.zackeyes/usage-cache.json")
    }()

    /// Update real subscriber rate limit data from a hook event.
    /// Call whenever a `BridgeEvent` arrives with non-nil `rateLimits`.
    public func updateFromHook(rateLimits: [String: AnyCodable]) {
        var s = snapshot
        let now = Date()
        s.lastUpdated = now
        var freshFivePct: Double? = nil

        if let fh = rateLimits["five_hour"]?.value as? [String: Any] {
            if let used = fh["used_percentage"] as? Double {
                s.fiveHourUsedPct = used
                freshFivePct = used
            } else if let used = fh["used_percentage"] as? Int {
                s.fiveHourUsedPct = Double(used)
                freshFivePct = Double(used)
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

        // #86 — only feed the estimator when THIS event carried a fresh 5h
        // reading (otherwise we'd inject a duplicate flat point at a new time).
        // Always re-estimate so the ETA reflects the latest % + reset.
        if let used = freshFivePct {
            // #116 — re-anchor the between-hook interpolation on every real
            // reading. Defer the token baseline to the next scan (anchorTokens =
            // nil): `s.tokens5h` here is the PREVIOUS scan's total, so pairing it
            // with the fresh % would double-count tokens written since that scan
            // (Codex review). The next refresh baselines tokens to the same
            // instant the % is anchored to.
            fiveHourAnchorPct = used
            fiveHourAnchorTokens = nil
            claudeEstimator.record(now, pct: used)
        }
        s.fiveHourETA = claudeEstimator.estimate(
            now: now, currentPct: s.fiveHourUsedPct, resetsAt: s.fiveHourResetsAt)

        snapshot = s
        saveToCache()
    }

    /// #116 — provisional 5h used% between hook updates. Scales the last real
    /// reading by transcript token growth so a long burst (e.g. a Workflow
    /// fan-out) shows continuous movement instead of a frozen number that snaps
    /// at the next hook. Only ever raises the number (you can only burn more
    /// mid-turn); the next real rate_limit re-anchors and can lower it. Returns
    /// nil when there is no usable anchor or tokens haven't grown.
    nonisolated static func interpolatedFiveHourPct(
        anchorPct: Double?, anchorTokens: Int?, currentTokens: Int, floor: Double
    ) -> Double? {
        guard let p0 = anchorPct, p0 > 0,
              let t0 = anchorTokens, t0 > 0,
              currentTokens > t0 else { return nil }
        // `floor` keeps the result monotonic between hooks (never below the last
        // displayed value, which the rolling token window could otherwise undo).
        return min(100, max(floor, p0 * Double(currentTokens) / Double(t0)))
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
        var restored = cached
        restored.dailyUsage = []   // #84: never trust a persisted (possibly stale) "today"
        snapshot = restored
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
        let cal = Calendar.current
        let scanNow = Date()
        let claudeCacheSnapshot = claudeFileCache
        let claudeScan = await Task.detached(priority: .utility) {
            Self.computeSnapshot(projectsDir: dir, cache: claudeCacheSnapshot, calendar: cal, now: scanNow)
        }.value
        claudeFileCache = claudeScan.cache
        let estimated = claudeScan.snapshot
        let codexObservation = await Task.detached(priority: .utility) { () -> CodexRateLimitObservation? in
            guard let codexDir else { return nil }
            return Self.scanLatestCodexRateLimits(rootDir: codexDir)
        }.value

        // #84 daily token scan (Codex), with the per-file parse cache.
        let codexCacheSnapshot = codexDailyCache
        let codexDaily = await Task.detached(priority: .utility) {
            () -> (merged: [Date: [String: ModelTokenTally]], cache: [String: FileTally])? in
            guard let codexDir else { return nil }
            return Self.scanCodexDailyTokens(rootDir: codexDir, cache: codexCacheSnapshot, calendar: cal, now: scanNow)
        }.value
        if let codexDaily { codexDailyCache = codexDaily.cache }

        var merged = snapshot
        merged.tokens5h = estimated.tokens5h
        merged.tokens7d = estimated.tokens7d
        merged.messages5h = estimated.messages5h
        merged.messages7d = estimated.messages7d
        merged.dailyUsage = Self.buildDailyUsage(
            claude: claudeScan.daily,
            codex: codexDaily?.merged ?? [:],
            pricing: pricingStore?.table ?? .empty,
            calendar: cal, now: scanNow
        )
        // #116 — between hooks, scale the displayed 5h% by transcript token
        // growth so a long burst (a Workflow fan-out) moves continuously instead
        // of freezing then snapping at the next hook. Skip once the window has
        // reset (resets_at passed): the sliding token window and Claude's fixed
        // reset window diverge there, so we wait for the next real rate_limit.
        let pastFiveHourReset = merged.fiveHourResetsAt.map { Date() >= $0 } ?? false
        if !pastFiveHourReset, let p0 = fiveHourAnchorPct {
            if fiveHourAnchorTokens == nil {
                // First scan after a real reading: baseline the token count so the
                // anchor (real %, tokens) refers to the same instant — no stale
                // double-count. Don't interpolate this tick (no growth yet).
                fiveHourAnchorTokens = merged.tokens5h
            } else if let smoothed = Self.interpolatedFiveHourPct(
                          anchorPct: p0, anchorTokens: fiveHourAnchorTokens,
                          currentTokens: merged.tokens5h,
                          // Monotonic between hooks: floor at the last displayed
                          // value so the rolling-window scan can't pull % back
                          // (only a real lower rate_limit does). Feeds the #86 ETA.
                          floor: merged.fiveHourUsedPct ?? p0) {
                merged.fiveHourUsedPct = smoothed
                claudeEstimator.record(Date(), pct: smoothed)
            }
        }
        // #86 — re-estimate Claude ETA on the refresh tick so it ages out to
        // `.computing` when no hook arrived recently (idle), instead of pinning
        // the last live countdown. Uses Date() — NOT the older `scanNow` captured
        // before the heavy disk scans above — so staleness/aging is measured
        // against the true current time (a concurrent hook may have recorded a
        // sample newer than scanNow). No new sample is recorded here.
        merged.fiveHourETA = claudeEstimator.estimate(
            now: Date(), currentPct: merged.fiveHourUsedPct, resetsAt: merged.fiveHourResetsAt)
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
            && s.codexSevenDayResetsAt == nil
            && s.codexFiveHourETA == nil { return }
        s.codexFiveHourUsedPct = nil
        s.codexFiveHourResetsAt = nil
        s.codexSevenDayUsedPct = nil
        s.codexSevenDayResetsAt = nil
        s.codexFiveHourETA = nil   // #86 — codex inactive → no countdown
        snapshot = s
        saveToCache()
    }

    private func applyCodexObservation(_ obs: CodexRateLimitObservation) {
        var s = snapshot
        let now = Date()
        s.lastUpdated = now
        if let v = obs.fiveHourUsedPct {
            s.codexFiveHourUsedPct = v
            codexEstimator.record(now, pct: v)   // #86 — same estimator, codex axis
        }
        if let v = obs.fiveHourResetsAt { s.codexFiveHourResetsAt = v }
        if let v = obs.sevenDayUsedPct { s.codexSevenDayUsedPct = v }
        if let v = obs.sevenDayResetsAt { s.codexSevenDayResetsAt = v }
        s.codexFiveHourETA = codexEstimator.estimate(
            now: now, currentPct: s.codexFiveHourUsedPct, resetsAt: s.codexFiveHourResetsAt)
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

    // MARK: - Codex Daily Token Scan

    /// Cached parse of one rollout file, keyed by identity `(mtime, size)`.
    struct FileTally: Sendable {
        var mtime: Date
        var size: UInt64
        var tallies: [Date: [String: ModelTokenTally]]
    }

    /// Full-window Codex daily-token scan with a per-file parse cache. Walks all
    /// date dirs (codex --resume appends to old dirs), skips files untouched within
    /// the 7-day window, and reuses cached tallies for files whose `(mtime,size)`
    /// is unchanged — so steady-state cost ≈ the active rollout. Returns the merged
    /// tallies plus the refreshed cache (the caller stores the cache on @MainActor).
    nonisolated static func scanCodexDailyTokens(
        rootDir: URL,
        cache: [String: FileTally],
        calendar: Calendar,
        now: Date
    ) -> (merged: [Date: [String: ModelTokenTally]], cache: [String: FileTally]) {
        let dailyCutoff = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now))
            ?? now.addingTimeInterval(-7 * 86400)
        let fm = FileManager.default
        var newCache: [String: FileTally] = [:]
        var merged: [Date: [String: ModelTokenTally]] = [:]

        for dayDir in SessionScanner.allDateDirs(under: rootDir) {
            guard let files = try? fm.contentsOfDirectory(
                at: dayDir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
            ) else { continue }
            for file in files where file.pathExtension == "jsonl" {
                guard let vals = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isSymbolicLinkKey]),
                      let mtime = vals.contentModificationDate,
                      let size = vals.fileSize else { continue }
                if mtime < dailyCutoff { continue }   // file untouched within the window
                // Same size/symlink gate the Claude path uses (T-2): the 256MB
                // cap + symlink skip (PR #119 / F-008) was applied only to
                // computeSnapshot, not to this structurally identical codex scan.
                guard UsageTracker.shouldScanTranscript(
                    isSymbolicLink: vals.isSymbolicLink ?? false, fileSize: size
                ) else { continue }
                // Use the symlink-resolved path as cache key so that entries
                // created with /var/... (FileManager.temporaryDirectory) and
                // those returned by contentsOfDirectory (/private/var/...) match.
                let key = file.resolvingSymlinksInPath().path
                let tallies: [Date: [String: ModelTokenTally]]
                if let hit = cache[key], hit.mtime == mtime, hit.size == UInt64(size) {
                    tallies = hit.tallies               // cache hit — no re-parse
                } else if let text = try? String(contentsOf: file, encoding: .utf8) {
                    tallies = parseCodexDailyTallies(text: text, calendar: calendar, cutoff: dailyCutoff)
                } else {
                    tallies = [:]
                }
                newCache[key] = FileTally(mtime: mtime, size: UInt64(size), tallies: tallies)
                mergeTallies(&merged, tallies)
            }
        }
        return (merged, newCache)
    }

    // MARK: - Computation

    // `ClaudeScanResult` + `computeSnapshot` are internal (not private) so
    // AppLibTests can drive them directly via `@testable import AppLib`.
    /// Result of one Claude transcript scan: the 5h/7d estimate plus per-local-day
    /// token tallies (for the #84 Today row).
    struct ClaudeScanResult: Sendable {
        var snapshot: Snapshot
        var daily: [Date: [String: ModelTokenTally]]
        var cache: [String: ClaudeFileCache]
    }

    /// One assistant message's token usage, parsed out of a transcript line.
    /// Folding these against the (now-relative) 5h/7d/daily cutoffs is cheap; the
    /// expensive part — reading + JSON-parsing the file — is what `ClaudeFileCache`
    /// skips on unchanged files.
    struct ClaudeMsgRecord: Sendable {
        var ts: Date
        var id: String?
        var model: String
        var input: Int, output: Int, cacheRead: Int, cacheCreate: Int
    }

    /// Cached parse of one transcript file, keyed by identity `(mtime, size)`.
    /// Mirrors the Codex `FileTally` cache. Stores the raw per-message records
    /// (NOT deduped / NOT windowed) so the global dedup + rolling-window fold stay
    /// correct against the current `now` on every scan.
    struct ClaudeFileCache: Sendable {
        var mtime: Date
        var size: UInt64
        var records: [ClaudeMsgRecord]
    }

    /// Per-file size ceiling for the recursive transcript scan (scan finding
    /// F-008). Real transcripts are a few MB; this bounds a single planted or
    /// runaway `.jsonl` from forcing a multi-GB read on every 30s refresh.
    nonisolated static let maxTranscriptBytes = 256 * 1024 * 1024

    /// Security gate for the recursive scan (scan findings F-008 / F-009):
    /// never read a symlink — don't follow links out of the projects tree
    /// (defense in depth; `isRegularFile` already excludes them, but a security
    /// boundary shouldn't lean on that subtlety) — and skip oversized files.
    nonisolated static func shouldScanTranscript(isSymbolicLink: Bool, fileSize: Int) -> Bool {
        !isSymbolicLink && fileSize <= maxTranscriptBytes
    }

    /// Clamp an untrusted token count to a sane, non-negative ceiling so summing
    /// many records cannot overflow Int and trap the process (T-8). Real
    /// per-message counts are at most a few million; 1e9 is far above that yet
    /// far below Int.max, so all downstream accumulation stays safe.
    nonisolated static func clampTokens(_ value: Int) -> Int {
        min(max(0, value), 1_000_000_000)
    }

    nonisolated static func computeSnapshot(
        projectsDir: URL,
        cache: [String: ClaudeFileCache] = [:],
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> ClaudeScanResult {
        let cutoff5h = now.addingTimeInterval(-5 * 3600)
        let cutoff7d = now.addingTimeInterval(-7 * 86400)
        // Daily window: the 7 local days ending today (startOfDay(today) - 6 days).
        let dailyCutoff = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)) ?? cutoff7d
        // Keep any file touched within the wider of the two windows.
        let fileCutoff = min(cutoff7d, dailyCutoff)

        let fm = FileManager.default
        // #116: recurse the WHOLE projects tree, not just `<projectDir>/*.jsonl`.
        // Claude Code writes Task-subagent transcripts to `<session>/subagents/
        // agent-*.jsonl` and Workflow-tool agent transcripts to `<session>/
        // wf_<runId>/agent-*.jsonl` (and `<session>/subagents/workflows/wf_*/`).
        // A deep-research / workflow run burns most of its tokens in those nested
        // files, so the old top-level-only walk made the Today row / `tokens5h7d`
        // / burn-rate input badly under-count.
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey]
        guard let walker = fm.enumerator(
            at: projectsDir, includingPropertiesForKeys: Array(keys)
        ) else { return ClaudeScanResult(snapshot: .empty, daily: [:], cache: [:]) }

        var tokens5h = 0, tokens7d = 0, msgs5h = 0, msgs7d = 0
        var daily: [Date: [String: ModelTokenTally]] = [:]
        // #88: Claude Code splits one API response across multiple JSONL lines
        // that share a `message.id` and each repeat the SAME `usage`. Dedup by
        // id GLOBALLY across all files (resume/fork can replay an id, and a main
        // transcript can share an id with a nested subagent file) so totals
        // aren't inflated. Runs on every scan over the (possibly cached) records.
        var seenMessageIDs = Set<String>()
        var newCache: [String: ClaudeFileCache] = [:]

        for case let file as URL in walker where file.pathExtension == "jsonl" {
            // Skip files untouched within the window; the prefetched values avoid
            // an extra stat() per file. Non-regular entries never get parsed.
            guard let vals = try? file.resourceValues(forKeys: keys),
                  vals.isRegularFile == true,
                  let mtime = vals.contentModificationDate, mtime >= fileCutoff,
                  let size = vals.fileSize,
                  shouldScanTranscript(isSymbolicLink: vals.isSymbolicLink ?? false, fileSize: size)
            else { continue }
            // Resolve symlinks in the key so /var/... (temp dirs) and the
            // /private/var/... the enumerator yields hash to the same entry.
            let key = file.resolvingSymlinksInPath().path
            let records: [ClaudeMsgRecord]
            if let hit = cache[key], hit.mtime == mtime, hit.size == UInt64(size) {
                records = hit.records                       // cache hit — no re-parse
            } else {
                records = parseFileRecords(at: file)
            }
            newCache[key] = ClaudeFileCache(mtime: mtime, size: UInt64(size), records: records)

            for r in records {
                if r.ts < cutoff7d { continue }
                // #88: skip a repeated message.id (its usage was already counted);
                // records without an id are never collapsed.
                if let id = r.id, !id.isEmpty, !seenMessageIDs.insert(id).inserted { continue }
                let total = r.input + r.output + r.cacheRead + r.cacheCreate
                tokens7d += total
                msgs7d += 1
                if r.ts >= cutoff5h {
                    tokens5h += total
                    msgs5h += 1
                }
                // #84 per-local-day tally (subset of the 7d window, by local day).
                if r.ts >= dailyCutoff {
                    let day = calendar.startOfDay(for: r.ts)
                    var tally = daily[day]?[r.model] ?? ModelTokenTally()
                    tally.input += r.input; tally.output += r.output
                    tally.cacheRead += r.cacheRead; tally.cacheCreate += r.cacheCreate
                    daily[day, default: [:]][r.model] = tally
                }
            }
        }

        let snapshot = Snapshot(
            fiveHourUsedPct: nil, fiveHourResetsAt: nil,
            sevenDayUsedPct: nil, sevenDayResetsAt: nil,
            tokens5h: tokens5h, tokens7d: tokens7d,
            messages5h: msgs5h, messages7d: msgs7d
        )
        return ClaudeScanResult(snapshot: snapshot, daily: daily, cache: newCache)
    }

    /// Parse one transcript file into its assistant-message token records.
    /// No dedup / no windowing here — that runs in the fold so it stays correct
    /// against the current `now`. This (file read + JSON parse) is the hot path
    /// the `ClaudeFileCache` skips when `(mtime, size)` is unchanged.
    private nonisolated static func parseFileRecords(at url: URL) -> [ClaudeMsgRecord] {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return [] }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoNoFrac = ISO8601DateFormatter()

        var records: [ClaudeMsgRecord] = []
        for line in text.split(separator: "\n") {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }

            // Timestamp lives at the top level of each JSONL entry.
            guard let tsString = obj["timestamp"] as? String,
                  let ts = iso.date(from: tsString) ?? isoNoFrac.date(from: tsString) else {
                continue
            }
            // Only assistant messages carry usage data.
            guard (obj["type"] as? String) == "assistant",
                  let msg = obj["message"] as? [String: Any],
                  let usage = msg["usage"] as? [String: Any] else { continue }

            records.append(ClaudeMsgRecord(
                ts: ts,
                id: msg["id"] as? String,
                model: (msg["model"] as? String) ?? "unknown",
                input: Self.clampTokens((usage["input_tokens"] as? Int) ?? 0),
                output: Self.clampTokens((usage["output_tokens"] as? Int) ?? 0),
                cacheRead: Self.clampTokens((usage["cache_read_input_tokens"] as? Int) ?? 0),
                cacheCreate: Self.clampTokens((usage["cache_creation_input_tokens"] as? Int) ?? 0)))
        }
        return records
    }
}
