import Testing
import Foundation
@testable import AppLib
import Shared

/// #37 — make context compaction visible on the session card.
///
/// The issue predates #181/#186, which already wired PreCompact/PostCompact
/// into SessionStore and the chime. What was still missing is the part the
/// issue's acceptance criteria are actually about: compaction being
/// distinguishable from an idle or stalled session on screen.
@MainActor
struct CompactLifecycleUITests {

    private func store() -> SessionStore {
        let s = SessionStore()
        s.handleEvent(BridgeEvent(bridgeEvent: "SessionStart", agent: .claude,
                                  sessionId: "s1", cwd: "/tmp/proj"))
        return s
    }

    private func pre(_ trigger: String?) -> BridgeEvent {
        BridgeEvent(bridgeEvent: "PreCompact", agent: .claude,
                    sessionId: "s1", trigger: trigger)
    }

    private func post(_ trigger: String?) -> BridgeEvent {
        BridgeEvent(bridgeEvent: "PostCompact", agent: .claude,
                    sessionId: "s1", trigger: trigger)
    }

    // MARK: - In-flight state

    @Test func preCompactMarksTheSessionCompacting() {
        let s = store()
        s.handleEvent(pre("manual"))
        #expect(s.sessions["s1"]?.isCompacting == true)
        #expect(s.sessions["s1"]?.compactTrigger == "manual")
    }

    @Test func aFreshSessionIsNotCompacting() {
        #expect(store().sessions["s1"]?.isCompacting == false)
    }

    @Test func postCompactEndsTheInFlightState() {
        let s = store()
        s.handleEvent(pre("manual"))
        s.handleEvent(post("manual"))
        #expect(s.sessions["s1"]?.isCompacting == false)
    }

    // MARK: - Counting

    @Test func postCompactCountsACompaction() {
        let s = store()
        s.handleEvent(pre("manual"))
        s.handleEvent(post("manual"))
        #expect(s.sessions["s1"]?.compactCount == 1)
        #expect(s.sessions["s1"]?.lastCompactedAt != nil)
    }

    @Test func repeatedCompactionsAccumulate() {
        let s = store()
        for _ in 0..<3 {
            s.handleEvent(pre("auto"))
            s.handleEvent(post("auto"))
        }
        #expect(s.sessions["s1"]?.compactCount == 3)
    }

    /// Interactive Claude Code never fires PostCompact (upstream
    /// anthropics/claude-code#78760), so #186 infers the finish and calls
    /// `clearCompactMarker`. That path must count too, or the tally would
    /// depend on which mode the user happened to be in.
    @Test func inferredFinishCountsTheSameAsPostCompact() {
        let s = store()
        s.handleEvent(pre("manual"))
        s.clearCompactMarker(sessionId: "s1")
        #expect(s.sessions["s1"]?.compactCount == 1)
        #expect(s.sessions["s1"]?.isCompacting == false)
    }

    /// The count survives turn boundaries — it describes the session, not the
    /// turn. `compactTrigger` deliberately does not (#181).
    @Test func countSurvivesTurnBoundaries() {
        let s = store()
        s.handleEvent(pre("manual"))
        s.handleEvent(post("manual"))
        s.handleEvent(BridgeEvent(bridgeEvent: "UserPromptSubmit", agent: .claude,
                                  sessionId: "s1", userPrompt: "next"))
        s.handleEvent(BridgeEvent(bridgeEvent: "Stop", agent: .claude, sessionId: "s1"))
        #expect(s.sessions["s1"]?.compactCount == 1)
    }

