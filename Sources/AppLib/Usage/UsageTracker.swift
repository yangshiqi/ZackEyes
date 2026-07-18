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

        /// Codex is temporarily unavailable (limit reached / out of credits /
        /// window at 100%). Drives the "limit reached" treatment in the usage
        /// header — the bars alone can't, since a credit-gated block leaves the
        /// window `used_percent` near 0.
        public var codexLimitReached: Bool = false
        /// When the codex block is expected to lift (the 5h/7d window reset, if
        /// known). Shown as a "resets in …" countdown alongside the indicator.
        public var codexLimitResetsAt: Date? = nil

        // Fallback estimates from transcript scanning (Claude-only)
        public var tokens5h: Int
        public var tokens7d: Int
        public var messages5h: Int
        public var messages7d: Int

        // Last time we received fresh rate_limits data from any source
        public var lastUpdated: Date?

        // Modification time of the rollout that supplied the latest Codex
        // quota reading. A rescan of the same file must not refresh this.
        public var codexLastUpdated: Date? = nil

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
        // `codexLimitReached` is excluded: the block *state* is live/derived
        // (recomputed each refresh from the codex rollout), so it must never
        // restore stale across launches — a recovered account shouldn't show
        // "limit reached" until the first scan confirms.
        // `codexLimitResetsAt` IS persisted, though: codex drops the 5h/7d windows
        // (incl. resets_at) the instant it reports a block, so without persistence a
        // restart-while-blocked loses the reset entirely (the only other source is an
        // inactive, un-scanned rollout). It's safe to restore because the UI only
        // reads it while codexLimitReached (re-derived live) is true, and the apply
        // path only keeps it while it is still in the future.
        private enum CodingKeys: String, CodingKey {
            case fiveHourUsedPct, fiveHourResetsAt, sevenDayUsedPct, sevenDayResetsAt
            case codexFiveHourUsedPct, codexFiveHourResetsAt, codexSevenDayUsedPct, codexSevenDayResetsAt
            case codexLimitResetsAt
            case tokens5h, tokens7d, messages5h, messages7d, lastUpdated, codexLastUpdated
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
            codexFiveHourUsedPct != nil || codexSevenDayUsedPct != nil || codexLimitReached
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

        public func sevenDayUsedPct(for agent: AgentKind) -> Double? {
            switch agent {
            case .claude: return sevenDayUsedPct
            case .codex:  return codexSevenDayUsedPct
            }
        }

        public func displayAgent(preferred: AgentKind) -> AgentKind {
            switch preferred {
            case .claude where !hasClaudeData && hasCodexData: return .codex
            case .codex where !hasCodexData && hasClaudeData: return .claude
            default: return preferred
            }
        }
    }

    @Published public private(set) var snapshot: Snapshot = .empty

    /// User preference (#84): whether the expanded "Today" consumption row is
    /// shown. Default true; seeded from `ConfigStore` by `AppDelegate`, toggled
    /// from the gear menu. Both expanded notch headers observe this.
    @Published public var showTodayConsumption: Bool = true
    @Published public var timeProgressMode: TimeProgressMode = .off
    @Published public var progressMode: ProgressMode = .used
    @Published public var leftProgressDirection: LeftProgressDirection = .leftToRight
    @Published public var timeOverlayOpacity: Double = TimeOverlayOpacity.defaultValue

    /// Agent selected for single-agent quota surfaces, including the physical
    /// notch path. Stored by ConfigStore and updated live from either menu.
    @Published public var compactAgent: AgentKind = .claude

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

    /// #148 — Codex reports rate limits per named scope (account-level plus
    /// per-model limits like "GPT-5.3-Codex-Spark"). We remember each scope's
    /// last reading keyed by `limit_name` ("" when absent) so a fresh per-model
    /// limit at 0% can't hide a higher account limit that's no longer in the
    /// scanned tail. Expired scopes (resets_at passed) are pruned on apply.
    private var codexScopeReadings: [String: CodexRateLimitObservation] = [:]

    /// Path where we persist the last received rate_limits snapshot so the UI
    /// can show meaningful data immediately on next launch instead of "no data".
    /// Injectable for tests (the default is the real user cache).
    private let cacheURL: URL

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
        codexSessionsDir: URL? = URL(fileURLWithPath: NSHomeDirectory() + "/.codex/sessions"),
        cacheURL: URL = URL(fileURLWithPath: NSHomeDirectory() + "/.zackeyes/usage-cache.json")
    ) {
        self.projectsDir = projectsDir
        self.codexSessionsDir = codexSessionsDir
        self.cacheURL = cacheURL
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

    /// Load the last persisted rate_limits snapshot. Internal (not private)
    /// so tests can exercise the restore path against an injected cacheURL.
    func loadFromCache() {
        guard let data = try? Data(contentsOf: cacheURL),
              let cached = try? JSONDecoder().decode(Snapshot.self, from: data) else {
            return
        }
        var restored = cached
        restored.dailyUsage = []   // #84: never trust a persisted (possibly stale) "today"
        if restored.codexLastUpdated == nil,
           restored.codexFiveHourUsedPct != nil || restored.codexSevenDayUsedPct != nil {
            // Best-effort migration for caches written before the per-agent
            // timestamp existed.
            restored.codexLastUpdated = restored.lastUpdated
        }
        // #172 — a persisted block reset that has already passed must not linger.
        // The views only read it while codexLimitReached (left false on load,
        // re-derived by the first scan), but guarding here keeps the field honest
        // for any future reader and avoids a one-frame stale "resets now".
        if let reset = restored.codexLimitResetsAt, reset <= Date() {
            restored.codexLimitResetsAt = nil
        }
        // #182 — drop a 5h pair whose reset is impossibly far out (pre-fix
        // positional decode persisted the promoted 7d window on the 5h axis).
        // Must run before the scope seeding below or the "\0cached" seed
        // resurrects the bad pair via mostConstrainedCodexReading.
        if Self.codexFiveHourResetImplausible(
            resetsAt: restored.codexFiveHourResetsAt, now: Date()) {
            restored.codexFiveHourUsedPct = nil
            restored.codexFiveHourResetsAt = nil
        }
        snapshot = restored
        // #148 — seed the per-scope map from the cached codex reading so the
        // most-constrained value survives a restart (the first live scan may
        // only see a fresh per-model scope). Keyed under a synthetic name that
        // can't collide with a real `limit_name` (Codex review #149): the cached
        // value is the last *max across scopes* and may have come from a named
        // model limit, so a fresh account ("") reading must NOT overwrite it.
        // It self-expires on its own reset like any scope.
        if restored.codexFiveHourUsedPct != nil || restored.codexSevenDayUsedPct != nil {
            codexScopeReadings["\u{0}cached"] = CodexRateLimitObservation(
                fiveHourUsedPct: restored.codexFiveHourUsedPct,
                fiveHourResetsAt: restored.codexFiveHourResetsAt,
                sevenDayUsedPct: restored.codexSevenDayUsedPct,
                sevenDayResetsAt: restored.codexSevenDayResetsAt)
        }
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
        /// Codex is currently blocked: it reported a reached limit, ran out of
        /// credits, or a window is at 100%. Distinct from `usedPct` because on
        /// credit-gated plans (e.g. prolite) the window `used_percent` stays ~0
        /// while the account is out of credits — so the bars alone never reflect
        /// the block. See `decodeCodexObservation`.
        public var limitReached: Bool = false
        /// #182 — the reading carried at least one window dict. Distinguishes
        /// "codex reported window state" (authoritative for BOTH axes — a
        /// missing axis means that window doesn't exist right now, e.g. the 5h
        /// limit temporarily lifted) from a windowless credits-only block
        /// reading (retain last-known pairs, #166 semantics).
        public var hasWindowData: Bool = false
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
        let codexState = await Task.detached(priority: .utility) { () -> CodexScanState? in
            guard let codexDir else { return nil }
            return Self.scanLatestCodexState(rootDir: codexDir)
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

        // Apply when there are per-window scopes OR a block flag. The two are
        // derived from the same token_count reading so scopes is non-empty
        // whenever limitReached is true today, but the explicit `|| limitReached`
        // keeps a credits-only reading (no per-window data) surfacing the block
        // even if `tailCodexReadings` ever stops emitting an empty scope for it.
        if let codexState, !codexState.scopes.isEmpty || codexState.limitReached {
            applyCodexScopes(
                codexState.scopes,
                limitReached: codexState.limitReached,
                limitResetsAt: codexState.limitResetsAt,
                observedAt: codexState.observedAt
            )
        } else {
            // No recent rollout means Codex is idle, not that the last quota
            // reading is invalid. Retain each window until its own reset.
            expireCodexWindows(now: Date())
        }
    }

    /// #182 — a 5h-window reset can never sit further out than its own window
    /// length (+1h slack for clock skew). A persisted pair violating that was
    /// written by the pre-#182 positional decoder misclassifying the promoted
    /// 7d window; restoring it would pin the wrong 5h value for days.
    nonisolated static func codexFiveHourResetImplausible(
        resetsAt: Date?, now: Date, cap: TimeInterval = 6 * 3600
    ) -> Bool {
        guard let resetsAt else { return false }
        return resetsAt.timeIntervalSince(now) > cap
    }

    /// #166 findings A/C — once the last real Codex reading is older than the
    /// longest window (7d), nothing we still hold can be valid. Backstops the idle
    /// path so a reset-less window or a credits-only block (no reset boundary)
    /// can't pin the bar/badge forever.
    nonisolated static func codexDataFullyStale(
        lastUpdated: Date?, now: Date, cap: TimeInterval = 7 * 24 * 3600
    ) -> Bool {
        guard let last = lastUpdated else { return false }
        return now.timeIntervalSince(last) > cap
    }

    private func expireCodexWindows(now: Date) {
        var s = snapshot
        var changed = false
        // Absolute staleness backstop (#166 A/C): drop ALL codex data (windows +
        // badge) once the last reading is older than the longest window, then stop —
        // otherwise a reset-less reading would linger indefinitely (only marked
        // stale). Fires at most once: it nils codexLastUpdated, so the next tick is
        // a no-op.
        if Self.codexDataFullyStale(lastUpdated: s.codexLastUpdated, now: now) {
            s.codexFiveHourUsedPct = nil
            s.codexFiveHourResetsAt = nil
            s.codexSevenDayUsedPct = nil
            s.codexSevenDayResetsAt = nil
            s.codexFiveHourETA = nil
            s.codexLimitReached = false
            s.codexLimitResetsAt = nil
            s.codexLastUpdated = nil
            codexScopeReadings.removeAll()
            snapshot = s
            saveToCache()
            return
        }
        if let reset = s.codexFiveHourResetsAt, reset <= now {
            s.codexFiveHourUsedPct = nil
            s.codexFiveHourResetsAt = nil
            changed = true
        }
        if let reset = s.codexSevenDayResetsAt, reset <= now {
            s.codexSevenDayUsedPct = nil
            s.codexSevenDayResetsAt = nil
            changed = true
        }
        let agedETA = codexEstimator.estimate(
            now: now, currentPct: s.codexFiveHourUsedPct, resetsAt: s.codexFiveHourResetsAt)
        if s.codexFiveHourETA != agedETA {
            s.codexFiveHourETA = agedETA
            changed = true
        }
        // Clear the block only when its reset actually passed (CodeRabbit review on
        // #166): 15-min idle alone is NOT a confirmed recovery, so a still-blocked
        // credits-only account keeps its badge. The reset-less case (nil
        // codexLimitResetsAt) no longer drops here — the absolute staleness cap above
        // is its backstop, so it can't pin forever either.
        if s.codexLimitReached, let resetsAt = s.codexLimitResetsAt, resetsAt <= now {
            s.codexLimitReached = false
            s.codexLimitResetsAt = nil
            changed = true
        }
        codexScopeReadings = codexScopeReadings.filter { _, obs in
            let primaryValid = obs.fiveHourResetsAt.map { $0 > now } ?? (obs.fiveHourUsedPct != nil)
            let secondaryValid = obs.sevenDayResetsAt.map { $0 > now } ?? (obs.sevenDayUsedPct != nil)
            return primaryValid || secondaryValid
        }
        guard changed else { return }
        snapshot = s
        saveToCache()
    }

    /// Reset of the window that most likely bound a block — the one with the
    /// higher last-known used% (mirrors `scanLatestCodexState`'s blockReset). When
    /// the block reading carries no window of its own, the retained countdown must
    /// point at the axis that's actually exhausted: a 7d-window block must not
    /// surface the sooner 5h reset. Falls back to whichever reset is present.
    nonisolated static func bindingReset(
        fiveUsed: Double?, fiveReset: Date?,
        sevenUsed: Double?, sevenReset: Date?
    ) -> Date? {
        // `>=` (not `>`): when both windows are equally exhausted (e.g. both 100%),
        // the 5h reset passing doesn't unblock — the user is still 7d-blocked — so
        // the later 7d reset is the binding one (Gemini review #173).
        let preferSeven = (sevenUsed ?? -1) >= (fiveUsed ?? -1)
        return (preferSeven ? sevenReset : fiveReset) ?? fiveReset ?? sevenReset
    }

    private func applyCodexObservation(_ obs: CodexRateLimitObservation) {
        var s = snapshot
        let now = Date()
        // #166 review (Gemini): `lastUpdated` is Claude-only now that Codex has its
        // own `codexLastUpdated`; the codex path must not touch it, so a codex read
        // can't make a stale Claude reading read as freshly updated.
        s.codexLastUpdated = now
        // #182 — a reading that carries window data is authoritative for BOTH
        // axes: an axis it omits (no 5h-class window while the 5h limit is
        // lifted) no longer exists and must clear, not pin until its resets_at.
        // A windowless reading (credits-only block) leaves the last-known
        // pairs retained (#166 semantics).
        if obs.hasWindowData {
            s.codexFiveHourUsedPct = obs.fiveHourUsedPct
            s.codexFiveHourResetsAt = obs.fiveHourResetsAt
            s.codexSevenDayUsedPct = obs.sevenDayUsedPct
            s.codexSevenDayResetsAt = obs.sevenDayResetsAt
            if let v = obs.fiveHourUsedPct {
                codexEstimator.record(now, pct: v)   // #86 — same estimator, codex axis
            }
        }
        s.codexFiveHourETA = codexEstimator.estimate(
            now: now, currentPct: s.codexFiveHourUsedPct, resetsAt: s.codexFiveHourResetsAt)
        s.codexLimitReached = obs.limitReached
        if obs.limitReached {
            if let live = Self.bindingReset(
                fiveUsed: obs.fiveHourUsedPct, fiveReset: obs.fiveHourResetsAt,
                sevenUsed: obs.sevenDayUsedPct, sevenReset: obs.sevenDayResetsAt) {
                // This reading's own reset is authoritative — trust it as-is, but
                // pick the BINDING window (higher used%) so a 7d block doesn't
                // surface the sooner 5h reset (Gemini review #173).
                s.codexLimitResetsAt = live
            } else {
                // Block reading with no window (out-of-credits) → reuse the last
                // window reset we still hold. Prefer the BINDING window (higher
                // last-known used%) so a 7d-exhaustion block counts down to the 7d
                // reset, not a sooner-but-irrelevant 5h reset. Future-only: a lapsed
                // one would render as "resets now" and mislead.
                let remembered = Self.bindingReset(
                    fiveUsed: s.codexFiveHourUsedPct, fiveReset: s.codexFiveHourResetsAt,
                    sevenUsed: s.codexSevenDayUsedPct, sevenReset: s.codexSevenDayResetsAt)
                    ?? snapshot.codexLimitResetsAt
                s.codexLimitResetsAt = remembered.flatMap { $0 > now ? $0 : nil }
            }
        } else {
            s.codexLimitResetsAt = nil
        }
        snapshot = s
        saveToCache()
    }

    /// #148 — apply a scan that may carry multiple named rate-limit scopes.
    /// Merge each scope's latest reading into the remembered map, prune scopes
    /// whose windows have all reset, then display the most-constrained reading.
    private func applyCodexScopes(
        _ scanned: [String: CodexRateLimitObservation],
        limitReached: Bool = false,
        limitResetsAt: Date? = nil,
        observedAt: Date
    ) {
        let now = Date()
        for (k, v) in scanned { codexScopeReadings[k] = v }
        // #182 (review) — the "\0cached" seed only bridges restart → first
        // live account reading. Once a live account-scope reading with window
        // data lands, the seed is superseded; keeping it would let
        // mostConstrainedCodexReading resurrect an axis the fresh reading
        // authoritatively omitted (e.g. the temporarily lifted 5h window).
        // A windowless account reading (credits-only block) keeps the seed —
        // it is still the only source of the retained countdown.
        if let account = scanned[""], account.hasWindowData {
            codexScopeReadings.removeValue(forKey: "\u{0}cached")
        }
        codexScopeReadings = codexScopeReadings.filter { _, obs in
            let pAlive = obs.fiveHourResetsAt.map { $0 > now } ?? (obs.fiveHourUsedPct != nil)
            let sAlive = obs.sevenDayResetsAt.map { $0 > now } ?? (obs.sevenDayUsedPct != nil)
            return pAlive || sAlive
        }
        let best = Self.mostConstrainedCodexReading(from: codexScopeReadings, now: now)
        // Safety net: the 5h/7d % is only a trustworthy account-quota reading
        // when a LIVE account-level scope is present (empty `limit_name`). A
        // per-model scope alone — e.g. gpt-5.5 writes only "GPT-5.3-Codex-Spark"
        // at 0% while its account scope comes through null — is NOT the account
        // quota; rendering its 0% as "100% remaining" misleads (the real account
        // usage lives only in response headers codex doesn't write to the
        // rollout). With no account reading we leave 5h/7d unknown (the bar
        // hides / shows "—"); the block flag below still surfaces a reached /
        // out-of-credits state.
        //
        // The persisted cache seed ("\0cached") is deliberately NOT counted: it
        // carries no provenance (loadFromCache restores a prior DISPLAY value
        // that may have come from a per-model scope), so trusting it would let a
        // stale per-model 0% defeat the safety net on restart (codex-review P1).
        let hasAccountReading = codexScopeReadings.contains { key, obs in
            key.isEmpty && (obs.fiveHourUsedPct != nil || obs.sevenDayUsedPct != nil)
        }
        let display = hasAccountReading ? best : CodexRateLimitObservation()
        var s = snapshot
        // #166 review (Gemini): `lastUpdated` stays Claude-only — the codex path
        // records its own freshness in `codexLastUpdated` and no longer bumps the
        // shared timestamp (which would mask Claude staleness in the split header).
        s.codexLastUpdated = observedAt
        // Set directly (not the "only-if-present" merge of applyCodexObservation)
        // so a window with no live scope clears instead of pinning a stale value.
        s.codexFiveHourUsedPct = display.fiveHourUsedPct
        s.codexFiveHourResetsAt = display.fiveHourResetsAt
        s.codexSevenDayUsedPct = display.sevenDayUsedPct
        s.codexSevenDayResetsAt = display.sevenDayResetsAt
        // Only feed the estimator a genuinely new reading — recording an
        // unchanged % at a new timestamp injects flat points that distort the
        // burn-rate ETA (mirrors the #86 Claude-path guard; Gemini review).
        // `snapshot` still holds the prior value here (s is a local copy).
        if let pct = display.fiveHourUsedPct,
           pct != snapshot.codexFiveHourUsedPct
            || display.fiveHourResetsAt != snapshot.codexFiveHourResetsAt {
            codexEstimator.record(now, pct: pct)
        }
        s.codexFiveHourETA = codexEstimator.estimate(
            now: now, currentPct: s.codexFiveHourUsedPct, resetsAt: s.codexFiveHourResetsAt)
        s.codexLimitReached = limitReached
        if limitReached {
            if let live = limitResetsAt {
                // The block reading carried its own window reset — authoritative.
                s.codexLimitResetsAt = live
            } else {
                // Out-of-credits block: codex nulls primary/secondary, so `display`
                // above cleared the live window resets. Fall back to the reset we
                // already remembered, else the prior snapshot's BINDING window reset
                // (higher last-known used% — a 7d-exhaustion block must count down to
                // the 7d reset, not a sooner 5h one) so the "resets in …" countdown
                // survives the transition + a restart. Future-only: a lapsed reset
                // would show "resets now" and mislead — once it passes we honestly
                // show no countdown until codex reports fresh windows.
                let remembered = snapshot.codexLimitResetsAt
                    ?? Self.bindingReset(
                        fiveUsed: snapshot.codexFiveHourUsedPct, fiveReset: snapshot.codexFiveHourResetsAt,
                        sevenUsed: snapshot.codexSevenDayUsedPct, sevenReset: snapshot.codexSevenDayResetsAt)
                s.codexLimitResetsAt = remembered.flatMap { $0 > now ? $0 : nil }
            }
        } else {
            s.codexLimitResetsAt = nil
        }
        snapshot = s
        saveToCache()
    }

    /// #148 — surface the most-constrained (highest used%) non-expired reading
    /// across all known Codex limit scopes, per window. A scope whose window has
    /// already reset (resets_at < now) is skipped — its % is stale. Lets a
    /// per-model scope at 0% never mask a higher account-level scope.
    nonisolated static func mostConstrainedCodexReading(
        from scopes: [String: CodexRateLimitObservation], now: Date
    ) -> CodexRateLimitObservation {
        var result = CodexRateLimitObservation()
        for obs in scopes.values {
            if let pct = obs.fiveHourUsedPct,
               obs.fiveHourResetsAt.map({ $0 > now }) ?? true,
               pct > (result.fiveHourUsedPct ?? -1) {
                result.fiveHourUsedPct = pct
                result.fiveHourResetsAt = obs.fiveHourResetsAt
            }
            if let pct = obs.sevenDayUsedPct,
               obs.sevenDayResetsAt.map({ $0 > now }) ?? true,
               pct > (result.sevenDayUsedPct ?? -1) {
                result.sevenDayUsedPct = pct
                result.sevenDayResetsAt = obs.sevenDayResetsAt
            }
        }
        return result
    }

    /// Codex rollout-mtime window for "is codex actively running right now".
    /// A rollout file's mtime advances on every event_msg write, so anything
    /// older than this is taken as "the user is not currently using codex" —
    /// we hide the codex usage bar in that case so it tracks current activity
    /// instead of historical state. 15 min mirrors the codex idle prune in
    /// AppDelegate.runLivenessSweep.
    public nonisolated static let codexActiveWindowSeconds: TimeInterval = 15 * 60

    /// Walk the date-partitioned codex sessions tree and merge the tail
    /// readings of EVERY rollout active within `recentSeconds`, newest-first.
    /// Returns the latest reading per named scope (across all active rollouts)
    /// plus the overall-newest rollout's last reading. Returns `nil` if no
    /// rollout was written within the window. Bounded — only the tail of each
    /// candidate file is read.
    ///
    /// Merging across rollouts (not just the newest one) matters when several
    /// codex sessions run concurrently: a chatty per-model session reporting
    /// `GPT-…-Spark` at 0% must NOT hide the account-level 5h/7d usage that a
    /// quieter session writes to a different rollout. Reading only the newest
    /// file pinned the bars to whichever session wrote last (the 0% bug).
    private nonisolated static func firstActiveCodexReadings(
        rootDir: URL,
        recentSeconds: TimeInterval
    ) -> (scopes: [String: CodexRateLimitObservation], last: CodexRateLimitObservation, observedAt: Date)? {
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
        // Walk newest-first, merging every active rollout's scopes. When the
        // SAME scope name appears across rollouts (e.g. concurrent codex
        // sessions on different accounts both writing an unnamed "account"
        // scope — one out of credits at null, one with real 6%/27% usage), keep
        // the HIGHER non-expired used% per window rather than letting whichever
        // wrote last win. This is the "stuck at 100%" fix: a chatty 0%/null
        // session must not mask a quieter session's real usage. `last` is the
        // overall-newest rollout's final reading — used for the block flag.
        let now = Date()
        var mergedScopes: [String: CodexRateLimitObservation] = [:]
        var overallLast: CodexRateLimitObservation?
        var overallObservedAt: Date?
        for c in candidates.sorted(by: { $0.mtime > $1.mtime }) {
            guard let readings = tailCodexReadings(in: c.url) else { continue }
            if overallLast == nil {
                overallLast = readings.last
                overallObservedAt = c.mtime
            }
            for (name, obs) in readings.scopes {
                mergedScopes[name] = mergeCodexObservations(mergedScopes[name], obs, now: now)
            }
        }
        guard let last = overallLast, let observedAt = overallObservedAt else { return nil }
        return (mergedScopes, last, observedAt)
    }

    /// Combine two readings of the same scope, keeping the higher non-expired
    /// used% per window and OR-ing the block flag. Mirrors the per-axis,
    /// reset-gated max in `mostConstrainedCodexReading` so a stale pre-reset
    /// spike (resets_at already passed) can't pin the merged value.
    nonisolated static func mergeCodexObservations(
        _ existing: CodexRateLimitObservation?,
        _ incoming: CodexRateLimitObservation,
        now: Date
    ) -> CodexRateLimitObservation {
        guard var merged = existing else { return incoming }
        if let pct = incoming.fiveHourUsedPct,
           incoming.fiveHourResetsAt.map({ $0 > now }) ?? true,
           pct > (merged.fiveHourUsedPct ?? -1) {
            merged.fiveHourUsedPct = pct
            merged.fiveHourResetsAt = incoming.fiveHourResetsAt
        }
        if let pct = incoming.sevenDayUsedPct,
           incoming.sevenDayResetsAt.map({ $0 > now }) ?? true,
           pct > (merged.sevenDayUsedPct ?? -1) {
            merged.sevenDayUsedPct = pct
            merged.sevenDayResetsAt = incoming.sevenDayResetsAt
        }
        // `limitReached` is intentionally NOT merged here: the block flag is
        // derived solely from the newest reading in `scanLatestCodexState`, so
        // a merged scope's flag is never read (and OR-ing would re-introduce the
        // stale-blocked pin this design avoids). Keep the newest scope's value.
        return merged
    }

    /// Most recent single `rate_limits` reading (the overall-last token_count).
    /// Kept for callers/tests that want the raw latest, independent of scope.
    nonisolated static func scanLatestCodexRateLimits(
        rootDir: URL,
        recentSeconds: TimeInterval = codexActiveWindowSeconds
    ) -> CodexRateLimitObservation? {
        firstActiveCodexReadings(rootDir: rootDir, recentSeconds: recentSeconds)?.last
    }

    /// #148 — latest reading per limit scope from the active rollout. Named
    /// scopes use `limit_name`; unnamed non-account scopes fall back to
    /// `limit_id`, while the Codex account scope keeps the empty key. The
    /// caller picks the most-constrained across scopes so a per-model or
    /// premium limit can't hide the account quota.
    nonisolated static func scanLatestCodexScopes(
        rootDir: URL,
        recentSeconds: TimeInterval = codexActiveWindowSeconds
    ) -> [String: CodexRateLimitObservation]? {
        firstActiveCodexReadings(rootDir: rootDir, recentSeconds: recentSeconds)?.scopes
    }

    /// Sendable bundle returned to the @MainActor from the detached codex scan:
    /// the per-scope used% readings (for the bars) plus the block state derived
    /// from the single most-recent reading (for the "limit reached" indicator).
    /// `limitReached` is taken from `last`, not the scope max, so it reflects
    /// the current account state rather than pinning a stale blocked scope.
    public struct CodexScanState: Sendable {
        public var scopes: [String: CodexRateLimitObservation]
        public var limitReached: Bool
        public var limitResetsAt: Date?
        public var observedAt: Date
    }

    nonisolated static func scanLatestCodexState(
        rootDir: URL,
        recentSeconds: TimeInterval = codexActiveWindowSeconds
    ) -> CodexScanState? {
        guard let readings = firstActiveCodexReadings(rootDir: rootDir, recentSeconds: recentSeconds) else {
            return nil
        }
        // Block state + reset come from the SINGLE newest reading only — never
        // OR'd across scopes. Codex replicates the account-level credits /
        // `rate_limit_reached_type` into every reading's `rate_limits` (any
        // session's request reflects the current account state), so the newest
        // reading already catches out-of-credits regardless of which session
        // wrote it. OR-ing across active scopes instead pinned the badge to a
        // stale blocked rollout for up to the 15-min window after the user
        // recovered (codex-review P1). Newest-only clears on recovery and keeps
        // the reset matched to the reading the flag came from.
        let last = readings.last
        // Reset for the block = the reset of the window that's actually binding
        // (higher used%), so a 7d-window block counts down to the 7d reset
        // instead of always the 5h one (CodeRabbit PR review). A credits-only
        // block has no clean window reset — fall back to whichever is present.
        let blockReset = ((last.sevenDayUsedPct ?? -1) > (last.fiveHourUsedPct ?? -1)
            ? last.sevenDayResetsAt : last.fiveHourResetsAt)
            ?? last.fiveHourResetsAt ?? last.sevenDayResetsAt
        return CodexScanState(
            scopes: readings.scopes,
            limitReached: last.limitReached,
            limitResetsAt: blockReset,
            observedAt: readings.observedAt
        )
    }

    /// Tail-scan a codex rollout jsonl, collecting the latest `rate_limits`
    /// reading per named scope plus the overall-last reading. Returns `nil`
    /// when the tail has no `token_count` event.
    private nonisolated static func tailCodexReadings(
        in url: URL
    ) -> (scopes: [String: CodexRateLimitObservation], last: CodexRateLimitObservation)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let fileSize: UInt64
        do {
            fileSize = try handle.seekToEnd()
        } catch {
            return nil
        }
        // #148 — 1MB tail. token_count payloads are ~500B, but large assistant
        // messages sit between them and Codex interleaves multiple named limit
        // scopes; a wider tail makes it likelier we capture every active scope's
        // latest reading in one scan (per-scope persistence covers the rest).
        let readSize: UInt64 = 1_048_576
        let offset = fileSize > readSize ? fileSize - readSize : 0
        try? handle.seek(toOffset: offset)
        // String(decoding:as:) is lossy — it replaces malformed bytes with
        // U+FFFD instead of failing the whole decode when the 1MB offset cuts
        // mid-UTF8-char (Gemini review). The garbled partial first line then
        // just fails JSON parse and is skipped; the rest decodes correctly.
        guard let data = try? handle.readToEnd() else { return nil }
        let text = String(decoding: data, as: UTF8.self)

        var scopes: [String: CodexRateLimitObservation] = [:]
        var last: CodexRateLimitObservation? = nil
        for line in text.split(separator: "\n") {
            guard let lineData = line.data(using: .utf8) else { continue }
            guard let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }
            guard obj["type"] as? String == "event_msg" else { continue }
            guard let payload = obj["payload"] as? [String: Any] else { continue }
            guard payload["type"] as? String == "token_count" else { continue }
            guard let rl = payload["rate_limits"] as? [String: Any] else { continue }
            let name = codexScopeKey(from: rl)
            let obs = decodeCodexObservation(from: rl)
            scopes[name] = obs
            last = obs
        }
        guard let last else { return nil }
        return (scopes, last)
    }

    /// Codex 0.137 can emit an account-level `limit_id: "codex"` reading and
    /// immediately follow it with an unnamed `limit_id: "premium"` reading.
    /// The latter may have null windows. Treating both as the empty unnamed
    /// scope lets that empty premium observation erase valid 5h/7d data.
    private nonisolated static func codexScopeKey(from rateLimits: [String: Any]) -> String {
        if let name = rateLimits["limit_name"] as? String, !name.isEmpty {
            return name
        }
        if let id = rateLimits["limit_id"] as? String,
           !id.isEmpty,
           id.caseInsensitiveCompare("codex") != .orderedSame {
            return "id:\(id)"
        }
        return ""
    }

    /// Decode codex rate_limits dict into the Sendable observation struct.
    /// Base schema (verified 2026-05-03):
    ///   primary:   {used_percent, window_minutes=300,   resets_at}  → 5h
    ///   secondary: {used_percent, window_minutes=10080, resets_at}  → 7d
    /// `resets_at` is unix seconds (integer or double).
    ///
    /// #182 — position is NOT stable: with the 5h limit lifted (2026-07)
    /// codex promotes the 7d window into `primary` and nulls `secondary`.
    /// Classify each window by its own `window_minutes` (≤600 → 5h axis,
    /// ≥1440 → 7d axis); a window without `window_minutes` keeps its
    /// positional meaning (older codex builds omit the field).
    nonisolated static func decodeCodexObservation(from rl: [String: Any]) -> CodexRateLimitObservation {
        var obs = CodexRateLimitObservation()

        for (dict, positionalIsFiveHour) in [(rl["primary"], true), (rl["secondary"], false)] {
            guard let window = dict as? [String: Any] else { continue }
            obs.hasWindowData = true
            let w = Self.parseCodexWindow(window)
            let isFiveHour: Bool
            switch w.minutes {
            case .some(let m) where m <= 600:  isFiveHour = true
            case .some(let m) where m >= 1440: isFiveHour = false
            case .some:
                // Present but unrecognized length (say a 12h window): neither
                // axis — showing it under either label would mislead. Skip it;
                // hasWindowData stays true (the reading did speak about
                // windows, we just can't classify this one).
                continue
            case .none:                        isFiveHour = positionalIsFiveHour
            }
            if isFiveHour {
                obs.fiveHourUsedPct = w.used
                obs.fiveHourResetsAt = w.resets
            } else {
                obs.sevenDayUsedPct = w.used
                obs.sevenDayResetsAt = w.resets
            }
        }
        obs.limitReached = codexLimitReached(from: rl, obs: obs)
        return obs
    }

    /// Pull one window's fields out of its codex dict, tolerating Int/Double
    /// and second/millisecond `resets_at` encodings.
    nonisolated private static func parseCodexWindow(
        _ w: [String: Any]
    ) -> (used: Double?, resets: Date?, minutes: Int?) {
        var used: Double?
        if let u = w["used_percent"] as? Double {
            used = u
        } else if let u = w["used_percent"] as? Int {
            used = Double(u)
        }
        var resets: Date?
        if let r = w["resets_at"] as? Double {
            resets = Date(timeIntervalSince1970: r > 1e12 ? r / 1000 : r)
        } else if let r = w["resets_at"] as? Int {
            let secs = r > 1_000_000_000_000 ? Double(r) / 1000 : Double(r)
            resets = Date(timeIntervalSince1970: secs)
        }
        var minutes: Int?
        if let m = w["window_minutes"] as? Int {
            minutes = m
        } else if let m = w["window_minutes"] as? Double {
            minutes = Int(m)
        }
        return (used, resets, minutes)
    }

    /// Decide whether Codex is currently blocked from this `rate_limits` reading.
    /// Three independent signals (any one is enough):
    ///   1. `rate_limit_reached_type` is set — codex explicitly hit a window.
    ///   2. Out of credits — `credits.has_credits == false`, not `unlimited`, and
    ///      a parsed `balance` of 0. (On credit-gated plans the window
    ///      `used_percent` stays ~0, so this is the only signal that fires.)
    ///   3. Either window is at 100% used.
    /// Conservative on credits: a nil/blank `balance` is treated as "unknown,
    /// not blocked" so a non-credit plan never false-flags.
    nonisolated static func codexLimitReached(
        from rl: [String: Any], obs: CodexRateLimitObservation
    ) -> Bool {
        if let reached = rl["rate_limit_reached_type"] as? String, !reached.isEmpty {
            return true
        }
        if let credits = rl["credits"] as? [String: Any] {
            let hasCredits = credits["has_credits"] as? Bool ?? true
            let unlimited = credits["unlimited"] as? Bool ?? false
            let balanceZero: Bool
            switch credits["balance"] {
            case let s as String: balanceZero = (Double(s) ?? 1) <= 0
            case let d as Double:  balanceZero = d <= 0
            case let i as Int:     balanceZero = i <= 0
            default:               balanceZero = false  // null/absent → unknown
            }
            if !hasCredits && !unlimited && balanceZero { return true }
        }
        if let p = obs.fiveHourUsedPct, p >= 100 { return true }
        if let s = obs.sevenDayUsedPct, s >= 100 { return true }
        return false
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
