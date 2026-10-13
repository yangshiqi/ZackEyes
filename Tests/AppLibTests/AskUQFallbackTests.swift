import Testing
import Foundation
import Shared
@testable import AppLib
import BridgeLib

@MainActor
struct AskUQFallbackTests {
    @Test func unansweredQuestionTimeoutReleasesBridge() async throws {
        let store = SessionStore()
        let response = Box<BridgeResponse>()
        let request = pending([["question": "Which?", "options": [["label": "A"]]]], response: response)
        store.handlePermissionRequest(sessionId: "s1", permission: request)
        store.startAskUQTimeout(sessionId: "s1", requestId: request.id, timeout: .milliseconds(10))
        let deadline = ContinuousClock.now + .seconds(10)
        while response.value == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard case .deferToTerminal = response.value else {
            Issue.record("Answer timeout did not release the bridge")
            return
        }
        #expect(store.sessions["s1"]?.pendingPermissions.isEmpty == true)
    }

    @Test func replacedTimeoutRemainsCancellable() async throws {
        let store = SessionStore()
        let response = Box<BridgeResponse>()
        let request = pending([["question": "Which?", "options": [["label": "A"]]]], response: response)
        store.handlePermissionRequest(sessionId: "s1", permission: request)
        store.startAskUQTimeout(sessionId: "s1", requestId: request.id, timeout: .seconds(1))
        store.startAskUQTimeout(sessionId: "s1", requestId: request.id, timeout: .milliseconds(100))
        // Let the cancelled predecessor wake before cancelling its replacement.
        try await Task.sleep(for: .milliseconds(10))
        store.cancelAskUQTimeout(requestId: request.id)
        try await Task.sleep(for: .milliseconds(150))
        #expect(response.value == nil)
        #expect(store.sessions["s1"]?.pendingPermissions.count == 1)
        store.deferAskUQToTerminal(sessionId: "s1", requestId: request.id)
    }

    private func pending(_ questions: [[String: Any]], response: Box<BridgeResponse>) -> PendingPermission {
        PendingPermission(toolName: "AskUserQuestion", toolInput: ["questions": questions],
            cwd: "/tmp", responder: { response.value = $0 }, answerableFromNotch: true)
    }

    @Test func unsupportedQuestionsCannotOfferNotchAnswers() {
        let fixtures: [[[String: Any]]] = [
            [],
            [["question": "Which?", "options": []]],
            [["question": "Which?", "options": [["label": "A"], ["description": "Missing label"]]]],
            [["question": "Which?", "options": [["label": "A"], ["label": "A"]]]],
            [["question": "Which?", "options": [["label": "A"]]],
             ["question": "Which?", "options": [["label": "B"]]]],
            [["question": "Which?", "multiSelect": true, "options": [["label": "A, B"], ["label": "C"]]]],
            [["question": "Which?", "options": [["label": "A"]]], ["options": [["label": "B"]]]],
            [["question": "Which?", "options": [["label": "A", "preview": "<html>Design A</html>"], ["label": "B"]]]],
            [["question": "Which?", "options": [["label": "A", "markdown": "## Design A"], ["label": "B"]]]],
            [["question": "Which?", "context": "Details needed to choose", "options": [["label": "A"]]]],
        ]
        for questions in fixtures {
            let response = Box<BridgeResponse>()
            let request = pending(questions, response: response)
            #expect(!request.answerableFromNotch, "Unsupported questions must go straight to the terminal")
        }
    }

    @Test func failedSubmitReleasesBridgeBeforeTerminalJump() {
        let store = SessionStore()
        let response = Box<BridgeResponse>()
        let request = pending([["question": "Which?", "options": [["label": "A"], ["label": "B"]]]], response: response)
        store.handlePermissionRequest(sessionId: "s1", permission: request)
        let viewModel = NotchViewModel(sessionStore: store)
        #expect(!viewModel.submitAskUQAnswer(sessionId: "s1", requestId: request.id, answers: ["Which?": "Z"]))
        guard case .deferToTerminal = response.value else {
            Issue.record("Failed submit left Claude waiting on the bridge")
            return
        }
        #expect(store.sessions["s1"]?.pendingPermissions.isEmpty == true)
    }

    @Test func invalidMultiSelectDoesNotDropEmptyOrDuplicateChoices() {
        for answer in ["A,", "A,,B", "A,A"] {
            let store = SessionStore()
            let response = Box<BridgeResponse>()
            let request = pending([["question": "Which?", "multiSelect": true,
                "options": [["label": "A"], ["label": "B"]]]], response: response)
            store.handlePermissionRequest(sessionId: "s1", permission: request)
            #expect(!store.submitAskUQAnswer(sessionId: "s1", requestId: request.id, answers: ["Which?": answer]))
            #expect(response.value == nil)
        }
    }
}
