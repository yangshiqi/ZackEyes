import Testing
import Foundation
@testable import AppLib
import Shared

/// Coverage for the SessionScanner's Codex adapter and the mixed scan path
/// that surfaces both Claude and Codex sessions in one sorted list.
struct SessionScannerTests {

    private func makeTmpDir() throws -> URL {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        return tmpDir
    }

    // MARK: - Filename UUID extraction

    @Test func extractCodexSessionId_canonicalUUID() {
        let id = SessionScanner.extractCodexSessionId(
            fromFilename: "rollout-2026-05-03T14-27-59-019dec85-b760-71f2-bca7-b1c463f0d36e.jsonl"
        )
        #expect(id == "019dec85-b760-71f2-bca7-b1c463f0d36e")
    }

    @Test func extractCodexSessionId_rejectsTooShortName() {
        // Truncated filename — last 5 dash-joined groups won't sum to 36 chars.
        let id = SessionScanner.extractCodexSessionId(fromFilename: "rollout-bogus.jsonl")
        #expect(id == nil)
    }

    // MARK: - Codex JSONL parsing

    @Test func scanCodex_parsesSessionMetaAndUserMessage() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Claude tree empty / absent
        let claudeDir = tmpDir.appendingPathComponent("claude-projects")
        // Codex tree at YYYY/MM/DD
        let codexRoot = tmpDir.appendingPathComponent("codex-sessions")
        let day = codexRoot
            .appendingPathComponent("2026")
            .appendingPathComponent("05")
            .appendingPathComponent("03")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)

        let id = "019dec85-b760-71f2-bca7-b1c463f0d36e"
        let file = day.appendingPathComponent("rollout-2026-05-03T14-27-59-\(id).jsonl")
        let content = """
            {"timestamp":"2026-05-03T14:27:59.000Z","type":"session_meta","payload":{"id":"\(id)","timestamp":"2026-05-03T14:27:59.000Z","cwd":"/Users/test/proj","cli_version":"0.128.0"}}
            {"timestamp":"2026-05-03T14:28:00.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"t1","started_at":"2026-05-03T14:28:00.000Z"}}
            {"timestamp":"2026-05-03T14:28:01.000Z","type":"event_msg","payload":{"type":"user_message","message":"first prompt","images":[],"local_images":[],"text_elements":[]}}
            {"timestamp":"2026-05-03T14:28:50.000Z","type":"event_msg","payload":{"type":"agent_message","message":"reply"}}
            {"timestamp":"2026-05-03T14:29:00.000Z","type":"event_msg","payload":{"type":"user_message","message":"second prompt — most recent","images":[],"local_images":[],"text_elements":[]}}
            """
        try content.write(to: file, atomically: true, encoding: .utf8)

        let scanner = SessionScanner(
            projectsDir: claudeDir,             // doesn't exist → no claude results
            codexSessionsDir: codexRoot
        )
        // 1 day window so we don't depend on file mtime
        let results = scanner.scan(recencyMinutes: 24 * 60)
        #expect(results.count == 1)
        let s = results[0]
        #expect(s.agent == .codex)
        #expect(s.id == id)
        #expect(s.cwd == "/Users/test/proj")
        #expect(s.lastUserPrompt == "second prompt — most recent")
        #expect(s.messageCount == 2)
        // /private/var ↔ /var symlink on macOS — compare suffix instead.
        #expect(s.transcriptPath.hasSuffix(file.lastPathComponent))
    }

    @Test func scanCodex_skipsFilesOlderThanRecencyWindow() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let codexRoot = tmpDir.appendingPathComponent("codex-sessions")
        let day = codexRoot
            .appendingPathComponent("2026")
            .appendingPathComponent("05")
            .appendingPathComponent("03")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)

        let id = "019dec85-b760-71f2-bca7-b1c463f0d36e"
        let file = day.appendingPathComponent("rollout-2026-05-03T14-27-59-\(id).jsonl")
        try """
            {"type":"session_meta","payload":{"id":"\(id)","cwd":"/proj"}}
            """.write(to: file, atomically: true, encoding: .utf8)
        // Backdate the file by 2 hours
        let oldDate = Date().addingTimeInterval(-2 * 3600)
        try FileManager.default.setAttributes(
            [.modificationDate: oldDate], ofItemAtPath: file.path
        )

        let scanner = SessionScanner(
            projectsDir: tmpDir.appendingPathComponent("nope"),
            codexSessionsDir: codexRoot
        )
        let results = scanner.scan(recencyMinutes: 60)
        #expect(results.isEmpty)
    }

    // MARK: - Mixed scan: claude + codex

    @Test func scan_mergesClaudeAndCodexSorted() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // --- Set up a minimal Claude transcript ---
        let claudeRoot = tmpDir.appendingPathComponent("claude-projects")
        let claudeProj = claudeRoot.appendingPathComponent("-Users-test-foo")
        try FileManager.default.createDirectory(at: claudeProj, withIntermediateDirectories: true)
        let claudeId = "claude-session-aaaa-bbbb"
        let claudeFile = claudeProj.appendingPathComponent("\(claudeId).jsonl")
        try """
            {"type":"user","cwd":"/Users/test/foo","message":{"content":"hello from claude"}}
            """.write(to: claudeFile, atomically: true, encoding: .utf8)

        // --- Set up a minimal Codex transcript ---
        let codexRoot = tmpDir.appendingPathComponent("codex-sessions")
        let day = codexRoot
            .appendingPathComponent("2026")
            .appendingPathComponent("05")
            .appendingPathComponent("03")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let codexId = "019dec85-b760-71f2-bca7-b1c463f0d36e"
        let codexFile = day.appendingPathComponent("rollout-2026-05-03T14-27-59-\(codexId).jsonl")
        try """
            {"type":"session_meta","payload":{"id":"\(codexId)","cwd":"/Users/test/bar"}}
            {"type":"event_msg","payload":{"type":"user_message","message":"hello from codex"}}
            """.write(to: codexFile, atomically: true, encoding: .utf8)

        // Make Codex newer so we can assert ordering deterministically.
        let now = Date()
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-30)], ofItemAtPath: claudeFile.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: now], ofItemAtPath: codexFile.path
        )

        let scanner = SessionScanner(projectsDir: claudeRoot, codexSessionsDir: codexRoot)
        let results = scanner.scan(recencyMinutes: 24 * 60)
        #expect(results.count == 2)
        // Sorted newest-first: Codex first.
        #expect(results[0].agent == .codex)
        #expect(results[0].id == codexId)
        #expect(results[1].agent == .claude)
        #expect(results[1].id == claudeId)
    }

    // MARK: - candidateDateDirs (date-window pruning)

    @Test func candidateDateDirs_returnsOneDayWhenWindowFitsInDay() {
        // 2026-05-03 14:00 UTC ± 8h is still within 2026-05-03 (after
        // start-of-day) — so the result spans 05-03 only.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = calendar.date(from: DateComponents(
            timeZone: TimeZone(identifier: "UTC"), year: 2026, month: 5, day: 3,
            hour: 14, minute: 0))!
        let cutoff = now.addingTimeInterval(-2 * 3600)  // 12:00
        let root = URL(fileURLWithPath: "/tmp/cdx")
        let dirs = SessionScanner.candidateDateDirs(rootDir: root, cutoff: cutoff, now: now)
        #expect(dirs.count == 1)
        #expect(dirs[0].path == "/tmp/cdx/2026/05/03")
    }

    @Test func candidateDateDirs_spansAcrossUTCMidnight() {
        // now = 2026-05-04 00:30 UTC; cutoff = -8h = 2026-05-03 16:30.
        // Window touches both 05-03 and 05-04.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = calendar.date(from: DateComponents(
            timeZone: TimeZone(identifier: "UTC"), year: 2026, month: 5, day: 4,
            hour: 0, minute: 30))!
        let cutoff = now.addingTimeInterval(-8 * 3600)
        let root = URL(fileURLWithPath: "/tmp/cdx")
        let dirs = SessionScanner.candidateDateDirs(rootDir: root, cutoff: cutoff, now: now)
        #expect(dirs.count == 2)
        #expect(dirs[0].path == "/tmp/cdx/2026/05/03")
        #expect(dirs[1].path == "/tmp/cdx/2026/05/04")
    }

    @Test func candidateDateDirs_doesNotEnumerateWholeArchive() {
        // 7-day window — should produce 7 or 8 dirs, never the whole year.
        let now = Date()
        let cutoff = now.addingTimeInterval(-7 * 86400)
        let root = URL(fileURLWithPath: "/tmp/cdx")
        let dirs = SessionScanner.candidateDateDirs(rootDir: root, cutoff: cutoff, now: now)
        #expect(dirs.count == 7 || dirs.count == 8)
    }

    // MARK: - Codex sessions dir absent

    @Test func scan_skipsCodexWhenDirNotProvided() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let claudeRoot = tmpDir.appendingPathComponent("claude")
        try FileManager.default.createDirectory(at: claudeRoot, withIntermediateDirectories: true)

        let scanner = SessionScanner(projectsDir: claudeRoot, codexSessionsDir: nil)
        let results = scanner.scan(recencyMinutes: 60)
        #expect(results.isEmpty)
    }
}
