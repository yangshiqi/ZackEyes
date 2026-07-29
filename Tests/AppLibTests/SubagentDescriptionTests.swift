import Testing
import Foundation
@testable import AppLib
import Shared

/// #79 — say what a subagent is *doing*, not just what type it is.
///
/// The issue asked for a rendered parent/child tree. Measured against real
/// data that does not pay for itself: nesting is 32 of 1052 subagents (~3%),
/// only 19 carry `parentAgentId`, and the `subagents/*.meta.json` that holds
/// it does not exist yet when `SubagentStart` fires — so a live tree needs a
/// retry loop in the hot event path to serve the 3% case, and renders
/// identically to a flat list for the other 97%.
///
/// What *is* free is the description. The parent's own tool call is
/// `Agent` with `input: {description, prompt, subagent_type, model}`, and
/// `PreToolUse` already delivers that to us. "Fix Task 5: add missing dedup
/// tests" beats "Explore".
@MainActor
struct SubagentDescriptionTests {

    private func store() -> SessionStore {
        let s = SessionStore()
        s.handleEvent(BridgeEvent(bridgeEvent: "SessionStart", agent: .claude,
                                  sessionId: "s1", cwd: "/tmp/proj"))
        return s
    }

    private func agentCall(_ description: String?, type: String?) -> BridgeEvent {
        var input: [String: AnyCodable] = [:]
        if let description { input["description"] = AnyCodable(description) }
        if let type { input["subagent_type"] = AnyCodable(type) }
        return BridgeEvent(bridgeEvent: "PreToolUse", agent: .claude, sessionId: "s1",
                           toolName: "Agent", toolInput: input)
    }

    private func start(id: String, type: String?) -> BridgeEvent {
        BridgeEvent(bridgeEvent: "SubagentStart", agent: .claude,
                    sessionId: "s1", agentId: id, agentType: type)
    }

    // MARK: - Pairing

