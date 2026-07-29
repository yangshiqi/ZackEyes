import Testing
import Foundation
@testable import AppLib
import Shared

/// #76 — per-session LISTEN port badge.
///
/// The syscall layer is covered by `ProcessTreeInspectorTests`. What is at
/// risk here is *attribution*: pointing a port scan at the wrong root pid
/// would print another session's dev server on this session's card.
@MainActor
struct SessionPortsTests {

    private func session(
        _ id: String,
        pid: Int?,
        fromHook: Bool,
        agent: AgentKind = .claude
    ) -> SessionInfo {
        var s = SessionInfo(id: id, cwd: "/tmp/\(id)", agent: agent)
        s.claudePid = pid
        s.claudePidFromHook = fromHook
        return s
    }

    // MARK: - Which sessions may be scanned (invariant #7)

    @Test func hookSuppliedPidsAreScanned() {
        let roots = SessionStore.portScanRoots([session("a", pid: 4242, fromHook: true)])
        #expect(roots == ["a": 4242])
    }

    /// `activateDetectedSessions` guesses a pid by picking *some* agent
    /// process sharing the cwd. That guess is good enough to jump a terminal
    /// but not to own a port: scanning a guessed sibling's subtree would
    /// attribute its dev server to this card. Same reasoning as #217, where
    /// trusting the guess for liveness evicted live sessions.
    @Test func guessedPidsAreNotScanned() {
        let roots = SessionStore.portScanRoots([session("a", pid: 4242, fromHook: false)])
        #expect(roots.isEmpty)
    }

    @Test func sessionsWithoutAPidAreNotScanned() {
        let roots = SessionStore.portScanRoots([session("a", pid: nil, fromHook: true)])
        #expect(roots.isEmpty)
    }

    @Test func nonPositivePidsAreRejected() {
        // A zero/negative pid would make the tree walk meaningless — pid 0 is
        // the kernel and would drag in unrelated subtrees.
        #expect(SessionStore.portScanRoots([session("a", pid: 0, fromHook: true)]).isEmpty)
        #expect(SessionStore.portScanRoots([session("b", pid: -1, fromHook: true)]).isEmpty)
    }

    @Test func scansBothAgents() {
        let roots = SessionStore.portScanRoots([
            session("claude", pid: 10, fromHook: true, agent: .claude),
            session("codex", pid: 20, fromHook: true, agent: .codex),
        ])
        #expect(roots == ["claude": 10, "codex": 20])
    }

    @Test func mixedSetKeepsOnlyTheTrustworthyRoots() {
        let roots = SessionStore.portScanRoots([
            session("trusted", pid: 10, fromHook: true),
            session("guessed", pid: 20, fromHook: false),
            session("pidless", pid: nil, fromHook: true),
        ])
        #expect(roots == ["trusted": 10])
    }

    // MARK: - Applying results

    @Test func applyStoresPortsOnTheMatchingSession() {
        let store = SessionStore()
        store.sessions["a"] = session("a", pid: 1, fromHook: true)
        store.applyListeningPorts(["a": [3000, 5173]])
        #expect(store.sessions["a"]?.listeningPorts == [3000, 5173])
    }

    /// A dev server the user stopped must clear the badge, not linger.
    @Test func applyClearsPortsThatWentAway() {
        let store = SessionStore()
        var s = session("a", pid: 1, fromHook: true)
        s.listeningPorts = [3000]
        store.sessions["a"] = s
        store.applyListeningPorts(["a": []])
        #expect(store.sessions["a"]?.listeningPorts.isEmpty == true)
    }

    /// A session absent from the scan result was not scanned this tick (no
    /// trustworthy pid). Leaving its stale ports on screen would be a lie, so
    /// the apply clears every session it did not measure.
    @Test func applyClearsSessionsMissingFromTheResult() {
        let store = SessionStore()
        var s = session("a", pid: 1, fromHook: true)
        s.listeningPorts = [3000]
        store.sessions["a"] = s
        store.applyListeningPorts([:])
        #expect(store.sessions["a"]?.listeningPorts.isEmpty == true)
    }

    @Test func applyIgnoresUnknownSessionIds() {
        let store = SessionStore()
        store.sessions["a"] = session("a", pid: 1, fromHook: true)
        store.applyListeningPorts(["ghost": [3000]])
        #expect(store.sessions["a"]?.listeningPorts.isEmpty == true)
        #expect(store.sessions["ghost"] == nil)
    }

    // MARK: - Badge text

    @Test func badgeIsHiddenWithoutPorts() {
        #expect(PortBadge.label(for: []) == nil)
    }

    @Test func badgeShowsASinglePort() {
        #expect(PortBadge.label(for: [3000]) == ":3000")
    }

    /// Cards are narrow; a session running vite + api + db must not push the
    /// project name off the row.
    @Test func badgeSummarisesMultiplePorts() {
        #expect(PortBadge.label(for: [3000, 5173]) == ":3000 +1")
        #expect(PortBadge.label(for: [3000, 5173, 8080]) == ":3000 +2")
    }

    @Test func badgeShowsTheLowestPortFirst() {
        // Lowest is the stable, recognisable one (`:3000`, not an ephemeral
        // helper port the framework happened to open).
        #expect(PortBadge.label(for: [61174, 3000]) == ":3000 +1")
    }
}
