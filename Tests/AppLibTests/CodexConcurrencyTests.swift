import Testing
import Foundation
import Shared
@testable import AppLib

@MainActor
struct CodexConcurrencyTests {
    @Test func completingOneConcurrentToolDoesNotClearItsSibling() {
        let store = SessionStore()
        for id in ["a", "b", "a"] {
            store.handleEvent(BridgeEvent(bridgeEvent: "PreToolUse", agent: .codex, sessionId: "s", toolName: "Bash", turnId: "t", toolUseId: id))
        }
        #expect(store.sessions["s"]?.toolCallCount == 2)
        store.handleEvent(BridgeEvent(bridgeEvent: "PostToolUse", agent: .codex, sessionId: "s", turnId: "t", toolUseId: "a"))
        #expect(store.sessions["s"]?.isToolRunning == true)
        store.handleEvent(BridgeEvent(bridgeEvent: "PostToolUse", agent: .codex, sessionId: "s", turnId: "t", toolUseId: "b"))
        #expect(store.sessions["s"]?.isToolRunning == false)
    }

    @Test func staleStopAndToolCompletionDoNotEndNewTurn() {
        let store = SessionStore()
        store.handleEvent(BridgeEvent(bridgeEvent: "UserPromptSubmit", agent: .codex, sessionId: "s", userPrompt: "first", turnId: "old"))
        store.handleEvent(BridgeEvent(bridgeEvent: "UserPromptSubmit", agent: .codex, sessionId: "s", userPrompt: "second", turnId: "new"))
        store.handleEvent(BridgeEvent(bridgeEvent: "PreToolUse", agent: .codex, sessionId: "s", toolName: "Bash", turnId: "new", toolUseId: "a"))
        store.handleEvent(BridgeEvent(bridgeEvent: "Stop", agent: .codex, sessionId: "s", lastAssistantMessage: "old reply", turnId: "old"))
        store.handleEvent(BridgeEvent(bridgeEvent: "PostToolUse", agent: .codex, sessionId: "s", turnId: "old", toolUseId: "a"))
        #expect(store.sessions["s"]?.state == .working)
        #expect(store.sessions["s"]?.isToolRunning == true)
        #expect(store.sessions["s"]?.lastAssistantMessage == nil)
    }

    @Test func steeringSameTurnPreservesRunningTools() {
        let store = SessionStore()
        store.handleEvent(BridgeEvent(bridgeEvent: "UserPromptSubmit", agent: .codex, sessionId: "s", userPrompt: "first", turnId: "t"))
        store.handleEvent(BridgeEvent(bridgeEvent: "PreToolUse", agent: .codex, sessionId: "s", turnId: "t", toolUseId: "a"))
        store.handleEvent(BridgeEvent(bridgeEvent: "UserPromptSubmit", agent: .codex, sessionId: "s", userPrompt: "correction", turnId: "t"))
        store.handleEvent(BridgeEvent(bridgeEvent: "PostToolUse", agent: .codex, sessionId: "s", turnId: "t", toolUseId: "unknown"))
        #expect(store.sessions["s"]?.isToolRunning == true)
        store.handleEvent(BridgeEvent(bridgeEvent: "PostToolUse", agent: .codex, sessionId: "s", turnId: "t", toolUseId: "a"))
        #expect(store.sessions["s"]?.isToolRunning == false)
        #expect(store.sessions["s"]?.lastUserPrompt == "correction")
    }
}

@MainActor @Test func staleOrDuplicateRolloutCompletionDoesNotNotify() {
    let store = SessionStore()
    store.recordCodexTaskStarted(sessionId: "s", cwd: nil, transcriptPath: nil, startedAt: Date(), turnId: "new")
    #expect(store.completeCodexTurn(sessionId: "s", cwd: nil, lastAgentMessage: "stale", transcriptPath: nil, completedAt: Date(), turnId: "old") == nil)
    #expect(store.sessions["s"]?.state == .working)
    #expect(store.completeCodexTurn(sessionId: "s", cwd: nil, lastAgentMessage: "done", transcriptPath: nil, completedAt: Date(), turnId: "new") != nil)
    #expect(store.completeCodexTurn(sessionId: "s", cwd: nil, lastAgentMessage: "done", transcriptPath: nil, completedAt: Date(), turnId: "new") == nil)
}

@MainActor @Test func newCodexTurnReleasesOldApproval() {
    let store = SessionStore()
    store.handleEvent(BridgeEvent(bridgeEvent: "UserPromptSubmit", agent: .codex, sessionId: "s", turnId: "old"))
    let answered = Box<BridgeResponse>()
    store.handlePermissionRequest(sessionId: "s", permission: PendingPermission(toolName: "Bash", toolInput: [:], cwd: nil, responder: { answered.value = $0 }), agent: .codex)
    store.handleEvent(BridgeEvent(bridgeEvent: "UserPromptSubmit", agent: .codex, sessionId: "s", turnId: "new"))
    #expect(store.sessions["s"]?.pendingPermissions.isEmpty == true)
    #expect(store.sessions["s"]?.state == .working)
    #expect(answered.value != nil)
}

@MainActor @Test func olderTaskStartedDoesNotReplaceNewerTurn() {
    let store = SessionStore()
    let newer = Date(timeIntervalSince1970: 200)
    store.recordCodexTaskStarted(sessionId: "s", cwd: nil, transcriptPath: nil, startedAt: newer, turnId: "new")
    store.recordCodexTaskStarted(sessionId: "s", cwd: nil, transcriptPath: nil, startedAt: newer.addingTimeInterval(-1), turnId: "old")
    #expect(store.sessions["s"]?.currentCodexTurnId == "new")
}