    @Test func descriptionFromTheAgentCallLandsOnTheSubagent() {
        let s = store()
        s.handleEvent(agentCall("Fix Task 5: add missing dedup tests", type: "general-purpose"))
        s.handleEvent(start(id: "a1", type: "general-purpose"))
        #expect(s.sessions["s1"]?.activeSubagents.first?.detail
                == "Fix Task 5: add missing dedup tests")
    }

    /// Parallel dispatch of the same type: descriptions are consumed in the
    /// order they were queued.
    @Test func parallelSameTypeCallsPairInOrder() {
        let s = store()
        s.handleEvent(agentCall("first task", type: "Explore"))
        s.handleEvent(agentCall("second task", type: "Explore"))
        s.handleEvent(start(id: "a1", type: "Explore"))
        s.handleEvent(start(id: "a2", type: "Explore"))
        let details = s.sessions["s1"]?.activeSubagents.map(\.detail) ?? []
        #expect(details == ["first task", "second task"])
    }

    /// Mixed types must not steal each other's descriptions.
    @Test func mixedTypesPairByType() {
        let s = store()
        s.handleEvent(agentCall("explore work", type: "Explore"))
        s.handleEvent(agentCall("general work", type: "general-purpose"))
        s.handleEvent(start(id: "a1", type: "general-purpose"))
        s.handleEvent(start(id: "a2", type: "Explore"))
        let byId = Dictionary(uniqueKeysWithValues:
            (s.sessions["s1"]?.activeSubagents ?? []).map { ($0.id, $0.detail) })
        #expect(byId["a1"] == "general work")
        #expect(byId["a2"] == "explore work")
    }

    /// A subagent whose type never matched a queued call still tracks; it just
    /// has no detail. Never block the #40 behaviour on this enrichment.
    @Test func subagentWithoutAMatchingCallStillTracks() {
        let s = store()
        s.handleEvent(start(id: "a1", type: "Explore"))
        #expect(s.sessions["s1"]?.activeSubagents.count == 1)
        #expect(s.sessions["s1"]?.activeSubagents.first?.detail == nil)
    }

    @Test func agentCallWithoutADescriptionIsNotQueued() {
        let s = store()
        s.handleEvent(agentCall(nil, type: "Explore"))
        s.handleEvent(start(id: "a1", type: "Explore"))
        #expect(s.sessions["s1"]?.activeSubagents.first?.detail == nil)
    }

    /// Only the Agent tool queues descriptions — a Bash call with a stray
    /// `description` key must not feed this.
    @Test func otherToolsDoNotQueueDescriptions() {
        let s = store()
        s.handleEvent(BridgeEvent(
            bridgeEvent: "PreToolUse", agent: .claude, sessionId: "s1",
            toolName: "Bash",
            toolInput: ["description": AnyCodable("not a subagent")]))
        s.handleEvent(start(id: "a1", type: "Explore"))
        #expect(s.sessions["s1"]?.activeSubagents.first?.detail == nil)
    }

    // MARK: - Queue hygiene

    /// A dispatched Agent call that never produced a SubagentStart (denied,
    /// errored) must not leave its description to be claimed by an unrelated
    /// subagent later in the session.
    @Test func newUserTurnDrainsTheQueue() {
        let s = store()
        s.handleEvent(agentCall("stale work", type: "Explore"))
        s.handleEvent(BridgeEvent(bridgeEvent: "UserPromptSubmit", agent: .claude,
                                  sessionId: "s1", userPrompt: "next"))
        s.handleEvent(start(id: "a1", type: "Explore"))
        #expect(s.sessions["s1"]?.activeSubagents.first?.detail == nil)
    }

    @Test func queueIsCapped() {
        let s = store()
        for i in 0..<(SessionInfo.maxQueuedSubagentCalls + 20) {
            s.handleEvent(agentCall("task \(i)", type: "Explore"))
        }
        #expect((s.sessions["s1"]?.pendingSubagentCalls.count ?? 0)
                <= SessionInfo.maxQueuedSubagentCalls)
    }

    @Test func codexIsUnaffected() {
        let s = SessionStore()
        s.handleEvent(BridgeEvent(bridgeEvent: "SessionStart", agent: .codex,
                                  sessionId: "c1", cwd: "/tmp"))
        s.handleEvent(BridgeEvent(
            bridgeEvent: "PreToolUse", agent: .codex, sessionId: "c1",
            toolName: "Agent", toolInput: ["description": AnyCodable("x")]))
        #expect(s.sessions["c1"]?.pendingSubagentCalls.isEmpty == true)
    }

    // MARK: - Rendering

    /// One subagent: the description is what the user wants, not the type.
    @Test func singleSubagentBadgePrefersTheDescription() {
        let one = [ActiveSubagent(id: "a", type: "Explore",
                                  detail: "Fix dedup tests", startedAt: Date())]
        #expect(SubagentBadge.label(for: one) == "Fix dedup tests")
    }

    @Test func singleSubagentFallsBackToTypeWithoutADescription() {
        let one = [ActiveSubagent(id: "a", type: "Explore", detail: nil, startedAt: Date())]
        #expect(SubagentBadge.label(for: one) == "Explore")
    }

    /// Long descriptions must not stretch an already-crowded row.
    @Test func longDescriptionsAreTruncated() {
        let one = [ActiveSubagent(
            id: "a", type: "Explore",
            detail: "Fix Task 5: add the missing dedup tests and then rerun everything",
            startedAt: Date())]
        let label = try! #require(SubagentBadge.label(for: one))
        #expect(label.count <= SubagentBadge.maxDetailLength + 1)
        #expect(label.hasSuffix("…"))
    }

    @Test func severalSubagentsStillShowACount() {
        let many = (0..<3).map {
            ActiveSubagent(id: "a\($0)", type: "Explore",
                           detail: "task \($0)", startedAt: Date())
        }
        #expect(SubagentBadge.label(for: many) == "3 agents")
    }

    // MARK: - Tool preview

    /// Before this change an in-flight `Agent` call rendered as a bare tool
    /// name with no preview, because the previewer only knew about
    /// file_path / command / path.
    @Test func toolPreviewSurfacesTheAgentDescription() {
        #expect(NotchExpandedView.toolInputPreview(["description": "Review the diff"])
                == "Review the diff")
    }

    @Test func toolPreviewStillPrefersConcreteTargets() {
        #expect(NotchExpandedView.toolInputPreview(
            ["file_path": "/a/b/File.swift", "description": "ignored"]) == "File.swift")
        #expect(NotchExpandedView.toolInputPreview(
            ["command": "ls -la", "description": "ignored"]) == "ls -la")
    }

    @Test func toolPreviewReturnsNilWithNothingUseful() {
        #expect(NotchExpandedView.toolInputPreview(nil) == nil)
        #expect(NotchExpandedView.toolInputPreview(["unrelated": 1]) == nil)
    }
}
