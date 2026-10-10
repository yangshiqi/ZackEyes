import Testing
import Foundation
@testable import AppLib

@MainActor
struct CodexEffortTests {
    private func apply(_ payload: String, to store: SessionStore, type: String = "turn_context") throws {
        var pending = ""
        let events = CodexJsonlTailer.parseTaskLifecycleEvents(chunk: "{\"type\":\"\(type)\",\"payload\":\(payload)}\n", pending: &pending, sessionId: "s", cwd: nil, transcriptPath: "/tmp/rollout")
        let model = try #require(events.compactMap { if case .modelChanged(let model) = $0 { return model }; return nil }.first)
        store.recordCodexModel(model)
    }

    @Test func streamedEffortChangesPreserveAbsentAndClearNull() throws {
        let store = SessionStore()
        try apply(#"{"model":"gpt-6.1-sol","effort":"high"}"#, to: store)
        #expect(store.sessions["s"]?.reasoningEffort == "high")
        try apply(#"{"model":"gpt-6.1-sol"}"#, to: store)
        #expect(store.sessions["s"]?.reasoningEffort == "high")
        try apply(#"{"model":"gpt-6.1-sol","effort":"ultra"}"#, to: store)
        #expect(store.sessions["s"]?.reasoningEffort == "ultra")
        try apply(#"{"model":"gpt-6.1-sol","effort":null}"#, to: store)
        #expect(store.sessions["s"]?.reasoningEffort == nil)
    }

    @Test func settingsSnapshotsUpdateEffortAndModelSwitchDropsUnknownEffort() throws {
        let store = SessionStore()
        try apply(#"{"type":"thread_settings_applied","thread_settings":{"model":"gpt-6.1-sol","reasoning_effort":"max"}}"#, to: store, type: "event_msg")
        #expect(store.sessions["s"]?.reasoningEffort == "max")
        try apply(#"{"model":"gpt-6-astra"}"#, to: store)
        #expect(store.sessions["s"]?.reasoningEffort == nil)
        try apply(#"{"type":"session_configured","model":"gpt-6-astra","reasoning_effort":"low"}"#, to: store, type: "event_msg")
        #expect(store.sessions["s"]?.reasoningEffort == "low")
        try apply(#"{"model":"gpt-6-astra","effort":""}"#, to: store)
        #expect(store.sessions["s"]?.reasoningEffort == nil)
    }

    @Test func attachReadsLatestEffortRatherThanFirstTurn() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        let text = """
        {"type":"session_meta","payload":{"cwd":"/tmp"}}
        {"type":"turn_context","payload":{"model":"gpt-6.1-sol","effort":"low"}}
        {"type":"turn_context","payload":{"model":"gpt-6.1-sol","effort":"high"}}
        """ + "\n"
        try text.write(to: file, atomically: true, encoding: .utf8)
        #expect(CodexJsonlTailer.parseInitialTurnContext(at: file)?.reasoningEffort == "high")
        let gap = "{\"type\":\"ignored\",\"payload\":\"" + String(repeating: "x", count: 1_200_000) + "\"}\n"
        try (text + gap + #"{"type":"turn_context","payload":{"model":"gpt-6-astra","effort":"max"}}"# + "\n").write(to: file, atomically: true, encoding: .utf8)
        #expect(CodexJsonlTailer.parseInitialTurnContext(at: file)?.model == "gpt-6-astra")
        #expect(CodexJsonlTailer.parseInitialTurnContext(at: file)?.reasoningEffort == "max")
    }
}

@Test func bootstrapSettingsSnapshotsOverrideTurnEffort() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
    defer { try? FileManager.default.removeItem(at: file) }
    for (raw, expected) in [(#""ultra""#, "ultra" as String?), ("null", nil)] {
        let text = #"{"type":"turn_context","payload":{"model":"gpt-6.1-sol","effort":"high"}}"# + "\n" + """
        {"type":"event_msg","payload":{"type":"thread_settings_applied","thread_settings":{"model":"gpt-6.1-sol","reasoning_effort":\(raw)}}}
        """ + "\n"
        try text.write(to: file, atomically: true, encoding: .utf8)
        let initial = try #require(CodexJsonlTailer.parseInitialTurnContext(at: file))
        #expect(initial.reasoningEffort == expected)
        #expect(initial.updatesReasoningEffort)
    }
}
