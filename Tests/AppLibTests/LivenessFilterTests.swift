import Testing
import Foundation
@testable import AppLib
import Shared

struct LivenessFilterTests {

    // MARK: - filterLiveDetected

    @Test func filterEmptyWhenNoLiveProcesses() {
        let detected = [
            mkDetected("a", cwd: "/foo", mtime: Date()),
            mkDetected("b", cwd: "/bar", mtime: Date()),
        ]
        let result = LivenessFilter.filterLiveDetected(detected, cwdCounts: [:])
        #expect(result.isEmpty)
    }

    @Test func filterDropsCandidatesWithoutCwd() {
        let detected = [
            mkDetected("a", cwd: nil, mtime: Date()),
            mkDetected("b", cwd: "/foo", mtime: Date()),
        ]
        let result = LivenessFilter.filterLiveDetected(
            detected, cwdCounts: ["/foo": 1]
        )
        #expect(result.map(\.id) == ["b"])
    }

    @Test func filterTakesTopNByMtimePerCwd() {
        let now = Date()
        let detected = [
            mkDetected("oldest",  cwd: "/foo", mtime: now.addingTimeInterval(-3600)),
            mkDetected("middle",  cwd: "/foo", mtime: now.addingTimeInterval(-1800)),
            mkDetected("newest",  cwd: "/foo", mtime: now),
        ]
        let result = LivenessFilter.filterLiveDetected(
            detected, cwdCounts: ["/foo": 2]
        )
        let ids = Set(result.map(\.id))
        #expect(ids == ["newest", "middle"])
    }

    @Test func filterHandlesMultipleCwdsIndependently() {
        let now = Date()
        let detected = [
            mkDetected("a", cwd: "/foo", mtime: now),
            mkDetected("b", cwd: "/foo", mtime: now.addingTimeInterval(-60)),
            mkDetected("c", cwd: "/bar", mtime: now),
        ]
        let result = LivenessFilter.filterLiveDetected(
            detected, cwdCounts: ["/foo": 1, "/bar": 1]
        )
        let ids = Set(result.map(\.id))
        #expect(ids == ["a", "c"])
    }

    @Test func filterCanonicalizesTrailingSlash() {
        let detected = [mkDetected("a", cwd: "/foo/", mtime: Date())]
        // counts dict has the unsuffixed form — they must still match
        let result = LivenessFilter.filterLiveDetected(
            detected, cwdCounts: ["/foo": 1]
        )
        #expect(result.map(\.id) == ["a"])
    }

    /// When `codexCwdCounts` is omitted (legacy callers, or a `ps` failure
    /// for the codex snapshot specifically), codex sessions still pass
    /// through unchanged so already-running Codex doesn't disappear.
    @Test func filterPassesCodexThroughWhenCodexSnapshotMissing() {
        let now = Date()
        let detected = [
            mkDetected("claude-a", cwd: "/foo", mtime: now, agent: .claude),
            mkDetected("codex-b",  cwd: "/bar", mtime: now, agent: .codex),
            mkDetected("codex-c",  cwd: nil,    mtime: now, agent: .codex),
        ]
        let result = LivenessFilter.filterLiveDetected(
            detected, cwdCounts: ["/foo": 1]
            // codexCwdCounts: nil (default) → codex passes through
        )
        let ids = Set(result.map(\.id))
        #expect(ids == ["claude-a", "codex-b", "codex-c"])
    }

    /// When `codexCwdCounts` is present, codex sessions are filtered the
    /// same way Claude is — only kept if a codex process is running in
    /// the same cwd. This is the path that drops stale codex cards on
    /// app launch when the codex TUI has already exited.
    @Test func filterFiltersCodexByCwdWhenSnapshotProvided() {
        let now = Date()
        let detected = [
            mkDetected("claude-a", cwd: "/foo", mtime: now, agent: .claude),
            mkDetected("codex-live",  cwd: "/bar", mtime: now, agent: .codex),
            mkDetected("codex-dead",  cwd: "/qux", mtime: now, agent: .codex),
            mkDetected("codex-no-cwd", cwd: nil, mtime: now, agent: .codex),
        ]
        let result = LivenessFilter.filterLiveDetected(
            detected,
            cwdCounts: ["/foo": 1],
            codexCwdCounts: ["/bar": 1]
        )
        let ids = Set(result.map(\.id))
        // codex-dead's cwd has no running codex → dropped.
        // codex-no-cwd has no cwd to match → dropped.
        #expect(ids == ["claude-a", "codex-live"])
    }

