import Testing
import Foundation
import Shared
@testable import AppLib

@MainActor
struct CodexCompactionTests {
    @Test func registersCompactionHooks() {
        #expect(CodexHookInstaller.hookEvents.contains("PreCompact"))
        #expect(CodexHookInstaller.hookEvents.contains("PostCompact"))
    }

    @Test func hookAndRolloutCompletionsCountOnceInEitherOrder() {
        for rolloutFirst in [true, false] {
            let store = SessionStore()
            store.handleEvent(BridgeEvent(bridgeEvent: "SessionStart", agent: .codex, sessionId: "s"))
            store.handleEvent(BridgeEvent(bridgeEvent: "PreCompact", agent: .codex, sessionId: "s", trigger: "auto"))
            if rolloutFirst { _ = store.recordCodexCompacted(sessionId: "s", cwd: nil, transcriptPath: nil, observedAt: Date()) }
            store.handleEvent(BridgeEvent(bridgeEvent: "PostCompact", agent: .codex, sessionId: "s", trigger: "auto"))
            if !rolloutFirst { _ = store.recordCodexCompacted(sessionId: "s", cwd: nil, transcriptPath: nil, observedAt: Date()) }
            #expect(store.sessions["s"]?.compactCount == 1)
            #expect(store.sessions["s"]?.isCompacting == false)
            #expect(store.sessions["s"]?.state == .working)
            // A new begin event distinguishes another fast compaction.
            store.handleEvent(BridgeEvent(bridgeEvent: "PreCompact", agent: .codex, sessionId: "s", trigger: "auto"))
            store.handleEvent(BridgeEvent(bridgeEvent: "PostCompact", agent: .codex, sessionId: "s", trigger: "auto"))
            #expect(store.sessions["s"]?.compactCount == 2)
        }
    }

    @Test func fallbackKeepsActiveTurnWorkingAndCreatesIdleUnknownSession() {
        let store = SessionStore()
        store.handleEvent(BridgeEvent(bridgeEvent: "SessionStart", agent: .codex, sessionId: "s"))
        #expect(store.recordCodexCompacted(sessionId: "s", cwd: nil, transcriptPath: nil, observedAt: Date()))
        #expect(store.sessions["s"]?.state == .working)
        #expect(store.recordCodexCompacted(sessionId: "other", cwd: nil, transcriptPath: nil, observedAt: Date()))
        #expect(store.sessions["other"]?.state == .idle)
    }
}

@Test func codexParserEmitsCompactCompletionWithoutReadingReplacementHistory() {
    var pending = ""
    let events = CodexJsonlTailer.parseTaskLifecycleEvents(chunk: #"{"timestamp":"2026-10-08T12:00:00.000Z","type":"compacted","payload":{"replacement_history":[]}}"# + "\n" + #"{"timestamp":"2026-10-08T12:00:00.000Z","type":"event_msg","payload":{"type":"context_compacted"}}"# + "\n", pending: &pending, sessionId: "s", cwd: nil, transcriptPath: "/tmp/rollout")
    #expect(events.count == 1)
    guard let first = events.first, case .compacted(let event) = first else { Issue.record("missing compact event"); return }
    #expect(event.sessionId == "s")
    #expect(event.observedAt != nil)
}

@MainActor @Test func manualCompactStateIsSavedWhenRolloutAlreadyCountedCompletion() {
    for rolloutFirst in [true, false] {
        let store = SessionStore()
        store.handleEvent(BridgeEvent(bridgeEvent: "PreToolUse", agent: .codex, sessionId: "s", toolName: "Bash"))
        store.handleEvent(BridgeEvent(bridgeEvent: "PreCompact", agent: .codex, sessionId: "s", trigger: "manual"))
        if rolloutFirst { _ = store.recordCodexCompacted(sessionId: "s", cwd: nil, transcriptPath: nil, observedAt: Date()) }
        store.handleEvent(BridgeEvent(bridgeEvent: "PostCompact", agent: .codex, sessionId: "s", trigger: "manual"))
        if !rolloutFirst { _ = store.recordCodexCompacted(sessionId: "s", cwd: nil, transcriptPath: nil, observedAt: Date()) }
        #expect(store.sessions["s"]?.compactCount == 1)
        #expect(store.sessions["s"]?.state == .idle)
        #expect(store.sessions["s"]?.isToolRunning == false)
        #expect(store.sessions["s"]?.isCompacting == false)
    }
}
