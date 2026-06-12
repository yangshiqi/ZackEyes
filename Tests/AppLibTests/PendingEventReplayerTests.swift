import Testing
import Foundation
import Shared
@testable import AppLib

struct PendingEventReplayerTests {

    private func makeTmpDir() throws -> URL {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        return tmpDir
    }

    /// Write a spool file the way PendingEventQueue would name it.
    private func writePending(
        dir: URL, msTimestamp: Int, sessionId: String, body: String? = nil
    ) throws {
        let payload = body ?? #"{"_bridge_event":"Stop","session_id":"\#(sessionId)"}"#
        let name = "\(msTimestamp)-123-\(UUID().uuidString).json"
        try payload.write(
            to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    @Test func replaysInTimestampOrderThenDeletes() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let now = Date(timeIntervalSince1970: 1_700_000_100)
        let baseMs = 1_700_000_000_000
        try writePending(dir: tmpDir, msTimestamp: baseMs + 2000, sessionId: "third")
        try writePending(dir: tmpDir, msTimestamp: baseMs, sessionId: "first")
        try writePending(dir: tmpDir, msTimestamp: baseMs + 1000, sessionId: "second")

        var seen: [String] = []
        let replayer = PendingEventReplayer(directory: tmpDir.path)
        let count = replayer.replayAll(now: now) { seen.append($0.sessionId ?? "?") }

        #expect(count == 3)
        #expect(seen == ["first", "second", "third"])
        #expect((try? FileManager.default.contentsOfDirectory(atPath: tmpDir.path))?.isEmpty == true)
    }

    @Test func expiredFilesDeletedWithoutReplay() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let now = Date(timeIntervalSince1970: 1_700_100_000)
        let staleMs = Int((now.timeIntervalSince1970 - 25 * 3600) * 1000)  // 25h old
        try writePending(dir: tmpDir, msTimestamp: staleMs, sessionId: "stale")

        var seen = 0
        let replayer = PendingEventReplayer(directory: tmpDir.path, maxAge: 24 * 3600)
        let count = replayer.replayAll(now: now) { _ in seen += 1 }

        #expect(count == 0)
        #expect(seen == 0)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: tmpDir.path))?.isEmpty == true)
    }

    @Test func malformedFilesDeletedSilently() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let now = Date(timeIntervalSince1970: 1_700_000_100)
        try writePending(
            dir: tmpDir, msTimestamp: 1_700_000_000_000,
            sessionId: "x", body: "{not json")

        var seen = 0
        let count = PendingEventReplayer(directory: tmpDir.path)
            .replayAll(now: now) { _ in seen += 1 }

        #expect(count == 0 && seen == 0)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: tmpDir.path))?.isEmpty == true)
    }

    @Test func unparseableFilenamePrefixJsonIsDeleted() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        try "{}".write(
            to: tmpDir.appendingPathComponent("garbage.json"),
            atomically: true, encoding: .utf8)

        let count = PendingEventReplayer(directory: tmpDir.path)
            .replayAll(now: Date()) { _ in }

        #expect(count == 0)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: tmpDir.path))?.isEmpty == true)
    }

    @Test func replayedEventsCarryIsReplayedFlag() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let now = Date(timeIntervalSince1970: 1_700_000_100)
        try writePending(dir: tmpDir, msTimestamp: 1_700_000_000_000, sessionId: "s1")

        var flags: [Bool] = []
        _ = PendingEventReplayer(directory: tmpDir.path)
            .replayAll(now: now) { flags.append($0.isReplayed) }

        #expect(flags == [true])
    }

    @Test func nonJsonFilesAreLeftAlone() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        try "junk".write(
            to: tmpDir.appendingPathComponent(".DS_Store"), atomically: true, encoding: .utf8)

        let count = PendingEventReplayer(directory: tmpDir.path)
            .replayAll(now: Date(timeIntervalSince1970: 1)) { _ in }

        #expect(count == 0)
        #expect(FileManager.default.fileExists(atPath: tmpDir.appendingPathComponent(".DS_Store").path))
    }

    @Test func missingDirectoryIsANoOp() {
        let replayer = PendingEventReplayer(
            directory: "/nonexistent/zackeyes-test-\(UUID().uuidString)")
        let count = replayer.replayAll(now: Date()) { _ in }
        #expect(count == 0)
    }
}