    /// Empty (but non-nil) codex snapshot = `ps` succeeded with zero codex
    /// processes. Every codex session must be evicted at import time.
    @Test func filterEvictsAllCodexWhenNoCodexProcessesRunning() {
        let now = Date()
        let detected = [
            mkDetected("codex-a", cwd: "/bar", mtime: now, agent: .codex),
            mkDetected("codex-b", cwd: "/qux", mtime: now, agent: .codex),
        ]
        let result = LivenessFilter.filterLiveDetected(
            detected,
            cwdCounts: [:],
            codexCwdCounts: [:]
        )
        #expect(result.isEmpty)
    }

    // MARK: - computeDeadIds

    @Test func computeDeadIdsBailsWhenSnapshotFailed() {
        let candidates = [
            LivenessFilter.PruneCandidate(
                id: "a", cwd: "/foo", lastActiveAt: Date.distantPast
            )
        ]
        // nil cwdCounts = ps/lsof outright failure → never wipe; sweep will retry
        let dead = LivenessFilter.computeDeadIds(
            candidates: candidates, cwdCounts: nil, graceCutoff: Date()
        )
        #expect(dead.isEmpty)
    }

    @Test func computeDeadIdsEvictsAllWhenNoClaudesRunning() {
        // Empty (but non-nil) counts = ps succeeded with zero claude processes,
        // e.g. user closed all their terminals. Everything past the grace
        // window must be evicted, otherwise tombstones live forever.
        let now = Date()
        let candidates = [
            LivenessFilter.PruneCandidate(id: "a", cwd: "/foo", lastActiveAt: now.addingTimeInterval(-300)),
            LivenessFilter.PruneCandidate(id: "b", cwd: "/bar", lastActiveAt: now.addingTimeInterval(-300)),
        ]
        let dead = LivenessFilter.computeDeadIds(
            candidates: candidates,
            cwdCounts: [:],
            graceCutoff: now.addingTimeInterval(-90)
        )
        #expect(dead == ["a", "b"])
    }

    @Test func computeDeadIdsKeepsRecentlyActiveSessionsEvenOnCwdMiss() {
        let now = Date()
        let candidates = [
            LivenessFilter.PruneCandidate(
                id: "fresh", cwd: "/foo/bar", lastActiveAt: now.addingTimeInterval(-10)
            )
        ]
        // /foo/bar isn't in counts (e.g. process is at /foo, jsonl at /foo/bar)
        let dead = LivenessFilter.computeDeadIds(
            candidates: candidates,
            cwdCounts: ["/foo": 1],
            graceCutoff: now.addingTimeInterval(-90)
        )
        // 10s ago is well within the 90s grace
        #expect(dead.isEmpty)
    }

    @Test func computeDeadIdsEvictsStaleBelowTopN() {
        let now = Date()
        let oldEnough = now.addingTimeInterval(-300)   // outside grace
        let candidates = [
            LivenessFilter.PruneCandidate(id: "alive", cwd: "/foo", lastActiveAt: oldEnough),
            LivenessFilter.PruneCandidate(id: "dead",  cwd: "/foo", lastActiveAt: oldEnough.addingTimeInterval(-60)),
        ]
        let dead = LivenessFilter.computeDeadIds(
            candidates: candidates,
            cwdCounts: ["/foo": 1],
            graceCutoff: now.addingTimeInterval(-90)
        )
        #expect(dead == ["dead"])
    }

    @Test func computeDeadIdsEvictsAllForVanishedCwd() {
        let now = Date()
        let candidates = [
            LivenessFilter.PruneCandidate(
                id: "ghost", cwd: "/gone", lastActiveAt: now.addingTimeInterval(-300)
            )
        ]
        // Some other cwd has a live claude — counts is non-empty so we don't short-circuit
        let dead = LivenessFilter.computeDeadIds(
            candidates: candidates,
            cwdCounts: ["/elsewhere": 1],
            graceCutoff: now.addingTimeInterval(-90)
        )
        #expect(dead == ["ghost"])
    }

    // MARK: - Helpers

    private func mkDetected(
        _ id: String, cwd: String?, mtime: Date,
        agent: AgentKind = .claude
    ) -> SessionScanner.DetectedSession {
        SessionScanner.DetectedSession(
            id: id,
            agent: agent,
            cwd: cwd,
            lastModified: mtime,
            lastUserPrompt: nil,
            lastAssistantMessage: nil,
            messageCount: 0,
            transcriptPath: "/tmp/\(id).jsonl"
        )
    }
}

