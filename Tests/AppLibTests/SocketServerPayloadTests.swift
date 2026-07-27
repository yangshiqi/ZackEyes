import Testing
import Foundation
import Shared
@testable import AppLib
@testable import BridgeLib

/// #200 — a hook payload larger than the server's read cap used to be truncated
/// mid-object, decoded as a fragment (failing), and the socket closed while the
/// bridge was still writing. These drive a real AF_UNIX round-trip because that
/// is where the truncation lived: neither end is wrong in isolation.
@MainActor
struct SocketServerPayloadTests {

    private func withServer(
        _ body: @MainActor (SocketServer, String) async throws -> Void
    ) async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("zackeyes-payload-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let path = dir.appendingPathComponent("s.sock").path
        let server = SocketServer(path: path)
        try server.start()
        defer { server.stop() }
        try await body(server, path)
    }

    /// A `tool_response` of a few hundred KB is ordinary for a Read of a large
    /// file. It must arrive whole.
    @Test func deliversPayloadLargerThanTheOldSixtyFourKiBCap() async throws {
        try await withServer { server, path in
            let received = Box<BridgeEvent>()
            server.setEventHandler { event, _, _ in received.value = event }

            let bulky = String(repeating: "x", count: 300_000)
            let json = """
            {"_bridge_event":"SessionStart","_bridge_agent":"claude",\
            "session_id":"big-1","cwd":"/tmp/big","tool_response":"\(bulky)"}
            """
            var payload = Data(json.utf8)
            payload.append(UInt8(ascii: "\n"))
            #expect(payload.count > 65_536, "fixture must exceed the old cap")

            let sent = await Task.detached { BridgeSocketClient(path: path).sendFireAndForget(data: payload) }.value
            #expect(sent)

            try await waitUntil { received.value != nil }
            #expect(received.value?.sessionId == "big-1")
            #expect(received.value?.cwd == "/tmp/big")
        }
    }

    /// The small path must keep working — the cap change is not a rewrite of the
    /// framing.
    @Test func stillDeliversSmallPayload() async throws {
        try await withServer { server, path in
            let received = Box<BridgeEvent>()
            server.setEventHandler { event, _, _ in received.value = event }

            var payload = Data(#"{"_bridge_event":"Stop","_bridge_agent":"claude","session_id":"s"}"#.utf8)
            payload.append(UInt8(ascii: "\n"))
            let sent = await Task.detached { BridgeSocketClient(path: path).sendFireAndForget(data: payload) }.value
            #expect(sent)

            try await waitUntil { received.value != nil }
            #expect(received.value?.sessionId == "s")
        }
    }

    private func waitUntil(
        timeout: Duration = .seconds(5),
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("timed out waiting for the event to arrive")
    }
}
