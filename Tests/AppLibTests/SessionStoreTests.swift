import Testing
import Foundation
@testable import AppLib
import Shared

/// Reference box for capturing values from @Sendable closures in tests.
final class Box<T>: @unchecked Sendable { var value: T? }

@MainActor
struct SessionStoreTests {

    // 1. Initial state is empty
    @Test func initialStateIsEmpty() {
        let store = SessionStore()
        #expect(store.sessions.isEmpty)
        #expect(store.primarySession == nil)
        #expect(store.aggregateState == .idle)
    }

    // 2. SessionStart creates a session
    @Test func sessionStartCreatesSession() {
        let store = SessionStore()
        let event = BridgeEvent(bridgeEvent: "SessionStart", sessionId: "s1", cwd: "/tmp")
        store.handleEvent(event)
        #expect(store.sessions.count == 1)
        #expect(store.sessions["s1"]?.state == .working)
        #expect(store.sessions["s1"]?.cwd == "/tmp")
        #expect(store.aggregateState == .working)
    }

    // 3. PreToolUse increments tool count
    @Test func preToolUseIncrementsToolCount() {
        let store = SessionStore()
        store.handleEvent(BridgeEvent(bridgeEvent: "SessionStart", sessionId: "s1", cwd: "/tmp"))
        store.handleEvent(BridgeEvent(bridgeEvent: "PreToolUse", sessionId: "s1", toolName: "Bash"))
        #expect(store.sessions["s1"]?.currentToolName == "Bash")
        #expect(store.sessions["s1"]?.toolCallCount == 1)
        store.handleEvent(BridgeEvent(bridgeEvent: "PreToolUse", sessionId: "s1", toolName: "Write"))
        #expect(store.sessions["s1"]?.toolCallCount == 2)
    }

    // 4. PermissionRequest sets waiting on the right session
    @Test func permissionRequestSetsWaiting() {
        let store = SessionStore()
        store.handleEvent(BridgeEvent(bridgeEvent: "SessionStart", sessionId: "s1", cwd: "/tmp"))
        let permission = PendingPermission(
            toolName: "Bash",
            toolInput: [:],
            cwd: "/tmp",
            responder: { _ in }
        )
        store.handlePermissionRequest(sessionId: "s1", permission: permission)
        #expect(store.sessions["s1"]?.state == .waiting)
        #expect(store.sessions["s1"]?.pendingPermission != nil)
        #expect(store.aggregateState == .waiting)
    }

    // 5. resolvePrimaryPermission allow returns to working
    @Test func resolvePermissionAllowReturnsToWorking() {
        let store = SessionStore()
        store.handleEvent(BridgeEvent(bridgeEvent: "SessionStart", sessionId: "s1", cwd: "/tmp"))
        let permission = PendingPermission(
            toolName: "Bash",
            toolInput: [:],
            cwd: "/tmp",
            responder: { _ in }
        )
        store.handlePermissionRequest(sessionId: "s1", permission: permission)
        store.resolvePrimaryPermission(allow: true)
        #expect(store.sessions["s1"]?.state == .working)
        #expect(store.sessions["s1"]?.pendingPermission == nil)
    }

    // 5b. resolvePermission(sessionId:allow:) only clears the named session,
    //     leaves other pending sessions intact. Guards the contract relied on
    //     by per-session approval buttons in the notch panel.
    @Test func resolvePermissionScopedToNamedSession() {
        let store = SessionStore()
        store.handleEvent(BridgeEvent(bridgeEvent: "SessionStart", sessionId: "s1", cwd: "/a"))
        store.handleEvent(BridgeEvent(bridgeEvent: "SessionStart", sessionId: "s2", cwd: "/b"))

        let s1Box = Box<BridgeResponse>()
        let s2Box = Box<BridgeResponse>()
        let s1Permission = PendingPermission(
            toolName: "Bash", toolInput: [:], cwd: "/a",
            responder: { s1Box.value = $0 }
        )
        let s2Permission = PendingPermission(
            toolName: "Write", toolInput: [:], cwd: "/b",
            responder: { s2Box.value = $0 }
        )
        store.handlePermissionRequest(sessionId: "s1", permission: s1Permission)
        store.handlePermissionRequest(sessionId: "s2", permission: s2Permission)

        store.resolvePermission(sessionId: "s2", allow: false)

        // s2 cleared and denied
        #expect(store.sessions["s2"]?.pendingPermission == nil)
        #expect(store.sessions["s2"]?.state == .working)
        if case .permission(let r) = s2Box.value {
            #expect(r.hookSpecificOutput.decision.behavior == "deny",
                    "s2 should have been denied")
        } else {
            #expect(Bool(false), "s2 responder should have received a .permission response")
        }

