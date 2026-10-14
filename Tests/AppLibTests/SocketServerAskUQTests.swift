import Testing
import Foundation
import Shared
import BridgeLib
@testable import AppLib

@MainActor
struct SocketServerAskUQTests {
    @Test(arguments: [true, false])
    func questionRoundTrip(answerFromNotch: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ze-q-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("s.sock").path
        let server = SocketServer(path: path)
        let receivedId = Box<UUID>()
        let abandoned = Box<UUID>()
        server.setPermissionAbandonedHandler { _, id in abandoned.value = id }
        server.setEventHandler { event, responder, id in
            #expect(event.toolName == "AskUserQuestion")
            #expect(responder != nil)
            receivedId.value = id
            if answerFromNotch {
                responder?(.preToolUse(.askUQAnswers(
                    questions: [["question": "Which?", "options": [["label": "A"]]]],
                    answers: ["Which?": "A"])))
            } else {
                responder?(.deferToTerminal)
            }
        }
        try server.start()
        defer { server.stop() }
        let payload = Data("""
        {"_bridge_event":"PreToolUse","_bridge_agent":"claude","session_id":"s1","tool_name":"AskUserQuestion"}

        """.utf8)
        let response = await Task.detached {
            BridgeSocketClient(path: path).sendAndWaitForResponse(data: payload, timeoutSeconds: 2)
        }.value
        #expect(receivedId.value != nil)
        #expect(abandoned.value == nil)
        if answerFromNotch {
            let decoded = try JSONDecoder().decode(PreToolUseHookResponse.self, from: #require(response))
            #expect(decoded.hookSpecificOutput.hookEventName == "PreToolUse")
            #expect(decoded.hookSpecificOutput.updatedInput?["answers"]?.value as? [String: String] == ["Which?": "A"])
        } else {
            #expect(response == nil, "Terminal fallback must close without writing a payload")
        }
    }
}
