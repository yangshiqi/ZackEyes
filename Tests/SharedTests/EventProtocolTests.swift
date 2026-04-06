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
