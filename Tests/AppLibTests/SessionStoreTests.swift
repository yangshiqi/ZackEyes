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

    @Test @MainActor func submitAskUQAnswer_callsResponderWithEncodedJSON() throws {
        let store = SessionStore()
        let dataBox = Box<Data>()

        let pending = PendingPermission(
            toolName: "AskUserQuestion",
            toolInput: ["questions": [
                ["question": "Pick a color",
                 "header": "color",
                 "multiSelect": false,
                 "options": [["label": "red", "description": "warm"]]]
            ]],
            cwd: "/tmp",
            responder: { response in
                dataBox.value = try? response.encoded()
            }
        )
        store.handlePermissionRequest(sessionId: "s1", permission: pending)

        store.submitAskUQAnswer(
            sessionId: "s1",
            answers: ["Pick a color": "red"]
        )

        let data = try #require(dataBox.value)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let hook = json["hookSpecificOutput"] as! [String: Any]
        #expect(hook["hookEventName"] as? String == "PreToolUse")
        let updated = hook["updatedInput"] as! [String: Any]
        let answers = updated["answers"] as! [String: String]
        #expect(answers["Pick a color"] == "red")

        // pending should be cleared
        #expect(store.sessions["s1"]?.pendingPermission == nil)
        #expect(store.sessions["s1"]?.state == .working)
    }

    @Test @MainActor func submitAskUQAnswer_isNoOpForPermissionRequest() {
        let store = SessionStore()
        let pending = PendingPermission(
            toolName: "Bash",
            toolInput: [:],
            cwd: "/tmp",
            responder: { _ in
                #expect(Bool(false), "responder must not fire for non-AskUQ pending")
            }
        )
        store.handlePermissionRequest(sessionId: "s1", permission: pending)
        store.submitAskUQAnswer(sessionId: "s1", answers: ["q": "a"])
        #expect(store.sessions["s1"]?.pendingPermission != nil, "pending should remain untouched")
        #expect(store.sessions["s1"]?.state == .waiting, "state should remain waiting")
    }

    @Test @MainActor func submitAskUQAnswer_isNoOpForUnknownSession() {
        let store = SessionStore()
        // session "ghost" never created — call should be silent no-op
        store.submitAskUQAnswer(sessionId: "ghost", answers: ["q": "a"])
        #expect(store.sessions["ghost"] == nil)
    }
}
