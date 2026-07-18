import Testing
import Foundation
@testable import Shared

@Test func decodeBridgeEvent_sessionStart() throws {
    let json = """
    {"_bridge_event":"SessionStart","session_id":"abc","hook_event_name":"SessionStart","cwd":"/tmp"}
    """.data(using: .utf8)!
    let event = try JSONDecoder().decode(BridgeEvent.self, from: json)
    #expect(event.bridgeEvent == "SessionStart")
    #expect(event.sessionId == "abc")
    #expect(event.cwd == "/tmp")
    #expect(event.toolName == nil)
}

@Test func decodeBridgeEvent_compactTrigger() throws {
    // #181 — PreCompact/PostCompact carry trigger: "manual" | "auto".
    let json = """
    {"_bridge_event":"PostCompact","session_id":"abc","hook_event_name":"PostCompact","trigger":"manual"}
    """.data(using: .utf8)!
    let event = try JSONDecoder().decode(BridgeEvent.self, from: json)
    #expect(event.trigger == "manual")
}

@Test func decodeBridgeEvent_triggerAbsentIsNil() throws {
    let json = """
    {"_bridge_event":"Stop","session_id":"abc"}
    """.data(using: .utf8)!
    let event = try JSONDecoder().decode(BridgeEvent.self, from: json)
    #expect(event.trigger == nil)
}

@Test func decodeBridgeEvent_nonStringTriggerDoesNotFailEvent() throws {
    // `trigger` is a generic key another agent could emit with any type; a
    // non-string value must degrade to nil, not throw away the whole event
    // (same defensive posture as the _bridge_agent decode).
    let json = """
    {"_bridge_event":"Stop","session_id":"abc","trigger":123}
    """.data(using: .utf8)!
    let event = try JSONDecoder().decode(BridgeEvent.self, from: json)
    #expect(event.bridgeEvent == "Stop")
    #expect(event.trigger == nil)
}

@Test func requiresBlockingResponse_regularPermissionRequestBlocks() {
    let event = BridgeEvent(
        bridgeEvent: "PermissionRequest",
        sessionId: "s1",
        toolName: "Bash"
    )
    #expect(event.requiresBlockingResponse == true,
            "regular permission requests must wait for the app's allow/deny")
}

@Test func requiresBlockingResponse_askUQPermissionRequestDoesNotBlock() {
    // Regression: routing AskUQ PermissionRequest as blocking causes the
    // app's poll loop to fire abandonPermission as soon as the bridge
    // closes the (fire-and-forget) connection — which clears the popup
    // before the user can interact. AskUQ uses the PreToolUse popup
    // surface and CC's terminal UI in parallel; both surfaces are driven
    // outside this PermissionRequest event.
    let event = BridgeEvent(
        bridgeEvent: "PermissionRequest",
        sessionId: "s1",
        toolName: "AskUserQuestion"
    )
    #expect(event.requiresBlockingResponse == false,
            "AskUQ PermissionRequest must not block — would trigger abandonPermission")
}

@Test func requiresBlockingResponse_otherEventsDoNotBlock() {
    for ev in ["PreToolUse", "PostToolUse", "SessionStart", "Stop"] {
        let event = BridgeEvent(bridgeEvent: ev, sessionId: "s1")
        #expect(event.requiresBlockingResponse == false,
                "\(ev) must be fire-and-forget")
    }
}

@Test func decodeBridgeEvent_permissionRequest() throws {
    let json = """
    {"_bridge_event":"PermissionRequest","session_id":"abc","hook_event_name":"PermissionRequest","cwd":"/tmp","tool_name":"Bash","tool_input":{"command":"rm -rf /tmp/test"}}
    """.data(using: .utf8)!
    let event = try JSONDecoder().decode(BridgeEvent.self, from: json)
    #expect(event.bridgeEvent == "PermissionRequest")
    #expect(event.toolName == "Bash")
    #expect(event.toolInput != nil)
}

@Test func encodePermissionResponse_allow() throws {
    let response = PermissionResponse.allow(message: "User approved via ZackEyes")
    let data = try JSONEncoder().encode(response)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    let hookOutput = json["hookSpecificOutput"] as! [String: Any]
    let decision = hookOutput["decision"] as! [String: Any]
    #expect(decision["behavior"] as? String == "allow")
    #expect(decision["message"] as? String == "User approved via ZackEyes")
    #expect(hookOutput["hookEventName"] as? String == "PermissionRequest")
}

@Test func encodePermissionResponse_deny() throws {
    let response = PermissionResponse.deny(message: "User denied")
    let data = try JSONEncoder().encode(response)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    let hookOutput = json["hookSpecificOutput"] as! [String: Any]
    let decision = hookOutput["decision"] as! [String: Any]
    #expect(decision["behavior"] as? String == "deny")
}

@Test func sessionState_allCases() {
    #expect(SessionState.idle.rawValue == "idle")
    #expect(SessionState.working.rawValue == "working")
    #expect(SessionState.waiting.rawValue == "waiting")
    #expect(SessionState.stopped.rawValue == "stopped")
}

@Test func decodeBridgeEvent_unknownFieldsIgnored() throws {
    let json = """
    {"_bridge_event":"PreToolUse","session_id":"s1","hook_event_name":"PreToolUse","cwd":"/tmp","tool_name":"Read","unknown_field":"ignored"}
    """.data(using: .utf8)!
    let event = try JSONDecoder().decode(BridgeEvent.self, from: json)
    #expect(event.bridgeEvent == "PreToolUse")
}