    /// Every real compaction is followed by `SessionStart(source:"compact")`,
    /// which rebuilds SessionInfo. An earlier revision preserved only the
    /// trigger/baseline/state, so the tally this feature exists to show was
    /// wiped by the very event that follows a compaction — `×2` could never
    /// appear, and `×1` vanished whenever SessionStart arrived after
    /// PostCompact. Review finding F1.
    @Test func compactTallySurvivesTheCompactRestart() {
        let s = store()
        s.handleEvent(pre("manual"))
        s.handleEvent(post("manual"))
        #expect(s.sessions["s1"]?.compactCount == 1)

        s.handleEvent(BridgeEvent(bridgeEvent: "SessionStart", agent: .claude,
                                  sessionId: "s1", cwd: "/tmp/proj", source: "compact"))
        #expect(s.sessions["s1"]?.compactCount == 1)
        #expect(s.sessions["s1"]?.lastCompactedAt != nil)

        // A second compaction then genuinely reads ×2.
        s.handleEvent(pre("auto"))
        s.handleEvent(post("auto"))
        #expect(s.sessions["s1"]?.compactCount == 2)
    }

    /// A non-compact SessionStart is a real restart and still resets.
    @Test func ordinarySessionStartResetsTheTally() {
        let s = store()
        s.handleEvent(pre("manual"))
        s.handleEvent(post("manual"))
        s.handleEvent(BridgeEvent(bridgeEvent: "SessionStart", agent: .claude,
                                  sessionId: "s1", cwd: "/tmp/proj", source: "startup"))
        #expect(s.sessions["s1"]?.compactCount == 0)
    }

    // MARK: - Marker expiry

    @Test func markerShowsRightAfterCompacting() {
        var session = SessionInfo(id: "s", cwd: "/tmp")
        session.lastCompactedAt = Date()
        #expect(session.recentlyCompacted() == true)
    }

    @Test func markerExpires() {
        var session = SessionInfo(id: "s", cwd: "/tmp")
        let now = Date()
        session.lastCompactedAt = now.addingTimeInterval(-61)
        #expect(session.recentlyCompacted(now: now) == false)
    }

    @Test func neverCompactedShowsNoMarker() {
        let session = SessionInfo(id: "s", cwd: "/tmp")
        #expect(session.recentlyCompacted() == false)
    }

    // MARK: - Wording

    @Test func tooltipDescribesTheRunningCompaction() {
        var session = SessionInfo(id: "s", cwd: "/tmp")
        session.compactTrigger = "manual"
        let text = NotchExpandedView.compactTooltip(session)
        #expect(text.contains("Compacting"))
        #expect(text.contains("manual"))
    }

    @Test func tooltipCountsFinishedCompactions() {
        var session = SessionInfo(id: "s", cwd: "/tmp")
        session.compactCount = 1
        session.lastCompactedAt = Date()
        #expect(NotchExpandedView.compactTooltip(session).contains("once"))
        session.compactCount = 4
        #expect(NotchExpandedView.compactTooltip(session).contains("4 times"))
    }

    // MARK: - Acceptance criteria

    /// "Unknown/missing payload fields do not break event handling."
    @Test func missingTriggerIsHandled() {
        let s = store()
        s.handleEvent(pre(nil))
        #expect(s.sessions["s1"]?.isCompacting == false || s.sessions["s1"]?.compactTrigger == nil)
        s.handleEvent(post(nil))
        #expect(s.sessions["s1"]?.compactCount == 1)
    }

    /// "Compact events remain observation-only for permission flow."
    @Test func compactionDoesNotTouchPendingPermissions() {
        let s = store()
        s.sessions["s1"]?.pendingPermissions = [PendingPermission(
            toolName: "Read", toolInput: [:], cwd: "/tmp", responder: { _ in })]
        s.handleEvent(pre("auto"))
        #expect(s.sessions["s1"]?.pendingPermissions.count == 1)
    }

    /// A PostCompact for a session we never saw mints one, deliberately, at
    /// `.idle` — the app may have restarted mid-compaction, and #181 chose
    /// `.idle` because a manual compaction has no Stop to follow it, so
    /// `.working` would stick forever. The counter must ride along with that
    /// rather than be skipped or double-counted.
    @Test func postCompactForAnUnknownSessionMintsAnIdleOne() {
        let s = SessionStore()
        s.handleEvent(post("manual"))
        let session = s.sessions["s1"]
        #expect(session?.state == .idle)
        #expect(session?.compactCount == 1)
        #expect(session?.isCompacting == false)
    }
}
