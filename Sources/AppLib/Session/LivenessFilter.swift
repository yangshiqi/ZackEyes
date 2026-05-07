import Foundation

/// Pure functions that decide which Claude Code sessions are alive based on
/// a snapshot of running `claude` process cwds. Extracted out of `AppDelegate`
/// so the heuristic logic is unit-testable in isolation from subprocess and
/// `@MainActor` glue.
///
/// **Heuristic limitation**: when multiple `claude` processes share a cwd we
/// cannot directly map session_id ↔ PID via `ps`/`lsof` alone. We fall back
/// to "the N most-recently-touched jsonls in this cwd are the live ones",
/// where N is the live PID count. This fails in one specific scenario: an
/// older session in the same cwd that's been touched more recently than a
/// currently-idle live session — we'd import the dead one and drop the live
/// one. There is no general fix without a per-session filesystem marker
/// emitted by Claude Code itself; this is a known gap, not a bug.
public enum LivenessFilter {

    /// Filter scanner output to sessions whose cwd has at least one running
    /// `claude` process. For cwds with multiple live claudes, keep the N
    /// most-recently-modified jsonls. Sessions with `cwd == nil` are dropped
    /// (no signal to match against).
    ///
    /// `cwdCounts` is the running-`claude` snapshot (Claude path).
    /// `codexCwdCounts` is the running-`codex` snapshot. When `nil`, codex
    /// sessions pass through unchanged — the legacy "we don't know if codex
    /// is alive" semantics. When non-nil (even empty), codex sessions are
    /// filtered the same way Claude is: only kept if their cwd appears in
    /// the snapshot.
    public static func filterLiveDetected(
        _ detected: [SessionScanner.DetectedSession],
        cwdCounts: [String: Int],
        codexCwdCounts: [String: Int]? = nil
    ) -> [SessionScanner.DetectedSession] {
        let codex = detected.filter { $0.agent == .codex }
        let claude = detected.filter { $0.agent == .claude }

        let liveClaude = filterByCwd(claude, cwdCounts: cwdCounts)
        let liveCodex: [SessionScanner.DetectedSession]
        if let codexCwdCounts = codexCwdCounts {
            liveCodex = filterByCwd(codex, cwdCounts: codexCwdCounts)
        } else {
            liveCodex = codex
        }
        return liveClaude + liveCodex
    }

    /// Per-agent cwd-grouped filter. Drops sessions with no cwd (no signal
    /// to match against) and keeps the N most-recently-modified jsonls per
    /// cwd where N is the live process count for that cwd.
    private static func filterByCwd(
        _ sessions: [SessionScanner.DetectedSession],
        cwdCounts: [String: Int]
    ) -> [SessionScanner.DetectedSession] {
        var grouped: [String: [SessionScanner.DetectedSession]] = [:]
        for d in sessions {
            guard let cwd = d.cwd else { continue }
            grouped[canonicalize(cwd), default: []].append(d)
        }
        var live: [SessionScanner.DetectedSession] = []
        for (cwd, group) in grouped {
            let liveCount = cwdCounts[cwd] ?? 0
            guard liveCount > 0 else { continue }
            let sortedDesc = group.sorted { $0.lastModified > $1.lastModified }
            live.append(contentsOf: sortedDesc.prefix(liveCount))
        }
        return live
    }

    /// One row of input to `computeDeadIds` — what we know about an
    /// in-store session at sweep time, in a Sendable form so the
    /// AppDelegate can compute the snapshot on the main actor and
    /// hand it off to a background queue for the actual decision.
    public struct PruneCandidate: Sendable {
        public let id: String
        public let cwd: String
        public let lastActiveAt: Date

        public init(id: String, cwd: String, lastActiveAt: Date) {
            self.id = id
            self.cwd = cwd
            self.lastActiveAt = lastActiveAt
        }
    }

    /// Decide which sessions to evict.
    ///
    /// Rules, applied in order:
    ///
    /// 1. **Snapshot failure → no eviction.** If `cwdCounts` is `nil`, the
    ///    `ps`/`lsof` snapshot failed (transient subprocess error, missing
    ///    entitlement, etc.). Evict nothing rather than risk wiping the
    ///    panel; the next sweep will retry. An *empty but non-nil* dict
    ///    is treated as legitimate "no claudes running" — every candidate
    ///    is eligible for eviction (subject to the grace period).
    /// 2. **Recent activity grace period** — sessions whose `lastActiveAt`
    ///    is newer than `graceCutoff` are kept regardless of cwd matching.
    ///    Hooks firing this minute is irrefutable proof of life and
    ///    overrides any cwd disagreement (symlink edge cases, subdirectory
    ///    mismatches, transient cwd drift).
    /// 3. **Top-N per cwd** — within each cwd group, sort by `lastActiveAt`
    ///    desc and keep the top `cwdCounts[cwd]` entries. Anything below
    ///    that watermark is presumed dead and evicted.
    public static func computeDeadIds(
        candidates: [PruneCandidate],
        cwdCounts: [String: Int]?,
        graceCutoff: Date
    ) -> Set<String> {
        guard let cwdCounts = cwdCounts else { return [] }

        var grouped: [String: [PruneCandidate]] = [:]
        for c in candidates {
            grouped[canonicalize(c.cwd), default: []].append(c)
        }

        var deadIds = Set<String>()
        for (cwd, group) in grouped {
            let liveCount = cwdCounts[cwd] ?? 0
            let sortedDesc = group.sorted { $0.lastActiveAt > $1.lastActiveAt }
            for (idx, c) in sortedDesc.enumerated() where idx >= liveCount {
                if c.lastActiveAt > graceCutoff { continue }   // recent hooks = trusted alive
                deadIds.insert(c.id)
            }
        }
        return deadIds
    }

    private static func canonicalize(_ path: String) -> String {
        TerminalLocator.canonicalize(path)
    }
}
