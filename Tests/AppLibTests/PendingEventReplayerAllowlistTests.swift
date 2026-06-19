import Testing
import Foundation
@testable import AppLib
import Shared

/// #127 / F-012: the read side must enforce the same replayable-event allowlist
/// the write side uses, so a planted spool file can't inject arbitrary events.
struct PendingEventReplayerAllowlistTests {

    private func makePendingDir() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("pending")
        try FileManager.default.createDirectory(atPath: dir.path, withIntermediateDirectories: true)
        return dir.path
    }

    @Test func replay_skipsNonAllowlistedEvent() throws {
        let dir = try makePendingDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let now = Date()

        func plant(_ event: String) throws {
            let data = try JSONEncoder().encode(BridgeEvent(bridgeEvent: event, sessionId: "s1"))
            let name = "\(Int(now.timeIntervalSince1970 * 1000))-1-\(UUID().uuidString).json"
            try data.write(to: URL(fileURLWithPath: dir + "/" + name))
        }
        try plant("PermissionRequest")   // not replayable — must be skipped
        try plant("SessionStart")         // replayable — must be handled

        var seen: [String] = []
        let count = PendingEventReplayer(directory: dir).replayAll(now: now) { seen.append($0.bridgeEvent) }

        #expect(count == 1)
        #expect(seen == ["SessionStart"])
    }
}
