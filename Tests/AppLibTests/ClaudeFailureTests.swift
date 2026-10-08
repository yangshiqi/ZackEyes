import Foundation
import Testing
import Shared
@testable import AppLib

@MainActor
struct ClaudeFailureTests {
    private func send(_ type: String, _ fields: String = "", to store: SessionStore) throws {
        let text = "{\"_bridge_event\":\"\(type)\",\"session_id\":\"s\"\(fields.isEmpty ? "" : "," + fields)}"
        store.handleEvent(try JSONDecoder().decode(BridgeEvent.self, from: Data(text.utf8)))
    }

    @Test func parallelToolCompletionAndFailureKeepParentTurnWorking() throws {
        let store = SessionStore()
        try send("PreToolUse", #""tool_name":"Read","tool_use_id":"a""#, to: store)
        try send("PreToolUse", #""tool_name":"Bash","tool_use_id":"b""#, to: store)
        try send("PreToolUse", #""tool_name":"Read","tool_use_id":"a""#, to: store)
        #expect(store.sessions["s"]?.toolCallCount == 2)
        try send("PostToolUse", #""tool_name":"Bash","tool_use_id":"b""#, to: store)
        #expect(store.sessions["s"]?.isToolRunning == true)
        #expect(store.sessions["s"]?.currentToolName == "Read")
        try send("PostToolUseFailure", #""tool_name":"Read","tool_use_id":"a","error":"file not found","is_interrupt":false"#, to: store)
        #expect(store.sessions["s"]?.isToolRunning == false)
        #expect(store.sessions["s"]?.state == .working)
        #expect(store.sessions["s"]?.errorMessage == nil)
        try send("Stop", to: store)
        try send("PostToolUseFailure", #""tool_use_id":"a","error":"late duplicate""#, to: store)
        #expect(store.sessions["s"]?.state == .idle)
    }

    @Test func failedTurnUsesStructuredReasonAndDoesNotReplaceConversationalReply() throws {
        let store = SessionStore()
        try send("Stop", #""last_assistant_message":"Earlier conversational reply""#, to: store)
        try send("UserPromptSubmit", to: store)
        try send("PreToolUse", #""tool_name":"Read","tool_use_id":"a""#, to: store)
        try send("StopFailure", #""error":"rate_limit","error_details":"429 Too Many Requests","last_assistant_message":"API Error: Rate limit reached""#, to: store)
        #expect(store.sessions["s"]?.state == .idle)
        #expect(store.sessions["s"]?.isToolRunning == false)
        #expect(store.sessions["s"]?.errorMessage == "Rate limit reached")
        #expect(store.sessions["s"]?.errorAt != nil)
        #expect(store.sessions["s"]?.lastAssistantMessage == "Earlier conversational reply")
        try send("UserPromptSubmit", to: store)
        #expect(store.sessions["s"]?.errorMessage == nil)
    }

    @Test func childStopAndFailureDoNotCompleteParentTurn() throws {
        let store = SessionStore()
        try send("PreToolUse", #""tool_name":"Read","tool_use_id":"a""#, to: store)
        for type in ["Stop", "StopFailure", "PostToolUseFailure"] {
            try send(type, #""agent_id":"child","tool_use_id":"child-call","error":"rate_limit","last_assistant_message":"child reply""#, to: store)
            #expect(store.sessions["s"]?.state == .working)
            #expect(store.sessions["s"]?.isToolRunning == true)
            #expect(store.sessions["s"]?.lastAssistantMessage == nil)
            #expect(store.sessions["s"]?.errorMessage == nil)
        }
    }

    @Test func installerAddsOnlyObservationHooksAndPreservesUnrelatedSettings() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = dir.appendingPathComponent("settings.json")
        let original = #"{"permissions":{"allow":["Read"]},"theme":"dark","enabledPlugins":{"p":true},"hooks":{"StopFailure":[{"hooks":[{"type":"command","command":"echo custom"}]}]}}"#
        try Data(original.utf8).write(to: settings)
        try HookInstaller(settingsPath: settings.path, bridgePath: "/test/zackeyes/bridge").installHooks()
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
        #expect(json["theme"] as? String == "dark")
        #expect((json["permissions"] as? [String: Any])?["allow"] as? [String] == ["Read"])
        #expect((json["enabledPlugins"] as? [String: Bool])?["p"] == true)
        let hooks = try #require(json["hooks"] as? [String: [[String: Any]]])
        for type in ["PostToolUseFailure", "StopFailure", "PostModelSwitch"] {
            let entries = try #require(hooks[type])
            let commands = entries.flatMap { $0["hooks"] as? [[String: Any]] ?? [] }.compactMap { $0["command"] as? String }
            #expect(commands.contains { $0.contains("zackeyes") && $0.contains("--agent claude") })
            #expect(!BridgeEvent(bridgeEvent: type).requiresBlockingResponse)
        }
        let backups = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("settings.json.backup.") }
        #expect(backups.count == 1)
        #expect(try Data(contentsOf: #require(backups.first)) == Data(original.utf8))
    }
    @Test func failedTurnAnswersEachPendingApprovalAndStaysIdle() throws {
        let store = SessionStore()
        let answers = Box<Int>(); answers.value = 0
        for _ in 0..<2 {
            store.handlePermissionRequest(sessionId: "s", permission: PendingPermission(
                toolName: "Read", toolInput: [:], cwd: nil, responder: { response in
                    if case .permission(let result) = response {
                        #expect(result.hookSpecificOutput.decision.behavior == "deny")
                    }
                    answers.value = (answers.value ?? 0) + 1
                }))
        }
        try send("StopFailure", #""error":"unknown""#, to: store)
        #expect(answers.value == 2)
        #expect(store.sessions["s"]?.pendingPermissions.isEmpty == true)
        #expect(store.sessions["s"]?.state == .idle)
        #expect(store.sessions["s"]?.errorDetail == "API request failed")
    }

    @Test func failureMetadataSurvivesReplayAndNeverBreaksApprovalDecoding() throws {
        let data = Data(#"{"_bridge_event":"StopFailure","session_id":"s","error":"server_error","error_details":"500 Internal Server Error","is_interrupt":true}"#.utf8)
        let decoded = try JSONDecoder().decode(BridgeEvent.self, from: data)
        let replayed = try JSONDecoder().decode(BridgeEvent.self, from: JSONEncoder().encode(decoded))
        #expect(replayed.hookError == "server_error")
        #expect(replayed.errorDetails == "500 Internal Server Error")
        #expect(replayed.isInterrupt == true)
        let approval = try JSONDecoder().decode(BridgeEvent.self, from: Data(#"{"_bridge_event":"PermissionRequest","session_id":"s","error":42,"error_details":{},"effort":[],"is_interrupt":"false"}"#.utf8))
        #expect(approval.requiresBlockingResponse)
    }

}
