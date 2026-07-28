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
        /// The agent process that owns this session, captured from the
        /// bridge's `getppid()`. Claude Code and Codex both run hooks through
        /// a chain that `exec`s all the way down (`sh -c` → launcher →
        /// bridge), so it collapses to a single process whose parent is the
        /// agent itself — meaning this is the agent's real PID, not a
        /// short-lived shell's.
        ///
        /// Pass `nil` unless the PID came from a hook. A session found by
        /// transcript scanning may also carry a PID, but that one is a guess
        /// (some agent process sharing its cwd), and letting a guessed
        /// sibling's exit decide this session's fate would reintroduce the
        /// eviction of live sessions in a new disguise.
        public let pid: Int?

        public init(id: String, cwd: String, lastActiveAt: Date, pid: Int? = nil) {
            self.id = id
            self.cwd = cwd
            self.lastActiveAt = lastActiveAt
            self.pid = pid
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
    /// 3. **Known PID decides, exactly** (#217). If the candidate carries a
    ///    `pid` and `livePids` is available, membership in that set is the
    ///    whole answer: present → alive, absent → dead. `livePids` holds only
    ///    PIDs that are *currently agent processes*, so a recycled PID picked
    ///    up by some unrelated program does not resurrect a dead session.
    ///    This replaces the counting heuristic for every hooked session,
    ///    which is what stopped live sessions being evicted whenever the
    ///    agent's real cwd disagreed with the one its hooks reported.
    /// 4. **Top-N per cwd** — the fallback for candidates with no PID (found
    ///    by transcript scanning rather than hooks). Within each cwd group,
    ///    sort by `lastActiveAt` desc and keep the top `cwdCounts[cwd]`
    ///    entries. Anything below that watermark is presumed dead.
    public static func computeDeadIds(
        candidates: [PruneCandidate],
        cwdCounts: [String: Int]?,
        livePids: Set<Int>? = nil,
        graceCutoff: Date
    ) -> Set<String> {
        guard let cwdCounts = cwdCounts else { return [] }

        var deadIds = Set<String>()
        var cwdFallback: [PruneCandidate] = []
        for c in candidates {
            // Rule 2 first — recent hook traffic outranks every other signal.
            guard c.lastActiveAt <= graceCutoff else { continue }
            if let pid = c.pid {
                // A PID-bearing candidate is NEVER sent to the cwd heuristic.
                // The two snapshots come from separate `ps` runs, so the PID
                // one can fail while the cwd one succeeded; falling back then
                // would re-enable the exact eviction this fix exists to stop.
                // No signal this sweep means keep it and retry next tick.
                guard let livePids else { continue }
                if !livePids.contains(pid) { deadIds.insert(c.id) }
            } else {
                cwdFallback.append(c)
            }
        }

        var grouped: [String: [PruneCandidate]] = [:]
        for c in cwdFallback {
            grouped[canonicalize(c.cwd), default: []].append(c)
        }

        for (cwd, group) in grouped {
            let liveCount = cwdCounts[cwd] ?? 0
            let sortedDesc = group.sorted { $0.lastActiveAt > $1.lastActiveAt }
            // The grace check already happened above, so everything here is
            // outside the window.
            for (idx, c) in sortedDesc.enumerated() where idx >= liveCount {
                deadIds.insert(c.id)
            }
        }
        return deadIds
    }

    private static func canonicalize(_ path: String) -> String {
        TerminalLocator.canonicalize(path)
    }
}