        // s1 untouched
        #expect(store.sessions["s1"]?.pendingPermission != nil)
        #expect(store.sessions["s1"]?.state == .waiting)
        #expect(s1Box.value == nil)
    }

    // 6. SessionEnd removes the session
    @Test func sessionEndRemovesSession() {
        let store = SessionStore()
        store.handleEvent(BridgeEvent(bridgeEvent: "SessionStart", sessionId: "s1", cwd: "/tmp"))
        store.handleEvent(BridgeEvent(bridgeEvent: "SessionEnd", sessionId: "s1"))
        #expect(store.sessions.isEmpty)
    }

    // 7. Stop sets idle but keeps session
    @Test func stopSetsIdleKeepsSession() {
        let store = SessionStore()
        store.handleEvent(BridgeEvent(bridgeEvent: "SessionStart", sessionId: "s1", cwd: "/tmp"))
        store.handleEvent(BridgeEvent(bridgeEvent: "Stop", sessionId: "s1"))
        #expect(store.sessions["s1"]?.state == .idle)
        #expect(store.sessions.count == 1)  // session still exists
    }

    @Test func recordCodexTaskStartedMarksSessionWorking() {
        let store = SessionStore()
        let startedAt = Date(timeIntervalSince1970: 1_777_962_840)

        store.recordCodexTaskStarted(
            sessionId: "codex-1",
            cwd: "/Users/test/proj",
            transcriptPath: "/tmp/rollout.jsonl",
            startedAt: startedAt,
            turnId: "t1"
        )

        let session = store.sessions["codex-1"]
        #expect(session?.agent == .codex)
        #expect(session?.state == .working)
        #expect(session?.isToolRunning == true)
        #expect(session?.currentToolName == "Codex")
        #expect(session?.currentToolInput?["turn_id"] as? String == "t1")
        #expect(session?.cwd == "/Users/test/proj")
        #expect(session?.transcriptPath == "/tmp/rollout.jsonl")
        #expect(session?.lastActiveAt == startedAt)
        #expect(session?.source == .detected)
    }

    @Test func recordCodexTaskCompleteKeepsTailerSessionDetected() {
        let store = SessionStore()
        let startedAt = Date(timeIntervalSince1970: 1_777_962_840)
        let completedAt = startedAt.addingTimeInterval(10)

        store.recordCodexTaskStarted(
            sessionId: "codex-1",
            cwd: "/Users/test/proj",
            transcriptPath: "/tmp/rollout.jsonl",
            startedAt: startedAt,
            turnId: "t1"
        )

        let completed = store.recordCodexTaskComplete(
            sessionId: "codex-1",
            cwd: "/Users/test/proj",
            lastAgentMessage: "done",
            transcriptPath: "/tmp/rollout.jsonl",
            completedAt: completedAt
        )

        #expect(completed.source == .detected)
        #expect(completed.state == .idle)
        #expect(completed.isToolRunning == false)
        #expect(completed.lastAssistantMessage == "done")
        #expect(store.sessions["codex-1"]?.source == .detected)
    }

    @Test func recordCodexContextPopulatesContextFields() {
        let store = SessionStore()
        let observedAt = Date(timeIntervalSince1970: 1_777_962_860)

        store.recordCodexContext(
            sessionId: "codex-context",
            cwd: "/Users/test/proj",
            contextUsedPct: 48.37,
            contextWindowSize: 258400,
            transcriptPath: "/tmp/rollout.jsonl",
            observedAt: observedAt
        )

        let session = store.sessions["codex-context"]
        #expect(session?.agent == .codex)
        #expect(session?.state == .working)
        #expect(session?.isToolRunning == true)
        #expect(session?.currentToolName == "Codex")
        #expect(session?.contextUsedPct == 48.37)
        #expect(session?.contextWindowSize == 258400)
        #expect(session?.transcriptPath == "/tmp/rollout.jsonl")
        #expect(session?.lastActiveAt == observedAt)
        #expect(session?.source == .detected)
    }

    @Test func recordCodexContextDoesNotReviveIdleSession() {
        let store = SessionStore()
        let startedAt = Date(timeIntervalSince1970: 1_777_962_840)
        let completedAt = startedAt.addingTimeInterval(10)
        let observedAt = completedAt.addingTimeInterval(5)

        store.recordCodexTaskStarted(
            sessionId: "codex-idle",
            cwd: "/Users/test/proj",
            transcriptPath: "/tmp/rollout.jsonl",
            startedAt: startedAt,
            turnId: "t1"
        )
        store.recordCodexTaskComplete(
            sessionId: "codex-idle",
            cwd: "/Users/test/proj",
            lastAgentMessage: "done",
            transcriptPath: "/tmp/rollout.jsonl",
            completedAt: completedAt
        )

        store.recordCodexContext(
            sessionId: "codex-idle",
            cwd: "/Users/test/proj",
            contextUsedPct: 12.5,
            contextWindowSize: 258400,
            transcriptPath: "/tmp/rollout.jsonl",
            observedAt: observedAt
        )

        let session = store.sessions["codex-idle"]
        #expect(session?.contextUsedPct == 12.5)
        #expect(session?.contextWindowSize == 258400)
        #expect(session?.state == .idle)
        #expect(session?.isToolRunning == false)
        #expect(session?.lastActiveAt == observedAt)
    }

    // 8. Multiple sessions tracked independently
    @Test func multipleSessionsTrackedIndependently() {
        let store = SessionStore()
        store.handleEvent(BridgeEvent(bridgeEvent: "SessionStart", sessionId: "s1", cwd: "/project-a"))
        store.handleEvent(BridgeEvent(bridgeEvent: "SessionStart", sessionId: "s2", cwd: "/project-b"))
        store.handleEvent(BridgeEvent(bridgeEvent: "PreToolUse", sessionId: "s1", toolName: "Bash"))
        store.handleEvent(BridgeEvent(bridgeEvent: "PreToolUse", sessionId: "s2", toolName: "Write"))
        store.handleEvent(BridgeEvent(bridgeEvent: "PreToolUse", sessionId: "s2", toolName: "Edit"))

        #expect(store.sessions.count == 2)
        #expect(store.sessions["s1"]?.toolCallCount == 1)
        #expect(store.sessions["s2"]?.toolCallCount == 2)
        #expect(store.sessions["s1"]?.currentToolName == "Bash")
        #expect(store.sessions["s2"]?.currentToolName == "Edit")
    }

    // 9. Primary session prioritizes pending permission
    @Test func primarySessionPrioritizesPending() {
        let store = SessionStore()
        store.handleEvent(BridgeEvent(bridgeEvent: "SessionStart", sessionId: "s1", cwd: "/a"))
        store.handleEvent(BridgeEvent(bridgeEvent: "SessionStart", sessionId: "s2", cwd: "/b"))
        // s2 is more recent (working), but s1 gets a pending permission
        let permission = PendingPermission(toolName: "Bash", toolInput: [:], cwd: "/a", responder: { _ in })
        store.handlePermissionRequest(sessionId: "s1", permission: permission)
        #expect(store.primarySession?.id == "s1")
    }

    // 10a. detectError must NOT false-match on standalone numbers in prose.
    //       The old contains("500") check fired on any assistant message that
    //       mentioned the number 500 (e.g. "<500=low, <3000=mid, >3000=high")
    //       and showed a red "Server error (500)" banner in the notch.
    @Test func detectErrorIgnoresNumbersInProse() {
        // Regression — the exact string that triggered the original bug report
        #expect(SessionStore.detectError(in: "length <500=low, <3000=mid, >3000=high") == nil)
        #expect(SessionStore.detectError(in: "this server handles 500 concurrent users") == nil)
        #expect(SessionStore.detectError(in: "I have 500 unread messages") == nil)
        #expect(SessionStore.detectError(in: "the 403 area code") == nil)
        #expect(SessionStore.detectError(in: "5000 requests per second") == nil)
    }

    @Test func detectErrorMatchesRealErrorPhrases() {
        // These are the phrasings Claude Code actually emits when the API fails
        #expect(SessionStore.detectError(
            in: "Sorry, I encountered a 503 Service Unavailable error from the API."
        ) == "Service unavailable (503)")
        #expect(SessionStore.detectError(
            in: "500 Internal Server Error"
        ) == "Server error (500)")
        #expect(SessionStore.detectError(
            in: "Got a 429 Too Many Requests response"
        ) == "Rate limited (429)")
        #expect(SessionStore.detectError(
            in: "You have hit the rate limit"
        ) == "Rate limited")
        #expect(SessionStore.detectError(
            in: "{\"type\":\"overloaded_error\"}"
        ) == "API overloaded")
        #expect(SessionStore.detectError(
            in: "Your credit balance is too low"
        ) == "Insufficient credits")
    }

    // 10b. removeSessions deletes the requested ids, but refuses to clear
    //       a session that has an active pendingPermission, and silently
    //       ignores ids that don't exist in the store.
    @Test func removeSessionsRespectsPendingPermissionAndUnknownIds() {
        let store = SessionStore()
        store.handleEvent(BridgeEvent(bridgeEvent: "SessionStart", sessionId: "a", cwd: "/tmp"))
        store.handleEvent(BridgeEvent(bridgeEvent: "SessionStart", sessionId: "b", cwd: "/tmp"))
        store.handleEvent(BridgeEvent(bridgeEvent: "SessionStart", sessionId: "c", cwd: "/tmp"))

        // c has a pending permission — should survive a remove request
        let permission = PendingPermission(toolName: "Bash", toolInput: [:], cwd: "/tmp", responder: { _ in })
        store.handlePermissionRequest(sessionId: "c", permission: permission)

        store.removeSessions(ids: ["a", "c", "ghost"])

        #expect(store.sessions["a"] == nil)            // removed
        #expect(store.sessions["b"] != nil)            // not requested
        #expect(store.sessions["c"] != nil)            // pending — refused
        #expect(store.sessions.count == 2)             // ghost id is a no-op
    }

    // 10. Aggregate state reflects worst status across sessions
    @Test func aggregateStateReflectsWorstStatus() {
        let store = SessionStore()
        store.handleEvent(BridgeEvent(bridgeEvent: "SessionStart", sessionId: "s1", cwd: "/a"))
        store.handleEvent(BridgeEvent(bridgeEvent: "Stop", sessionId: "s1"))
        #expect(store.aggregateState == .idle)
        store.handleEvent(BridgeEvent(bridgeEvent: "SessionStart", sessionId: "s2", cwd: "/b"))
        #expect(store.aggregateState == .working)
        let permission = PendingPermission(toolName: "Bash", toolInput: [:], cwd: "/b", responder: { _ in })
        store.handlePermissionRequest(sessionId: "s2", permission: permission)
        #expect(store.aggregateState == .waiting)
    }

    @Test @MainActor func askUQOptionsParseAfterAnyCodableRoundTrip() throws {
        // Regression: existing AskUQ tests construct toolInput with native
        // Swift [String: Any] dicts. The real path goes through:
        //   JSON → BridgeEvent decode → AnyCodable → mapValues { $0.value }
        // This test exercises that real path and asserts options actually
        // parse — guards against the symptom "popup shows but no options".
        let json = """
        {
          "_bridge_event": "PreToolUse",
          "session_id": "s1",
          "hook_event_name": "PreToolUse",
          "tool_name": "AskUserQuestion",
          "tool_input": {
            "questions": [
              {
                "question": "Pick a fruit",
                "header": "fruit",
                "multiSelect": true,
                "options": [
                  {"label": "Apple", "description": "red"},
                  {"label": "Banana", "description": "yellow"}
                ]
              }
            ]
          }
        }
        """.data(using: .utf8)!
        let event = try JSONDecoder().decode(BridgeEvent.self, from: json)
        let toolInput = event.toolInput?.mapValues { $0.value } ?? [:]
        let pending = PendingPermission(
            toolName: event.toolName ?? "AskUserQuestion",
            toolInput: toolInput,
            cwd: nil,
            responder: { _ in }
        )
        let questions = pending.questions
        #expect(questions.count == 1)
        #expect(questions.first?.options.count == 2,
                "options must parse from AnyCodable-decoded toolInput")
        #expect(questions.first?.options.map(\.label) == ["Apple", "Banana"])
    }

    @Test @MainActor func preToolUseAsFirstEventStampsClaudePid() {
        // Regression: when AskUQ (or any PreToolUse) is the first event the
        // app sees for a session — i.e. no prior SessionStart, e.g. because
        // the CC session predated ZackEyes launch — the session was created
        // without claudePid. Submit-popup keystroke injection then failed at
        // GUARD-4 ("missing claudePid"), so multi-select Submit silently
        // did nothing. Stamp ppid on creation.
        let store = SessionStore()
        store.handleEvent(BridgeEvent(
            bridgeEvent: "PreToolUse",
            sessionId: "fresh-session",
            toolName: "AskUserQuestion",
            bridgePpid: 12345
        ))
        #expect(store.sessions["fresh-session"]?.claudePid == 12345)
    }

    @Test @MainActor func userPromptSubmitAsFirstEventStampsClaudePid() {
        // Same shape as above but UserPromptSubmit — defensive coverage so
        // if a session's first event is a user message (not SessionStart),
        // claudePid still lands.
        let store = SessionStore()
        store.handleEvent(BridgeEvent(
            bridgeEvent: "UserPromptSubmit",
            sessionId: "fresh-session-2",
            userPrompt: "hello",
            bridgePpid: 67890
        ))
        #expect(store.sessions["fresh-session-2"]?.claudePid == 67890)
    }

    @Test @MainActor func postToolUseAskUQ_clearsPendingPopup() {
        // Other half of Path 2: the popup must auto-dismiss when CC's
        // terminal UI closes (i.e. the user answered there first).
        let store = SessionStore()
        let pending = PendingPermission(
            toolName: "AskUserQuestion",
            toolInput: ["questions": [
                ["question": "Q?", "multiSelect": false,
                 "options": [["label": "x", "description": ""]]]
            ]],
            cwd: "/tmp",
            responder: { _ in }
        )
        store.handleEvent(BridgeEvent(bridgeEvent: "SessionStart", sessionId: "s1", cwd: "/tmp"))
        store.handlePermissionRequest(sessionId: "s1", permission: pending)
        #expect(store.sessions["s1"]?.pendingPermission != nil)
        #expect(store.sessions["s1"]?.state == .waiting)

        let postEvent = BridgeEvent(
            bridgeEvent: "PostToolUse",
            sessionId: "s1",
            cwd: "/tmp",
            toolName: "AskUserQuestion"
        )
        store.handleEvent(postEvent)

        #expect(store.sessions["s1"]?.pendingPermission == nil,
                "AskUQ PostToolUse must clear the popup")
        #expect(store.sessions["s1"]?.state == .working)
    }

    @Test @MainActor func postToolUseOtherTool_doesNotClearAskUQPopup() {
        // Sanity: a PostToolUse for some unrelated tool must not steal the
        // dismiss path from a still-live AskUQ popup.
        let store = SessionStore()
        let pending = PendingPermission(
            toolName: "AskUserQuestion",
            toolInput: ["questions": [
                ["question": "Q?", "multiSelect": false,
                 "options": [["label": "x", "description": ""]]]
            ]],
            cwd: "/tmp",
            responder: { _ in }
        )
        store.handleEvent(BridgeEvent(bridgeEvent: "SessionStart", sessionId: "s1", cwd: "/tmp"))
        store.handlePermissionRequest(sessionId: "s1", permission: pending)

        let unrelated = BridgeEvent(
            bridgeEvent: "PostToolUse",
            sessionId: "s1",
            cwd: "/tmp",
            toolName: "Bash"
        )
        store.handleEvent(unrelated)
        #expect(store.sessions["s1"]?.pendingPermission != nil)
    }

}
