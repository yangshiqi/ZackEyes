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

    /// `cwdCounts` only describes running `claude` processes. A Codex
    /// session in a cwd with no claude must still come through, otherwise
    /// the user's already-running Codex would never appear in the notch.
    @Test func filterPassesCodexThroughEvenWithNoClaudeInCwd() {
        let now = Date()
        let detected = [
            mkDetected("claude-a", cwd: "/foo", mtime: now, agent: .claude),
            mkDetected("codex-b",  cwd: "/bar", mtime: now, agent: .codex),
            mkDetected("codex-c",  cwd: nil,    mtime: now, agent: .codex),
        ]
        // Only /foo has a running claude; /bar has no claude (and Codex
        // wouldn't appear in this snapshot at all).
        let result = LivenessFilter.filterLiveDetected(
            detected, cwdCounts: ["/foo": 1]
        )
        let ids = Set(result.map(\.id))
        // Codex sessions all pass through, including the one without a cwd.
        #expect(ids == ["claude-a", "codex-b", "codex-c"])
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
            messageCount: 0,
            transcriptPath: "/tmp/\(id).jsonl"
        )
    }
}
