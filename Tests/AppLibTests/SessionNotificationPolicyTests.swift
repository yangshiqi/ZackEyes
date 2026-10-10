import Testing
import Foundation
import Shared
@testable import AppLib

@MainActor
struct SessionNotificationPolicyTests {
    private func event(_ name: String, fields: String = "") throws -> BridgeEvent {
        let suffix = fields.isEmpty ? "" : ",\(fields)"
        return try JSONDecoder().decode(BridgeEvent.self, from: Data(
            "{\"_bridge_agent\":\"claude\",\"_bridge_event\":\"\(name)\",\"session_id\":\"s\",\"cwd\":\"/tmp\"\(suffix)}".utf8))
    }

    @Test func childStopCannotNotifyParentEvenWhenParentHasWorked() throws {
        let store = SessionStore()
        try store.handleEvent(event("UserPromptSubmit", fields: #""prompt":"work""#))
        let stop = try event("Stop", fields: #""agent_id":"child","last_assistant_message":"child done""#)
        let prior = try #require(store.sessions["s"]?.state)
        store.handleEvent(stop)
        let parent = try #require(store.sessions["s"])
        #expect(parent.state == .working)
        #expect(!SessionNotificationPolicy.shouldNotifyFinished(event: stop, priorState: prior, session: parent))
        let parentStop = try event("Stop", fields: #""last_assistant_message":"parent done""#)
        #expect(SessionNotificationPolicy.shouldNotifyFinished(event: parentStop, priorState: prior, session: parent))
    }

    @Test func failedTurnNotificationUsesErrorDetailsInsteadOfPreviousReply() throws {
        let store = SessionStore()
        try store.handleEvent(event("Stop", fields: #""last_assistant_message":"old reply""#))
        let failure = try event("StopFailure", fields: #""error":"rate_limit","error_details":"Retry after 30 seconds""#)
        store.handleEvent(failure)
        let session = try #require(store.sessions["s"])
        #expect(session.lastAssistantMessage == "old reply")
        #expect(SessionNotificationPolicy.errorDetail(for: session) == "Retry after 30 seconds")
        #expect(!SessionNotificationPolicy.shouldNotifyFinished(event: failure, priorState: .working, session: session))
    }

    @Test func legacyErrorDetailAndFinishGatesRemainCompatible() throws {
        var session = SessionInfo(id: "s", cwd: "/tmp", agent: .claude)
        session.lastAssistantMessage = "legacy API error"
        #expect(SessionNotificationPolicy.errorDetail(for: session) == "legacy API error")
        let stop = try event("Stop")
        #expect(!SessionNotificationPolicy.shouldNotifyFinished(event: stop, priorState: .working, session: session))
        session.toolCallCount = 1
        #expect(SessionNotificationPolicy.shouldNotifyFinished(event: stop, priorState: .waiting, session: session))
        #expect(!SessionNotificationPolicy.shouldNotifyFinished(event: stop, priorState: .idle, session: session))
        var replay = stop
        replay.isReplayed = true
        #expect(!SessionNotificationPolicy.shouldNotifyFinished(event: replay, priorState: .working, session: session))
        session.errorMessage = "API error"
        #expect(!SessionNotificationPolicy.shouldNotifyFinished(event: stop, priorState: .working, session: session))
    }
}
