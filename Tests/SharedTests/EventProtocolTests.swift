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
    #expect(askUQ.requiresBlockingResponse == true)
    #expect(preBash.requiresBlockingResponse == false)
    #expect(post.requiresBlockingResponse == false)
    #expect(start.requiresBlockingResponse == false)
}