// MARK: - PID-based liveness (#217)

/// The bug these cover: a session's cwd as reported by its hooks and the cwd
/// its process actually holds can disagree (worktrees, a directory deleted
/// under a running agent, a `cd` mid-session). The counting heuristic then
/// judged a perfectly live session dead as soon as it went 90s without a
/// hook — which is just the user reading output or typing.
struct LivenessPidTests {

    private let now = Date()
    private var graceCutoff: Date { now.addingTimeInterval(-90) }
    private var stale: Date { now.addingTimeInterval(-300) }

    @Test func aSessionWhoseAgentIsStillRunningSurvivesACwdWithNoProcesses() {
        let dead = LivenessFilter.computeDeadIds(
            candidates: [
                LivenessFilter.PruneCandidate(
                    id: "live", cwd: "/deleted/worktree", lastActiveAt: stale, pid: 4242)
            ],
            cwdCounts: [:],          // no process claims that cwd — the old death sentence
            livePids: [4242],        // but the agent is demonstrably running
            graceCutoff: graceCutoff
        )
        #expect(dead.isEmpty)
    }

    @Test func aSessionWhoseAgentExitedIsEvictedEvenIfItsCwdLooksBusy() {
        let dead = LivenessFilter.computeDeadIds(
            candidates: [
                LivenessFilter.PruneCandidate(
                    id: "gone", cwd: "/repo", lastActiveAt: stale, pid: 111)
            ],
            cwdCounts: ["/repo": 5],   // plenty of processes, none of them ours
            livePids: [222, 333],
            graceCutoff: graceCutoff
        )
        #expect(dead == ["gone"])
    }

    /// Sessions found by transcript scanning never ran a hook, so they have
    /// no PID and must keep the old behaviour.
    @Test func candidatesWithoutAPidStillUseTheCwdHeuristic() {
        let dead = LivenessFilter.computeDeadIds(
            candidates: [
                LivenessFilter.PruneCandidate(id: "newer", cwd: "/repo", lastActiveAt: stale),
                LivenessFilter.PruneCandidate(
                    id: "older", cwd: "/repo", lastActiveAt: now.addingTimeInterval(-600))
            ],
            cwdCounts: ["/repo": 1],   // room for exactly one
            livePids: [999],
            graceCutoff: graceCutoff
        )
        #expect(dead == ["older"])
    }

    /// The PID and cwd snapshots are separate `ps` runs, so the PID one can
    /// fail while the cwd one succeeded. A PID-bearing session must then be
    /// KEPT, not quietly handed back to the heuristic that caused #217 — note
    /// the cwd map here is empty, so a fallback would evict it.
    @Test func aFailedPidSnapshotKeepsTheSessionInsteadOfFallingBackToCwd() {
        let dead = LivenessFilter.computeDeadIds(
            candidates: [
                LivenessFilter.PruneCandidate(
                    id: "s", cwd: "/repo", lastActiveAt: stale, pid: 111)
            ],
            cwdCounts: [:],
            livePids: nil,
            graceCutoff: graceCutoff
        )
        #expect(dead.isEmpty)
    }

    /// A hook that fired seconds ago outranks everything, including a PID we
    /// can no longer find — the agent may have exited right after it.
    @Test func recentHookTrafficOutranksAMissingPid() {
        let dead = LivenessFilter.computeDeadIds(
            candidates: [
                LivenessFilter.PruneCandidate(
                    id: "s", cwd: "/repo", lastActiveAt: now, pid: 111)
            ],
            cwdCounts: [:],
            livePids: [],
            graceCutoff: graceCutoff
        )
        #expect(dead.isEmpty)
    }

    /// Mixed fleets are the normal case; each candidate must be judged by the
    /// signal it actually has.
    @Test func pidAndCwdCandidatesAreJudgedIndependently() {
        let dead = LivenessFilter.computeDeadIds(
            candidates: [
                LivenessFilter.PruneCandidate(
                    id: "hooked-live", cwd: "/repo", lastActiveAt: stale, pid: 1),
                LivenessFilter.PruneCandidate(
                    id: "hooked-dead", cwd: "/repo", lastActiveAt: stale, pid: 2),
                LivenessFilter.PruneCandidate(id: "scanned", cwd: "/repo", lastActiveAt: stale)
            ],
            cwdCounts: [:],   // nothing matches by cwd, so the scanned one dies
            livePids: [1],
            graceCutoff: graceCutoff
        )
        #expect(dead == ["hooked-dead", "scanned"])
    }
}
