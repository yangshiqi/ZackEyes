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

    // 5a. "Allow Always" sends an allow for the current request, clears pending,
    //     and remembers the tool so future requests for it are auto-allowed.
    @Test func allowAlwaysApprovesAndRemembersTool() {
        let store = SessionStore()
        store.handleEvent(BridgeEvent(bridgeEvent: "SessionStart", sessionId: "s1", cwd: "/tmp"))
        let box = Box<BridgeResponse>()
        let permission = PendingPermission(
            toolName: "Read", toolInput: [:], cwd: "/tmp",
            responder: { box.value = $0 }
        )
        store.handlePermissionRequest(sessionId: "s1", permission: permission)

        #expect(store.isToolAutoAllowed(sessionId: "s1", toolName: "Read") == false)
        store.allowAlways(sessionId: "s1")

        // Current request allowed + pending cleared + back to working
        if case .permission(let r) = box.value {
            #expect(r.hookSpecificOutput.decision.behavior == "allow")
        } else {
            #expect(Bool(false), "allowAlways should send a .permission(allow) response")
        }
        #expect(store.sessions["s1"]?.pendingPermission == nil)
        #expect(store.sessions["s1"]?.state == .working)
        // Future Read requests in this session are now auto-allowed
        #expect(store.isToolAutoAllowed(sessionId: "s1", toolName: "Read"))
        // A different tool is NOT auto-allowed
        #expect(store.isToolAutoAllowed(sessionId: "s1", toolName: "Write") == false)
    }

    // #128: a high-risk tool (Bash) is approved once but never remembered — every
    // future invocation still prompts, even after "Allow Always".
    @Test func allowAlwaysDoesNotRememberHighRiskTool() {
        let store = SessionStore()
        store.handleEvent(BridgeEvent(bridgeEvent: "SessionStart", sessionId: "s1", cwd: "/tmp"))
        let box = Box<BridgeResponse>()
        let permission = PendingPermission(
            toolName: "Bash", toolInput: [:], cwd: "/tmp",
            responder: { box.value = $0 }
        )
        store.handlePermissionRequest(sessionId: "s1", permission: permission)
        store.allowAlways(sessionId: "s1")

        // The current request is still approved...
        if case .permission(let r) = box.value {
            #expect(r.hookSpecificOutput.decision.behavior == "allow")
        } else {
            #expect(Bool(false), "allowAlways should still approve the current high-risk request")
        }
        #expect(store.sessions["s1"]?.pendingPermission == nil)
        // ...but Bash is NOT remembered (#128).
        #expect(store.isToolAutoAllowed(sessionId: "s1", toolName: "Bash") == false)
        #expect(store.sessions["s1"]?.autoAllowedTools.contains("Bash") == false)
        #expect(SessionStore.isHighRisk("Bash"))
        #expect(SessionStore.isHighRisk("Read") == false)
    }

    // 5b. Auto-allow is scoped per session: allowing all Read in s1 must not
    //     auto-allow Read in s2.
    @Test func autoAllowIsScopedPerSession() {
        let store = SessionStore()
        store.handleEvent(BridgeEvent(bridgeEvent: "SessionStart", sessionId: "s1", cwd: "/a"))
        store.handleEvent(BridgeEvent(bridgeEvent: "SessionStart", sessionId: "s2", cwd: "/b"))
        let permission = PendingPermission(
            toolName: "Read", toolInput: [:], cwd: "/a", responder: { _ in }
        )
        store.handlePermissionRequest(sessionId: "s1", permission: permission)
        store.allowAlways(sessionId: "s1")

        #expect(store.isToolAutoAllowed(sessionId: "s1", toolName: "Read"))
        #expect(store.isToolAutoAllowed(sessionId: "s2", toolName: "Read") == false)
    }

    @Test func isToolAutoAllowedDefaultsFalse() {
        let store = SessionStore()
        store.handleEvent(BridgeEvent(bridgeEvent: "SessionStart", sessionId: "s1", cwd: "/tmp"))
        #expect(store.isToolAutoAllowed(sessionId: "s1", toolName: "Bash") == false)
        // Unknown session is also false (no crash).
        #expect(store.isToolAutoAllowed(sessionId: "nope", toolName: "Bash") == false)
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

    // #43 — a Stop payload populates the recap text, and a new prompt clears it
    // so a resting card never shows last turn's stale reply (acceptance ①).
    @Test func stopPayloadSetsRecapText_clearedOnNewPrompt() {
        let store = SessionStore()
        store.handleEvent(BridgeEvent(bridgeEvent: "Stop", sessionId: "s1",
                                      lastAssistantMessage: "Fixed the parser."))
        #expect(store.sessions["s1"]?.lastAssistantMessage == "Fixed the parser.")
        #expect(store.sessions["s1"]?.state == .idle)
        store.handleEvent(BridgeEvent(bridgeEvent: "UserPromptSubmit", sessionId: "s1",
                                      userPrompt: "now do something else"))
        #expect(store.sessions["s1"]?.lastAssistantMessage == nil)
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

    // MARK: - Codex error surfacing (usage-limit hit / API failure)

    @Test func recordCodexErrorSurfacesUsageLimitOnBanner() {
        let store = SessionStore()
        let at = Date(timeIntervalSince1970: 1_777_966_338)
        let message = "You've hit your usage limit. Upgrade to Pro, visit https://chatgpt.com/codex/settings/usage to purchase more credits or try again at 7:34 PM."

        let result = store.recordCodexError(
            sessionId: "codex-err",
            cwd: "/Users/test/proj",
            message: message,
            errorInfo: "usage_limit_exceeded",
            transcriptPath: "/tmp/rollout.jsonl",
            observedAt: at
        )

        #expect(result.isNew)
        let session = store.sessions["codex-err"]
        #expect(session?.agent == .codex)
        #expect(session?.source == .detected)
        #expect(session?.errorMessage == "Usage limit reached")
        #expect(session?.errorAt == at)
        // Full text mirrored into lastAssistantMessage so the banner detail
        // shows the reset time + link (mirrors Claude's error path).
        #expect(session?.lastAssistantMessage == message)
    }

    @Test func recordCodexErrorDedupesRepeatWithinWindow() {
        let store = SessionStore()
        let first = Date(timeIntervalSince1970: 1_777_966_338)
        let message = "You've hit your usage limit. Try again at 7:34 PM."

        let r1 = store.recordCodexError(
            sessionId: "codex-err", cwd: "/p", message: message,
            errorInfo: "usage_limit_exceeded", transcriptPath: "/tmp/r.jsonl",
            observedAt: first
        )
        // 16s later — same ongoing limit, should NOT re-notify.
        let secondAt = first.addingTimeInterval(16)
        let r2 = store.recordCodexError(
            sessionId: "codex-err", cwd: "/p", message: message,
            errorInfo: "usage_limit_exceeded", transcriptPath: "/tmp/r.jsonl",
            observedAt: secondAt
        )
        // Well past the window SINCE THE LAST error — a fresh attempt failing
        // again (codex's real pattern is a ~48-min-later retry) re-notifies.
        let thirdAt = secondAt.addingTimeInterval(SessionStore.codexErrorNotifyWindow + 5)
        let r3 = store.recordCodexError(
            sessionId: "codex-err", cwd: "/p", message: message,
            errorInfo: "usage_limit_exceeded", transcriptPath: "/tmp/r.jsonl",
            observedAt: thirdAt
        )

        #expect(r1.isNew)
        #expect(r2.isNew == false)
        #expect(r3.isNew)
        // Banner is always refreshed regardless of dedup.
        #expect(store.sessions["codex-err"]?.errorAt == thirdAt)
    }

    @Test func recordCodexErrorDistinctMessagesNotCollapsed() {
        // Two DIFFERENT failures that share the generic "Codex error" label,
        // within the dedup window, must both notify — dedup keys on the message
        // too, not just the label (CodeRabbit PR review).
        let store = SessionStore()
        let at = Date(timeIntervalSince1970: 1_777_966_338)
        let r1 = store.recordCodexError(
            sessionId: "codex-err", cwd: "/p", message: "network blip alpha",
            errorInfo: nil, transcriptPath: "/tmp/r.jsonl", observedAt: at
        )
        let r2 = store.recordCodexError(
            sessionId: "codex-err", cwd: "/p", message: "totally different failure beta",
            errorInfo: nil, transcriptPath: "/tmp/r.jsonl", observedAt: at.addingTimeInterval(10)
        )
        #expect(r1.session.errorMessage == "Codex error")  // same generic label
        #expect(r2.session.errorMessage == "Codex error")
        #expect(r1.isNew)
        #expect(r2.isNew)   // distinct message → not collapsed despite same label
    }

    @Test func recordCodexTaskCompleteClearsErrorOnRecovery() {
        let store = SessionStore()
        let at = Date(timeIntervalSince1970: 1_777_966_338)
        store.recordCodexError(
            sessionId: "codex-err", cwd: "/p", message: "You've hit your usage limit.",
            errorInfo: "usage_limit_exceeded", transcriptPath: "/tmp/r.jsonl",
            observedAt: at
        )
        #expect(store.sessions["codex-err"]?.errorMessage == "Usage limit reached")

        // The error turn's own task_complete carries no reply — must NOT clear.
        store.recordCodexTaskComplete(
            sessionId: "codex-err", cwd: "/p", lastAgentMessage: nil,
            transcriptPath: "/tmp/r.jsonl", completedAt: at.addingTimeInterval(1)
        )
        #expect(store.sessions["codex-err"]?.errorMessage == "Usage limit reached")

        // A later turn that actually replies = recovered; clear the banner.
        store.recordCodexTaskComplete(
            sessionId: "codex-err", cwd: "/p", lastAgentMessage: "back online",
            transcriptPath: "/tmp/r.jsonl", completedAt: at.addingTimeInterval(3600)
        )
        #expect(store.sessions["codex-err"]?.errorMessage == nil)
        #expect(store.sessions["codex-err"]?.errorAt == nil)
    }

    @Test func codexErrorLabelMapsKnownCodesThenFallsBack() {
        #expect(SessionStore.codexErrorLabel(
            errorInfo: "usage_limit_exceeded",
            message: "anything"
        ) == "Usage limit reached")
        // Unknown code → fall back to the generic detector on the message.
        #expect(SessionStore.codexErrorLabel(
            errorInfo: "some_future_code",
            message: "503 Service Unavailable from upstream"
        ) == "Service unavailable (503)")
        // Nothing recognizable → generic label, never empty.
        #expect(SessionStore.codexErrorLabel(
            errorInfo: nil,
            message: "weird unparseable failure"
        ) == "Codex error")
    }

    @Test func detectErrorMatchesHitUsageLimitPhrasing() {
        // Codex's exact phrasing uses "hit", not "reached"/"exceeded".
        #expect(SessionStore.detectError(
            in: "You've hit your usage limit. Try again at 7:34 PM."
        ) == "Usage limit reached")
    }

    @Test func detectErrorIgnoresNegatedUsageLimit() {
        // Negated phrasing must NOT raise the banner (Gemini PR review).
        #expect(SessionStore.detectError(
            in: "Your usage limit has not been reached yet."
        ) == nil)
        #expect(SessionStore.detectError(
            in: "Good news: the usage limit was not exceeded this month."
        ) == nil)
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

    @Test @MainActor func userPromptSubmit_clearsStaleAskUQPopup() {
        // Reject-by-new-prompt: user ESC'd the in-terminal AskUQ and typed a
        // new prompt instead of selecting an option. CC does NOT fire
        // PostToolUse for that path, so the only clearing signal is the
        // incoming UserPromptSubmit — without this the popup is stranded
        // until the next Stop (potentially minutes).
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

        store.handleEvent(BridgeEvent(
            bridgeEvent: "UserPromptSubmit",
            sessionId: "s1",
            cwd: "/tmp",
            userPrompt: "actually do this instead"
        ))

        #expect(store.sessions["s1"]?.pendingPermission == nil,
                "UserPromptSubmit must clear a stale AskUQ popup")
        #expect(store.sessions["s1"]?.state == .working,
                "session must drop out of .waiting once the AskUQ clears, otherwise it stays wrongly prioritized in the UI ranking")
        #expect(store.sessions["s1"]?.lastUserPrompt == "actually do this instead")
    }

    @Test @MainActor func userPromptSubmit_doesNotClearBlockingPermission() {
        // Counter-test for the isAskUserQuestion gate: a non-AskUQ blocking
        // PermissionRequest (Bash/Edit/etc.) carries a real socket responder.
        // Clearing it on UserPromptSubmit would leak the bridge socket fd
        // until POLLHUP and drop the user's pending Allow/Deny gesture.
        let store = SessionStore()
        let responder = Box<BridgeResponse>()
        let pending = PendingPermission(
            toolName: "Bash",
            toolInput: ["command": "rm -rf /"],
            cwd: "/tmp",
            responder: { responder.value = $0 }
        )
        store.handleEvent(BridgeEvent(bridgeEvent: "SessionStart", sessionId: "s1", cwd: "/tmp"))
        store.handlePermissionRequest(sessionId: "s1", permission: pending)

        store.handleEvent(BridgeEvent(
            bridgeEvent: "UserPromptSubmit",
            sessionId: "s1",
            cwd: "/tmp",
            userPrompt: "noise"
        ))

        #expect(store.sessions["s1"]?.pendingPermission != nil,
                "blocking PermissionRequest must survive UserPromptSubmit")
        #expect(responder.value == nil,
                "the socket responder must not be called from the clearing path")
    }

    @Test @MainActor func stop_clearsStaleAskUQPopup() {
        // Backstop for UserPromptSubmit: if a turn ends with an AskUQ still
        // pending (no rejection prompt, no PostToolUse fired — e.g. the
        // agent self-cancelled), the popup is unresolvable. Stop catches it.
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

        store.handleEvent(BridgeEvent(bridgeEvent: "Stop", sessionId: "s1", cwd: "/tmp"))

        #expect(store.sessions["s1"]?.pendingPermission == nil,
                "Stop must clear a stale AskUQ popup")
        #expect(store.sessions["s1"]?.state == .idle)
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

    // MARK: - PermissionRiskLevel mapping

    @Test func claudeModeMapping() {
        #expect(PermissionRiskLevel.fromClaudeMode("default") == nil)
        #expect(PermissionRiskLevel.fromClaudeMode("acceptEdits") == .auto)
        #expect(PermissionRiskLevel.fromClaudeMode("bypassPermissions") == .yolo)
        #expect(PermissionRiskLevel.fromClaudeMode("plan") == .plan)
        #expect(PermissionRiskLevel.fromClaudeMode("nonsense") == nil)
    }

    @Test func codexPolicyMapping() {
        // Default (on-request + workspace-write) → no badge
        #expect(PermissionRiskLevel.fromCodex(approvalPolicy: "on-request", sandboxType: "workspace-write") == nil)
        // Read-only is structurally harmless — codex cannot mutate the FS
        // regardless of approval mode, so no badge even with `never`.
        #expect(PermissionRiskLevel.fromCodex(approvalPolicy: "never", sandboxType: "read-only") == nil)
        #expect(PermissionRiskLevel.fromCodex(approvalPolicy: "on-request", sandboxType: "read-only") == nil)
        // Silent edits = .auto
        #expect(PermissionRiskLevel.fromCodex(approvalPolicy: "never", sandboxType: "workspace-write") == .auto)
        // Asks but no sandbox = .auto
        #expect(PermissionRiskLevel.fromCodex(approvalPolicy: "on-request", sandboxType: "danger-full-access") == .auto)
        // Silent + unbounded = .yolo
        #expect(PermissionRiskLevel.fromCodex(approvalPolicy: "never", sandboxType: "danger-full-access") == .yolo)
        // Nil inputs → default-assumption (on-request + workspace-write) → nil
        #expect(PermissionRiskLevel.fromCodex(approvalPolicy: nil, sandboxType: nil) == nil)
    }

    @Test func claudeEventStampsPermissionRisk() {
        let store = SessionStore()
        store.handleEvent(BridgeEvent(bridgeEvent: "SessionStart", sessionId: "s1", cwd: "/tmp"))

        // Default mode = no badge.
        store.handleEvent(BridgeEvent(
            bridgeEvent: "PreToolUse",
            sessionId: "s1",
            toolName: "Bash",
            permissionMode: "default"
        ))
        #expect(store.sessions["s1"]?.permissionRisk == nil)

        // Switch to acceptEdits → .auto badge.
        store.handleEvent(BridgeEvent(
            bridgeEvent: "PreToolUse",
            sessionId: "s1",
            toolName: "Bash",
            permissionMode: "acceptEdits"
        ))
        #expect(store.sessions["s1"]?.permissionRisk == .auto)

        // Switch back to default → badge clears.
        store.handleEvent(BridgeEvent(
            bridgeEvent: "PreToolUse",
            sessionId: "s1",
            toolName: "Bash",
            permissionMode: "default"
        ))
        #expect(store.sessions["s1"]?.permissionRisk == nil)
    }

    @Test func codexEventDoesNotStampViaPermissionMode() {
        // Defensive: codex hook events that happen to carry a permission_mode
        // field (shouldn't happen, but the agent flag gates us) must not
        // pollute the codex permissionRisk path — that lives behind the tailer.
        let store = SessionStore()
        store.handleEvent(BridgeEvent(
            bridgeEvent: "SessionStart",
            agent: .codex,
            sessionId: "s1",
            cwd: "/tmp"
        ))
        store.handleEvent(BridgeEvent(
            bridgeEvent: "PreToolUse",
            agent: .codex,
            sessionId: "s1",
            toolName: "shell",
            permissionMode: "acceptEdits"  // pretend codex sent it
        ))
        #expect(store.sessions["s1"]?.permissionRisk == nil)
    }

    @Test func setCodexPermissionRiskCreatesDetectedSession() {
        let store = SessionStore()
        store.setCodexPermissionRisk(
            sessionId: "codex-1",
            cwd: "/proj",
            transcriptPath: "/tmp/rollout.jsonl",
            risk: .auto
        )
        let session = store.sessions["codex-1"]
        #expect(session?.permissionRisk == .auto)
        #expect(session?.source == .detected)
        #expect(session?.agent == .codex)
        #expect(session?.cwd == "/proj")
    }

    // MARK: - #181 PreCompact/PostCompact trigger tracking

    @Test func preCompactStoresTriggerOnSession() {
        let store = SessionStore()
        store.handleEvent(BridgeEvent(bridgeEvent: "SessionStart", sessionId: "s1", cwd: "/tmp"))
        store.handleEvent(BridgeEvent(
            bridgeEvent: "PreCompact", sessionId: "s1", trigger: "manual"))
        #expect(store.sessions["s1"]?.compactTrigger == "manual")
    }

    @Test func postCompactClearsStoredTrigger() {
        let store = SessionStore()
        store.handleEvent(BridgeEvent(bridgeEvent: "SessionStart", sessionId: "s1", cwd: "/tmp"))
        store.handleEvent(BridgeEvent(
            bridgeEvent: "PreCompact", sessionId: "s1", trigger: "manual"))
        store.handleEvent(BridgeEvent(bridgeEvent: "PostCompact", sessionId: "s1"))
        #expect(store.sessions["s1"]?.compactTrigger == nil)
    }

    @Test func postCompactAfterManualCompact_returnsWorkingSessionToIdle() {
        // /compact submits through UserPromptSubmit on some CC versions,
        // flipping the session to .working; nothing after PostCompact would
        // ever flip it back (no Stop follows a manual compaction).
        let store = SessionStore()
        store.handleEvent(BridgeEvent(bridgeEvent: "SessionStart", sessionId: "s1", cwd: "/tmp"))
        store.handleEvent(BridgeEvent(
            bridgeEvent: "UserPromptSubmit", sessionId: "s1", userPrompt: "/compact"))
        store.handleEvent(BridgeEvent(
            bridgeEvent: "PreCompact", sessionId: "s1", trigger: "manual"))
        store.handleEvent(BridgeEvent(bridgeEvent: "PostCompact", sessionId: "s1"))
        #expect(store.sessions["s1"]?.state == .idle)
    }

    @Test func postCompactAfterAutoCompact_leavesWorkingStateAlone() {
        // Auto-compact happens MID-TURN — the agent keeps working after it,
        // so PostCompact must not flip the state (Stop will, at turn end).
        let store = SessionStore()
        store.handleEvent(BridgeEvent(bridgeEvent: "SessionStart", sessionId: "s1", cwd: "/tmp"))
        store.handleEvent(BridgeEvent(
            bridgeEvent: "UserPromptSubmit", sessionId: "s1", userPrompt: "do stuff"))
        store.handleEvent(BridgeEvent(
            bridgeEvent: "PreCompact", sessionId: "s1", trigger: "auto"))
        store.handleEvent(BridgeEvent(bridgeEvent: "PostCompact", sessionId: "s1"))
        #expect(store.sessions["s1"]?.state == .working)
    }

    @Test func preCompactOnUnknownSessionCreatesIt() {
        // /compact can fire before ZackEyes ever saw the session (app started
        // mid-conversation) — same create-on-first-event contract as PreToolUse.
        let store = SessionStore()
        store.handleEvent(BridgeEvent(
            bridgeEvent: "PreCompact", sessionId: "s9", cwd: "/tmp", trigger: "auto"))
        #expect(store.sessions["s9"]?.compactTrigger == "auto")
    }

    @Test func postCompactOnUnknownSessionMintsIdle() {
        // App restarted while a manual /compact was running: PreCompact died
        // with the old instance, PostCompact arrives for an unknown session
        // with no trigger. Minting the default .working would stick forever
        // (no Stop follows a manual compaction).
        let store = SessionStore()
        store.handleEvent(BridgeEvent(bridgeEvent: "PostCompact", sessionId: "s9", cwd: "/tmp"))
        #expect(store.sessions["s9"]?.state == .idle)
    }

    @Test func postCompactWithUnknownTrigger_stillEndsTheTurn() {
        // Neither payload carried a trigger (older CC / lost PreCompact).
        // Wrongly idling a mid-turn auto compaction self-corrects on the next
        // PreToolUse; NOT idling a finished manual compaction sticks forever —
        // so unknown ends the turn. Only a provably-auto reading leaves the
        // state alone.
        let store = SessionStore()
        store.handleEvent(BridgeEvent(bridgeEvent: "SessionStart", sessionId: "s1", cwd: "/tmp"))
        store.handleEvent(BridgeEvent(
            bridgeEvent: "UserPromptSubmit", sessionId: "s1", userPrompt: "/compact"))
        store.handleEvent(BridgeEvent(bridgeEvent: "PostCompact", sessionId: "s1"))
        #expect(store.sessions["s1"]?.state == .idle)
    }

    @Test func postCompactManual_mirrorsStopTurnEndReset() {
        // PostCompact is the turn terminator for manual /compact, so it must
        // restore Stop's other turn-end guarantees too: isToolRunning off and
        // the stale-AskUQ backstop clear.
        let store = SessionStore()
        store.handleEvent(BridgeEvent(bridgeEvent: "SessionStart", sessionId: "s1", cwd: "/tmp"))
        store.handleEvent(BridgeEvent(bridgeEvent: "PreToolUse", sessionId: "s1", toolName: "Bash"))
        let askUQ = PendingPermission(
            toolName: "AskUserQuestion", toolInput: [:], cwd: "/tmp", responder: { _ in })
        store.handlePermissionRequest(sessionId: "s1", permission: askUQ)
        #expect(store.sessions["s1"]?.state == .waiting)

        store.handleEvent(BridgeEvent(
            bridgeEvent: "PreCompact", sessionId: "s1", trigger: "manual"))
        store.handleEvent(BridgeEvent(bridgeEvent: "PostCompact", sessionId: "s1"))

        #expect(store.sessions["s1"]?.state == .idle)
        #expect(store.sessions["s1"]?.isToolRunning == false)
        #expect(store.sessions["s1"]?.pendingPermission == nil)
    }

    @Test func sessionStartFromCompact_preservesTriggerAndState() {
        // CC fires SessionStart(source:"compact") around the compaction
        // boundary; order vs PostCompact is not guaranteed. The administrative
        // restart must not wipe the in-flight marker (before PostCompact) nor
        // resurrect .working on an already-idled card (after PostCompact).
        let store = SessionStore()
        store.handleEvent(BridgeEvent(bridgeEvent: "SessionStart", sessionId: "s1", cwd: "/tmp"))
        store.handleEvent(BridgeEvent(
            bridgeEvent: "PreCompact", sessionId: "s1", trigger: "manual"))
        store.handleEvent(BridgeEvent(
            bridgeEvent: "SessionStart", sessionId: "s1", cwd: "/tmp", source: "compact"))
        #expect(store.sessions["s1"]?.compactTrigger == "manual")

        store.handleEvent(BridgeEvent(bridgeEvent: "PostCompact", sessionId: "s1"))
        #expect(store.sessions["s1"]?.state == .idle)
        store.handleEvent(BridgeEvent(
            bridgeEvent: "SessionStart", sessionId: "s1", cwd: "/tmp", source: "compact"))
        #expect(store.sessions["s1"]?.state == .idle)
    }

    @Test func sessionStartFresh_doesNotInheritCompactTrigger() {
        // A genuinely new conversation (/clear, startup) must not inherit a
        // stale marker from the session id's previous life.
        let store = SessionStore()
        store.handleEvent(BridgeEvent(bridgeEvent: "SessionStart", sessionId: "s1", cwd: "/tmp"))
        store.handleEvent(BridgeEvent(
            bridgeEvent: "PreCompact", sessionId: "s1", trigger: "manual"))
        store.handleEvent(BridgeEvent(
            bridgeEvent: "SessionStart", sessionId: "s1", cwd: "/tmp", source: "clear"))
        #expect(store.sessions["s1"]?.compactTrigger == nil)
    }

    @Test func stopAndUserPromptSubmit_clearStaleCompactTrigger() {
        // A compaction marker cannot outlive the turn context that created it:
        // if PostCompact was lost, the next turn boundary must drop it so a
        // later trigger-less compaction is never promoted to "manual".
        let store = SessionStore()
        store.handleEvent(BridgeEvent(bridgeEvent: "SessionStart", sessionId: "s1", cwd: "/tmp"))
        store.handleEvent(BridgeEvent(
            bridgeEvent: "PreCompact", sessionId: "s1", trigger: "manual"))
        store.handleEvent(BridgeEvent(bridgeEvent: "Stop", sessionId: "s1"))
        #expect(store.sessions["s1"]?.compactTrigger == nil)

        store.handleEvent(BridgeEvent(
            bridgeEvent: "PreCompact", sessionId: "s1", trigger: "manual"))
        store.handleEvent(BridgeEvent(
            bridgeEvent: "UserPromptSubmit", sessionId: "s1", userPrompt: "next turn"))
        #expect(store.sessions["s1"]?.compactTrigger == nil)
    }

    // MARK: - importDetectedSessions (#83 unchanged-skip guard)

    // #83-1. Re-importing the same DetectedSession (same lastModified) must
    // be a no-op: returns 0 and leaves any enrichment intact.
    @Test func reimportSkipsUnchangedDetectedSession() {
        let store = SessionStore()
        let modDate = Date(timeIntervalSince1970: 1_800_000_000)
        let d = SessionScanner.DetectedSession(
            id: "s1",
            agent: .claude,
            cwd: "/tmp/p",
            lastModified: modDate,
            lastUserPrompt: "original prompt",
            lastAssistantMessage: nil,
            messageCount: 1,
            transcriptPath: "/nonexistent/transcript.jsonl"
        )

        // First import — creates the session
        let first = store.importDetectedSessions([d])
        #expect(first == 1)

        // Simulate enrichment written by another path
        store.sessions["s1"]?.lastAssistantMessage = "enriched"

        // Re-import with same DetectedSession (same lastModified) → skip
        let second = store.importDetectedSessions([d])
        #expect(second == 0)
        #expect(store.sessions["s1"]?.lastAssistantMessage == "enriched",
                "unchanged-skip must preserve enrichment from other paths")
    }

    // #83-2. Re-importing with an updated lastModified must refresh the session
    // and return 1.
    @Test func reimportRefreshesWhenTranscriptMoved() {
        let store = SessionStore()
        let modDate = Date(timeIntervalSince1970: 1_800_000_000)
        let d1 = SessionScanner.DetectedSession(
            id: "s1",
            agent: .claude,
            cwd: "/tmp/p",
            lastModified: modDate,
            lastUserPrompt: "old prompt",
            lastAssistantMessage: nil,
            messageCount: 1,
            transcriptPath: "/nonexistent/transcript.jsonl"
        )
        _ = store.importDetectedSessions([d1])

        let modDate2 = modDate.addingTimeInterval(60)
        let d2 = SessionScanner.DetectedSession(
            id: "s1",
            agent: .claude,
            cwd: "/tmp/p",
            lastModified: modDate2,
            lastUserPrompt: "new prompt",
            lastAssistantMessage: "new reply",
            messageCount: 2,
            transcriptPath: "/nonexistent/transcript.jsonl"
        )
        let second = store.importDetectedSessions([d2])
        #expect(second == 1)
        #expect(store.sessions["s1"]?.lastUserPrompt == "new prompt")
        #expect(store.sessions["s1"]?.lastAssistantMessage == "new reply")
        #expect(store.sessions["s1"]?.lastActiveAt == modDate2)
    }

    // #83-3. importDetectedSessions must never touch a .live session, and
    // must return 0 for it.
    // SessionStart creates sessions with source == .live directly, so no
    // upgradeToLive call needed.
    @Test func reimportNeverTouchesLiveSessions() {
        let store = SessionStore()
        // SessionStart → source == .live
        store.handleEvent(BridgeEvent(bridgeEvent: "SessionStart", sessionId: "s1", cwd: "/tmp/p"))
        #expect(store.sessions["s1"]?.source == .live)

        let modDate = Date(timeIntervalSince1970: 1_800_000_000)
        let d = SessionScanner.DetectedSession(
            id: "s1",
            agent: .claude,
            cwd: "/tmp/p",
            lastModified: modDate,
            lastUserPrompt: "stale",
            lastAssistantMessage: nil,
            messageCount: 1,
            transcriptPath: "/nonexistent/transcript.jsonl"
        )
        let count = store.importDetectedSessions([d])
        #expect(count == 0)
        #expect(store.sessions["s1"]?.lastUserPrompt != "stale",
                "live session must not be overwritten by importDetectedSessions")
    }

    // #83-4. A transcript mtime bump rebuilds the .detected session — the
    // activation cache (claudePid) must survive the rebuild, otherwise the
    // periodic rescan re-runs lsof/OSC2-titling for already-known sessions.
    @Test func reimportPreservesCachedPidOnRefresh() {
        let store = SessionStore()
        let modDate = Date(timeIntervalSince1970: 1_800_000_000)
        let d1 = SessionScanner.DetectedSession(
            id: "s1",
            agent: .claude,
            cwd: "/tmp/p",
            lastModified: modDate,
            lastUserPrompt: "old",
            lastAssistantMessage: nil,
            messageCount: 1,
            transcriptPath: "/nonexistent/transcript.jsonl"
        )
        _ = store.importDetectedSessions([d1])
        // Activation pass cached a pid for this session.
        store.sessions["s1"]?.claudePid = 4242

        let d2 = SessionScanner.DetectedSession(
            id: "s1",
            agent: .claude,
            cwd: "/tmp/p",
            lastModified: modDate.addingTimeInterval(60),
            lastUserPrompt: "new",
            lastAssistantMessage: "reply",
            messageCount: 2,
            transcriptPath: "/nonexistent/transcript.jsonl"
        )
        let count = store.importDetectedSessions([d2])
        #expect(count == 1)
        #expect(store.sessions["s1"]?.lastUserPrompt == "new")
        #expect(store.sessions["s1"]?.claudePid == 4242,
                "refresh must carry the activation cache forward")
    }

}
