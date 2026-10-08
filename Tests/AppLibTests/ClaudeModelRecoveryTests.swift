import Foundation
import Testing
import Shared
@testable import AppLib

@MainActor
struct ClaudeModelRecoveryTests {
    @Test func startupUsesLatestRealAssistantModelWithoutInventingEffortOrOverwritingLiveState() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let project = root.appendingPathComponent("p")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let transcript = """
        {"type":"assistant","cwd":"/tmp","message":{"model":"claude-opus-5-5","content":[{"type":"text","text":"earlier"}]}}
        {"type":"assistant","message":{"model":"claude-fable-5-1","content":[{"type":"thinking","thinking":"private"},{"type":"text","text":"latest"}]}}
        {"type":"assistant","message":{"model":"<synthetic>","content":[]}}
        """
        try transcript.write(to: project.appendingPathComponent("s.jsonl"), atomically: true, encoding: .utf8)
        let detected = SessionScanner(projectsDir: root, codexSessionsDir: nil).scan()
        let store = SessionStore()
        #expect(store.importDetectedSessions(detected) == 1)
        #expect(store.sessions["s"]?.modelDisplayName == "Fable 5.1")
        #expect(store.sessions["s"]?.reasoningEffort == nil)
        #expect(store.sessions["s"]?.lastAssistantMessage == "latest")
        #expect(store.sessions["s"]?.state == .idle)
        store.handleEvent(BridgeEvent(bridgeEvent: "StatusLine", sessionId: "s", model: ["display_name": AnyCodable("Live model")]))
        _ = store.importDetectedSessions(detected)
        #expect(store.sessions["s"]?.modelDisplayName == "Live model")
    }
}

@Test func claudeModelLabelsFormatOnlyObservedNumericIDs() {
    #expect(ClaudeModelMetadata.displayName(for: "claude-opus-5-5") == "Opus 5.5")
    #expect(ClaudeModelMetadata.displayName(for: "claude-fable-5-1-20261001") == "Fable 5.1")
    #expect(ClaudeModelMetadata.displayName(for: "Opus 5.5") == "Opus 5.5")
    #expect(ClaudeModelMetadata.displayName(for: "custom-provider-model") == "custom-provider-model")
    #expect(ClaudeModelMetadata.displayName(for: "claude-opus-5-5-fast") == "claude-opus-5-5-fast")
}
