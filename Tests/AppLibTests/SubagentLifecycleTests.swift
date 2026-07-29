import Testing
import Foundation
@testable import AppLib
import Shared

/// #40 — Claude subagent lifecycle.
///
/// Payload shapes here are transcribed from real hook events captured off
/// Claude Code (see the PR), not guessed. Both `SubagentStart` and
/// `SubagentStop` carry `agent_id` and `agent_type`, so pairing is exact;
/// `SubagentStop` additionally carries `last_assistant_message` and
/// `agent_transcript_path`.
@MainActor
struct SubagentLifecycleTests {

    private func store(with sessionId: String = "s1") -> SessionStore {
        let s = SessionStore()
        s.handleEvent(BridgeEvent(
            bridgeEvent: "SessionStart", agent: .claude,
            sessionId: sessionId, cwd: "/tmp/proj"))
        return s
    }

    private func start(
        _ sessionId: String = "s1", id: String, type: String? = "Explore"
    ) -> BridgeEvent {
        BridgeEvent(bridgeEvent: "SubagentStart", agent: .claude,
                    sessionId: sessionId, agentId: id, agentType: type)
    }

    private func stop(
        _ sessionId: String = "s1", id: String?, type: String? = "Explore"
    ) -> BridgeEvent {
        BridgeEvent(bridgeEvent: "SubagentStop", agent: .claude,
                    sessionId: sessionId, agentId: id, agentType: type)
    }

    // MARK: - Counting

    @Test func startTracksASubagent() {
        let s = store()
        s.handleEvent(start(id: "a1", type: "Explore"))
        #expect(s.sessions["s1"]?.activeSubagents.count == 1)
        #expect(s.sessions["s1"]?.activeSubagents.first?.type == "Explore")
    }

    @Test func stopRemovesTheMatchingSubagent() {
        let s = store()
        s.handleEvent(start(id: "a1"))
        s.handleEvent(stop(id: "a1"))
        #expect(s.sessions["s1"]?.activeSubagents.isEmpty == true)
    }

    @Test func tracksSeveralConcurrentSubagents() {
        let s = store()
        s.handleEvent(start(id: "a1", type: "Explore"))
        s.handleEvent(start(id: "a2", type: "general-purpose"))
        s.handleEvent(start(id: "a3", type: "Explore"))
        #expect(s.sessions["s1"]?.activeSubagents.count == 3)
        s.handleEvent(stop(id: "a2"))
        let remaining = s.sessions["s1"]?.activeSubagents.map(\.id) ?? []
        #expect(Set(remaining) == ["a1", "a3"])
    }

    // MARK: - The parent must not be disturbed (acceptance criterion)

    /// The headline risk in the issue: a subagent finishing is not the parent
    /// finishing. If SubagentStop idled the card, every Task dispatch would
    /// make the session look done while it is still mid-turn.
    @Test func subagentStopDoesNotIdleTheParent() {
        let s = store()
        s.handleEvent(BridgeEvent(bridgeEvent: "UserPromptSubmit", agent: .claude,
                                  sessionId: "s1", userPrompt: "go"))
        s.handleEvent(start(id: "a1"))
        s.handleEvent(stop(id: "a1"))
        #expect(s.sessions["s1"]?.state == .working)
    }

    /// Nor may a subagent's completion message overwrite the parent's own
    /// last reply — the card would show a subagent's words attributed to the
    /// main agent.
    @Test func subagentStopDoesNotOverwriteParentLastMessage() {
        let s = store()
        s.sessions["s1"]?.lastAssistantMessage = "parent said this"
        var e = stop(id: "a1")
        e = BridgeEvent(bridgeEvent: "SubagentStop", agent: .claude, sessionId: "s1",
                        lastAssistantMessage: "subagent said this",
                        agentId: "a1", agentType: "Explore")
        s.handleEvent(e)
        #expect(s.sessions["s1"]?.lastAssistantMessage == "parent said this")
    }

    /// #217's rule: any hook event naming a session proves it is alive.
    @Test func subagentEventsRefreshLiveness() {
        let s = store()
        let before = Date().addingTimeInterval(-600)
        s.sessions["s1"]?.lastActiveAt = before
        s.handleEvent(start(id: "a1"))
        #expect((s.sessions["s1"]?.lastActiveAt ?? before) > before)
    }

    // MARK: - Malformed / duplicate events must not corrupt state

    @Test func duplicateStartDoesNotDoubleCount() {
        let s = store()
        s.handleEvent(start(id: "a1"))
        s.handleEvent(start(id: "a1"))
        #expect(s.sessions["s1"]?.activeSubagents.count == 1)
    }

    @Test func stopForAnUnknownIdIsANoOp() {
        let s = store()
        s.handleEvent(start(id: "a1"))
        s.handleEvent(stop(id: "does-not-exist"))
        #expect(s.sessions["s1"]?.activeSubagents.count == 1)
    }

    @Test func duplicateStopIsANoOp() {
        let s = store()
        s.handleEvent(start(id: "a1"))
        s.handleEvent(stop(id: "a1"))
        s.handleEvent(stop(id: "a1"))
        #expect(s.sessions["s1"]?.activeSubagents.isEmpty == true)
    }