@Test func encodePreToolUseHookResponse_askUQAnswers() throws {
    let questions: [[String: Any]] = [[
        "question": "Pick a color",
        "header": "color",
        "multiSelect": false,
        "options": [
            ["label": "red", "description": "warm"],
            ["label": "blue", "description": "cool"],
        ],
    ]]
    let answers = ["Pick a color": "red"]
    let response = PreToolUseHookResponse.askUQAnswers(
        questions: questions, answers: answers
    )
    let data = try JSONEncoder().encode(response)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    let hookOutput = json["hookSpecificOutput"] as! [String: Any]
    #expect(hookOutput["hookEventName"] as? String == "PreToolUse")
    #expect(hookOutput["permissionDecision"] as? String == "allow")
    let updated = hookOutput["updatedInput"] as! [String: Any]
    let returnedAnswers = updated["answers"] as! [String: String]
    #expect(returnedAnswers["Pick a color"] == "red")
}

@Test func bridgeResponse_encodesPermissionVariant() throws {
    let r: BridgeResponse = .permission(.allow(message: "ok"))
    let data = try r.encoded()
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    let hookOutput = json["hookSpecificOutput"] as! [String: Any]
    #expect(hookOutput["hookEventName"] as? String == "PermissionRequest")
}

@Test func bridgeResponse_encodesPreToolUseVariant() throws {
    let r: BridgeResponse = .preToolUse(
        .askUQAnswers(questions: [], answers: ["q": "a"])
    )
    let data = try r.encoded()
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    let hookOutput = json["hookSpecificOutput"] as! [String: Any]
    #expect(hookOutput["hookEventName"] as? String == "PreToolUse")
}

@Test func requiresBlockingResponse_matrix() {
    let perm = BridgeEvent(bridgeEvent: "PermissionRequest", toolName: "Bash")
    let askUQ = BridgeEvent(bridgeEvent: "PreToolUse", toolName: "AskUserQuestion")
    let preBash = BridgeEvent(bridgeEvent: "PreToolUse", toolName: "Bash")
    let post = BridgeEvent(bridgeEvent: "PostToolUse", toolName: "AskUserQuestion")
    let start = BridgeEvent(bridgeEvent: "SessionStart")
    #expect(perm.requiresBlockingResponse == true)
    // Path 2: AskUQ no longer blocks — bridge fires-and-forgets so CC's
    // own terminal AskUQ UI runs in parallel with the popup.
    #expect(askUQ.requiresBlockingResponse == false)
    #expect(preBash.requiresBlockingResponse == false)
    #expect(post.requiresBlockingResponse == false)
    #expect(start.requiresBlockingResponse == false)
}

// MARK: - AgentKind / agent field

@Test func decodeBridgeEvent_explicitCodexAgent() throws {
    let json = """
    {"_bridge_event":"PreToolUse","_bridge_agent":"codex","session_id":"s","cwd":"/tmp","tool_name":"Bash"}
    """.data(using: .utf8)!
    let event = try JSONDecoder().decode(BridgeEvent.self, from: json)
    #expect(event.agent == .codex)
}

@Test func decodeBridgeEvent_explicitClaudeAgent() throws {
    let json = """
    {"_bridge_event":"PreToolUse","_bridge_agent":"claude","session_id":"s"}
    """.data(using: .utf8)!
    let event = try JSONDecoder().decode(BridgeEvent.self, from: json)
    #expect(event.agent == .claude)
}

/// Legacy bridge entries (pre-agent flag) omit `_bridge_agent` entirely. The
/// decoder must default to `.claude` so existing installs keep working
/// between an app upgrade and the next HookInstaller reinstall sweep.
@Test func decodeBridgeEvent_missingAgentDefaultsToClaude() throws {
    let json = """
    {"_bridge_event":"SessionStart","session_id":"s","cwd":"/tmp"}
    """.data(using: .utf8)!
    let event = try JSONDecoder().decode(BridgeEvent.self, from: json)
    #expect(event.agent == .claude)
}

@Test func encodeDecodeBridgeEvent_agentRoundTrip() throws {
    let original = BridgeEvent(bridgeEvent: "PreToolUse", agent: .codex, sessionId: "s")
    let data = try JSONEncoder().encode(original)
    // Encoded JSON must use the `_bridge_agent` JSON key.
    let raw = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(raw["_bridge_agent"] as? String == "codex")

    let decoded = try JSONDecoder().decode(BridgeEvent.self, from: data)
    #expect(decoded.agent == .codex)
    #expect(decoded.sessionId == "s")
}

// MARK: - #89 isReplayed

@Test func isReplayedDefaultsFalseWhenAbsent() throws {
    let json = #"{"_bridge_event":"Stop","session_id":"s1"}"#
    let event = try JSONDecoder().decode(BridgeEvent.self, from: Data(json.utf8))
    #expect(event.isReplayed == false)
}

@Test func isReplayedDecodesTrue() throws {
    let json = #"{"_bridge_event":"Stop","session_id":"s1","_bridge_replayed":true}"#
    let event = try JSONDecoder().decode(BridgeEvent.self, from: Data(json.utf8))
    #expect(event.isReplayed == true)
}
