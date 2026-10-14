import Testing
import Foundation
import Shared
@testable import AppLib

@MainActor
struct AskUQConcurrentTests {
    @Test func completionPrefersExactIDOverEarlierUncorrelatedNotice() {
        let store = SessionStore()
        let notice = PendingPermission(toolName: "AskUserQuestion", toolInput: [:], cwd: "/tmp", responder: { _ in })
        let response = Box<BridgeResponse>()
        let live = PendingPermission(toolName: "AskUserQuestion",
            toolInput: ["questions": [["question": "Live?", "options": [["label": "A"]]]]],
            cwd: "/tmp", responder: { response.value = $0 }, answerableFromNotch: true, toolUseId: "live-call")
        store.handlePermissionRequest(sessionId: "s1", permission: notice)
        store.handlePermissionRequest(sessionId: "s1", permission: live)
        store.handleEvent(BridgeEvent(bridgeEvent: "PostToolUse", sessionId: "s1",
            toolName: "AskUserQuestion", toolUseId: "live-call"))
        #expect(store.sessions["s1"]?.pendingPermission?.id == notice.id)
        guard case .deferToTerminal = response.value else {
            Issue.record("An uncorrelated notice consumed the live request's completion")
            return
        }
    }

    @Test func compactRestartDoesNotLeaveAnEmptyQueueWaiting() {
        let store = SessionStore()
        let response = Box<BridgeResponse>()
        let request = PendingPermission(toolName: "AskUserQuestion",
            toolInput: ["questions": [["question": "Which?", "options": [["label": "A"]]]]],
            cwd: "/tmp", responder: { response.value = $0 }, answerableFromNotch: true)
        store.handlePermissionRequest(sessionId: "s1", permission: request)
        store.handleEvent(BridgeEvent(bridgeEvent: "SessionStart", sessionId: "s1", source: "compact"))
        #expect(store.sessions["s1"]?.pendingPermissions.isEmpty == true)
        #expect(store.sessions["s1"]?.state == .working)
    }

    @Test func completionWithoutIDClearsANoticeWithAnObservedID() {
        let store = SessionStore()
        let request = PendingPermission(toolName: "AskUserQuestion", toolInput: [:], cwd: "/tmp",
            responder: { _ in }, toolUseId: "notice-call")
        store.handlePermissionRequest(sessionId: "s1", permission: request)
        store.handleEvent(BridgeEvent(bridgeEvent: "PostToolUse", sessionId: "s1", toolName: "AskUserQuestion"))
        #expect(store.sessions["s1"]?.pendingPermissions.isEmpty == true)
    }

    @Test func completedAnsweredQuestionDoesNotDeferItsWaitingSibling() {
        let store = SessionStore()
        let firstResponse = Box<BridgeResponse>()
        let secondResponse = Box<BridgeResponse>()
        func question(_ text: String, response: Box<BridgeResponse>) -> PendingPermission {
            PendingPermission(toolName: "AskUserQuestion",
                toolInput: ["questions": [["question": text, "options": [["label": "A"]]]]],
                cwd: "/tmp", responder: { response.value = $0 }, answerableFromNotch: true)
        }
        let first = question("First?", response: firstResponse)
        let second = question("Second?", response: secondResponse)
        store.handlePermissionRequest(sessionId: "s1", permission: first)
        store.handlePermissionRequest(sessionId: "s1", permission: second)
        #expect(store.submitAskUQAnswer(sessionId: "s1", requestId: first.id, answers: ["First?": "A"]))
        store.handleEvent(BridgeEvent(bridgeEvent: "PostToolUse", sessionId: "s1",
            toolName: "AskUserQuestion", toolUseId: "first-call"))
        #expect(secondResponse.value == nil)
        #expect(store.sessions["s1"]?.pendingPermission?.id == second.id)
        store.deferAskUQToTerminal(sessionId: "s1", requestId: second.id)
    }
}