    /// Without an id we cannot pair start with stop. Counting anyway would
    /// strand an entry that nothing can ever remove, so an unidentifiable
    /// subagent is not tracked at all.
    @Test func startWithoutAnAgentIdIsIgnored() {
        let s = store()
        s.handleEvent(BridgeEvent(bridgeEvent: "SubagentStart", agent: .claude,
                                  sessionId: "s1", agentId: nil, agentType: "Explore"))
        #expect(s.sessions["s1"]?.activeSubagents.isEmpty == true)
    }

    @Test func stopWithoutAnAgentIdLeavesTrackingAlone() {
        let s = store()
        s.handleEvent(start(id: "a1"))
        s.handleEvent(stop(id: nil))
        #expect(s.sessions["s1"]?.activeSubagents.count == 1)
    }

    @Test func missingAgentTypeStillTracks() {
        let s = store()
        s.handleEvent(start(id: "a1", type: nil))
        #expect(s.sessions["s1"]?.activeSubagents.count == 1)
        #expect(s.sessions["s1"]?.activeSubagents.first?.type == nil)
    }

    /// A runaway or malformed stream must not grow without bound.
    @Test func trackingIsCapped() {
        let s = store()
        for i in 0..<(SessionInfo.maxTrackedSubagents + 25) {
            s.handleEvent(start(id: "a\(i)"))
        }
        #expect(s.sessions["s1"]?.activeSubagents.count == SessionInfo.maxTrackedSubagents)
    }

    // MARK: - Leak guards

    /// If a SubagentStop is ever lost, the count would otherwise stay wrong
    /// forever. A new user turn is proof that nothing from the previous one is
    /// still worth showing.
    @Test func newUserPromptClearsStaleSubagents() {
        let s = store()
        s.handleEvent(start(id: "a1"))
        s.handleEvent(BridgeEvent(bridgeEvent: "UserPromptSubmit", agent: .claude,
                                  sessionId: "s1", userPrompt: "next"))
        #expect(s.sessions["s1"]?.activeSubagents.isEmpty == true)
    }

    @Test func sessionStartClearsStaleSubagents() {
        let s = store()
        s.handleEvent(start(id: "a1"))
        s.handleEvent(BridgeEvent(bridgeEvent: "SessionStart", agent: .claude,
                                  sessionId: "s1", cwd: "/tmp/proj"))
        #expect(s.sessions["s1"]?.activeSubagents.isEmpty == true)
    }

    /// Subagents are a Claude concept; Codex threads carry `subagentLabel`
    /// instead and must not be touched by this path.
    @Test func codexSessionsAreUnaffected() {
        let s = SessionStore()
        s.handleEvent(BridgeEvent(bridgeEvent: "SessionStart", agent: .codex,
                                  sessionId: "c1", cwd: "/tmp/proj"))
        s.handleEvent(BridgeEvent(bridgeEvent: "SubagentStart", agent: .codex,
                                  sessionId: "c1", agentId: "a1", agentType: "x"))
        #expect(s.sessions["c1"]?.activeSubagents.isEmpty == true)
    }

    // MARK: - Badge text

    @Test func badgeHiddenWithNoSubagents() {
        #expect(SubagentBadge.label(for: []) == nil)
    }

    @Test func singleSubagentShowsItsType() {
        let one = [ActiveSubagent(id: "a", type: "Explore", startedAt: Date())]
        #expect(SubagentBadge.label(for: one) == "Explore")
    }

    @Test func singleUntypedSubagentFallsBackToACount() {
        let one = [ActiveSubagent(id: "a", type: nil, startedAt: Date())]
        #expect(SubagentBadge.label(for: one) == "1 agent")
    }

    @Test func severalSubagentsShowACount() {
        let many = (0..<3).map { ActiveSubagent(id: "a\($0)", type: "Explore", startedAt: Date()) }
        #expect(SubagentBadge.label(for: many) == "3 agents")
    }

    // MARK: - Protocol decoding

    /// Decoded from a real captured SubagentStop payload, with the three
    /// `_bridge_*` keys `Bridge/main.swift` injects before it hits the socket
    /// — that composite, not the raw hook payload, is what `BridgeEvent` sees.
    @Test func decodesRealSubagentStopPayload() throws {
        let json = """
        {"_bridge_event":"SubagentStop","_bridge_agent":"claude","_bridge_ppid":38082,
         "session_id":"af47f433-cca7-4bae-8ba6-15ad0c63b9b0",
         "cwd":"/Users/ysq/Work/lab/ZackEyes",
         "permission_mode":"default",
         "agent_id":"a7c18204dd6ccd0e9",
         "agent_type":"Explore",
         "hook_event_name":"SubagentStop",
         "stop_hook_active":false,
         "agent_transcript_path":"/tmp/agent-a7c18204dd6ccd0e9.jsonl",
         "last_assistant_message":"Found it."}
        """
        let decoded = try JSONDecoder().decode(BridgeEvent.self, from: Data(json.utf8))
        #expect(decoded.agentId == "a7c18204dd6ccd0e9")
        #expect(decoded.agentType == "Explore")
    }

    /// A payload with neither field must decode, not throw — the whole event
    /// pipeline is downstream of this.
    @Test func decodesPayloadWithoutAgentFields() throws {
        let json = """
        {"_bridge_event":"Stop","_bridge_agent":"claude",
         "session_id":"s1","hook_event_name":"Stop","cwd":"/tmp"}
        """
        let decoded = try JSONDecoder().decode(BridgeEvent.self, from: Data(json.utf8))
        #expect(decoded.agentId == nil)
        #expect(decoded.agentType == nil)
    }
}
