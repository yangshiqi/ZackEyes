import Testing
import Foundation
@testable import BridgeLib

struct PendingEventQueueTests {

    private func makeTmpDir() throws -> URL {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        return tmpDir
    }

    private func files(in dir: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()) ?? []
    }

    @Test func eligibleEventIsSpooled() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let dir = tmpDir.appendingPathComponent("pending")
        let queue = PendingEventQueue(directory: dir.path)
        let payload = Data(#"{"_bridge_event":"Stop","session_id":"s1"}"#.utf8)

        queue.enqueueIfEligible(event: "Stop", payload: payload)

        let names = files(in: dir)
        #expect(names.count == 1)
        // <unix-ms>-<pid>-<uuid>.json
        #expect(names[0].hasSuffix(".json"))
        #expect(names[0].split(separator: "-").count >= 3)
        let written = try Data(contentsOf: dir.appendingPathComponent(names[0]))
        #expect(written == payload)
    }

    @Test func ineligibleEventsAreNotSpooled() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let dir = tmpDir.appendingPathComponent("pending")
        let queue = PendingEventQueue(directory: dir.path)
        let payload = Data("{}".utf8)

        for event in ["StatusLine", "PermissionRequest", "PreToolUse", "PostToolUse"] {
            queue.enqueueIfEligible(event: event, payload: payload)
        }

        // Directory is never even created for ineligible events.
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test func capPrunesOldestBeyondMaxCount() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let dir = tmpDir.appendingPathComponent("pending")
        let queue = PendingEventQueue(directory: dir.path, maxCount: 3)
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        for i in 0..<5 {
            queue.enqueueIfEligible(
                event: "Stop",
                payload: Data("{\"n\":\(i)}".utf8),
                now: base.addingTimeInterval(Double(i))
            )
        }

        let names = files(in: dir)
        #expect(names.count == 3)
        // Filename sort is chronological (fixed-width ms prefix) — the
        // oldest timestamp must be among the evicted.
        let survivingPrefixes = names.compactMap { $0.split(separator: "-").first }
        let expectedOldest = String(Int(base.timeIntervalSince1970 * 1000))
        #expect(!survivingPrefixes.contains(Substring(expectedOldest)))
    }

    @Test func spoolFailureIsSilent() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        // Point the queue at a path occupied by a regular FILE — directory
        // creation and the write both fail; enqueue must not throw or crash.
        let blocked = tmpDir.appendingPathComponent("blocked")
        try "x".write(to: blocked, atomically: true, encoding: .utf8)
        let queue = PendingEventQueue(directory: blocked.path)

        queue.enqueueIfEligible(event: "Stop", payload: Data("{}".utf8))

        let attrs = try FileManager.default.attributesOfItem(atPath: blocked.path)
        #expect((attrs[.type] as? FileAttributeType) == .typeRegular)  // untouched
    }

    @Test func sessionLifecycleWhitelistIsExact() {
        #expect(PendingEventQueue.replayableEvents == [
            "SessionStart", "SessionEnd", "Stop", "UserPromptSubmit",
            "Notification", "PreCompact", "PostCompact",
            "SubagentStart", "SubagentStop",
        ])
    }
}
