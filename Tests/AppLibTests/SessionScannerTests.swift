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

    private func currentCodexDayDir(under root: URL) -> URL {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let comps = calendar.dateComponents([.year, .month, .day], from: Date())
        return root
            .appendingPathComponent(String(format: "%04d", comps.year!))
            .appendingPathComponent(String(format: "%02d", comps.month!))
            .appendingPathComponent(String(format: "%02d", comps.day!))
    }

    private func currentCodexRolloutName(id: String) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let comps = calendar.dateComponents([.year, .month, .day], from: Date())
        return String(format: "rollout-%04d-%02d-%02dT00-00-00-\(id).jsonl",
                      comps.year!, comps.month!, comps.day!)
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
        let day = currentCodexDayDir(under: codexRoot)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)

        let id = "019dec85-b760-71f2-bca7-b1c463f0d36e"
        let file = day.appendingPathComponent(currentCodexRolloutName(id: id))
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

    @Test func scanCodex_parsesCwdWhenSessionMetaLineExceedsHeadBuffer() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let codexRoot = tmpDir.appendingPathComponent("codex-sessions")
        let day = currentCodexDayDir(under: codexRoot)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)

        let id = "019dec85-b760-71f2-bca7-b1c463f0d36e"
        let file = day.appendingPathComponent(currentCodexRolloutName(id: id))
        let largeInstructions = String(repeating: "x", count: 20_000)
        let content = """
            {"type":"session_meta","payload":{"id":"\(id)","cwd":"/Users/test/Obsidian Vault","base_instructions":{"text":"\(largeInstructions)"}}}
            {"type":"event_msg","payload":{"type":"user_message","message":"hello from codex"}}
            """
        try content.write(to: file, atomically: true, encoding: .utf8)

        let scanner = SessionScanner(
            projectsDir: tmpDir.appendingPathComponent("no-claude"),
            codexSessionsDir: codexRoot
        )
        let results = scanner.scan(recencyMinutes: 24 * 60)

        #expect(results.count == 1)
        #expect(results[0].cwd == "/Users/test/Obsidian Vault")
    }

    @Test func scanCodex_skipsFilesOlderThanRecencyWindow() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let codexRoot = tmpDir.appendingPathComponent("codex-sessions")
        let day = currentCodexDayDir(under: codexRoot)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)

        let id = "019dec85-b760-71f2-bca7-b1c463f0d36e"
        let file = day.appendingPathComponent(currentCodexRolloutName(id: id))
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
        let day = currentCodexDayDir(under: codexRoot)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let codexId = "019dec85-b760-71f2-bca7-b1c463f0d36e"
        let codexFile = day.appendingPathComponent(currentCodexRolloutName(id: codexId))
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

    // MARK: - #43 recap: last assistant message from transcript tail

    @Test func scanClaude_extractsLastAssistantReplyForRecap() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let claudeRoot = tmpDir.appendingPathComponent("claude-projects")
        let proj = claudeRoot.appendingPathComponent("-Users-test-foo")
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        let id = "claude-recap-aaaa-bbbb"
        let file = proj.appendingPathComponent("\(id).jsonl")
        try """
            {"type":"user","cwd":"/Users/test/foo","message":{"content":"fix the bug"}}
            {"type":"assistant","message":{"content":[{"type":"text","text":"Looking into it."}]}}
            {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit"},{"type":"text","text":"Fixed the off-by-one in parse()."}]}}
            """.write(to: file, atomically: true, encoding: .utf8)
        let scanner = SessionScanner(
            projectsDir: claudeRoot,
            codexSessionsDir: tmpDir.appendingPathComponent("no-codex")
        )
        let results = scanner.scan(recencyMinutes: 24 * 60)
        #expect(results.count == 1)
        // Last assistant message wins; tool_use blocks are skipped.
        #expect(results.first?.lastAssistantMessage == "Fixed the off-by-one in parse().")
    }

    @Test func scanCodex_prefersTaskCompleteForRecap() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let codexRoot = tmpDir.appendingPathComponent("codex-sessions")
        let day = currentCodexDayDir(under: codexRoot)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let id = "019dec85-b760-71f2-bca7-b1c463f0d36e"
        let file = day.appendingPathComponent(currentCodexRolloutName(id: id))
        try """
            {"type":"session_meta","payload":{"id":"\(id)","cwd":"/Users/test/bar"}}
            {"type":"event_msg","payload":{"type":"user_message","message":"build it"}}
            {"type":"event_msg","payload":{"type":"agent_message","message":"working on it"}}
            {"type":"event_msg","payload":{"type":"task_complete","last_agent_message":"Done built and tested."}}
            """.write(to: file, atomically: true, encoding: .utf8)
        let scanner = SessionScanner(
            projectsDir: tmpDir.appendingPathComponent("no-claude"),
            codexSessionsDir: codexRoot
        )
        let results = scanner.scan(recencyMinutes: 24 * 60)
        #expect(results.count == 1)
        // task_complete.last_agent_message follows agent_message → it's the recap.
        #expect(results.first?.lastAssistantMessage == "Done built and tested.")
    }

    @Test func scanClaude_handlesStringFormAssistantContent() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let claudeRoot = tmpDir.appendingPathComponent("claude-projects")
        let proj = claudeRoot.appendingPathComponent("-Users-test-foo")
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        let id = "claude-strcontent-cccc"
        let file = proj.appendingPathComponent("\(id).jsonl")
        try """
            {"type":"user","cwd":"/Users/test/foo","message":{"content":"hi"}}
            {"type":"assistant","message":{"content":"plain string reply"}}
            """.write(to: file, atomically: true, encoding: .utf8)
        let scanner = SessionScanner(
            projectsDir: claudeRoot,
            codexSessionsDir: tmpDir.appendingPathComponent("no-codex")
        )
        let results = scanner.scan(recencyMinutes: 24 * 60)
        #expect(results.first?.lastAssistantMessage == "plain string reply")
    }

    @Test func scanClaude_trailingUserTurnClearsStaleRecap() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let claudeRoot = tmpDir.appendingPathComponent("claude-projects")
        let proj = claudeRoot.appendingPathComponent("-Users-test-foo")
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        let id = "claude-trailing-dddd"
        let file = proj.appendingPathComponent("\(id).jsonl")
        // Transcript ends with a NEW user turn (no assistant reply yet) → the
        // previous turn's recap must NOT be carried forward (acceptance ①).
        try """
            {"type":"user","cwd":"/Users/test/foo","message":{"content":"do X"}}
            {"type":"assistant","message":{"content":[{"type":"text","text":"X done."}]}}
            {"type":"user","cwd":"/Users/test/foo","message":{"content":"now do Y"}}
            """.write(to: file, atomically: true, encoding: .utf8)
        let scanner = SessionScanner(
            projectsDir: claudeRoot,
            codexSessionsDir: tmpDir.appendingPathComponent("no-codex")
        )
        let results = scanner.scan(recencyMinutes: 24 * 60)
        #expect(results.first?.lastAssistantMessage == nil)
        #expect(results.first?.lastUserPrompt == "now do Y")
    }

    // MARK: - allDateDirs (filesystem walk)

    /// macOS `temporaryDirectory` returns `/var/folders/...` but
    /// `FileManager.createDirectory` records `/private/var/folders/...`.
    /// `contentsOfDirectory` echoes the canonical form back, so callers
    /// that built paths with raw `.appendingPathComponent` need to
    /// re-canonicalize before comparing.
    private static func canonical(_ url: URL) -> String {
        (url.path as NSString).resolvingSymlinksInPath
    }

    @Test func allDateDirs_returnsEveryExistingDayDir() throws {
        let root = try makeTmpDir()
        let fm = FileManager.default
        for path in ["2025/12/30", "2026/01/01", "2026/05/12", "2026/05/18"] {
            try fm.createDirectory(
                at: root.appendingPathComponent(path),
                withIntermediateDirectories: true
            )
        }
        let rootPath = Self.canonical(root)
        let dirs = SessionScanner.allDateDirs(under: root)
            .map { Self.canonical($0).replacingOccurrences(of: rootPath, with: "") }
            .sorted()
        #expect(dirs == ["/2025/12/30", "/2026/01/01", "/2026/05/12", "/2026/05/18"])
    }

    @Test func allDateDirs_skipsNonNumericDirs() throws {
        // Codex tooling occasionally drops sibling files / dirs under the
        // sessions root (e.g. `.DS_Store`, `tmp/`). Only well-formed
        // `YYYY/MM/DD` paths should be returned.
        let root = try makeTmpDir()
        let fm = FileManager.default
        try fm.createDirectory(
            at: root.appendingPathComponent("2026/05/18"),
            withIntermediateDirectories: true
        )
        try fm.createDirectory(
            at: root.appendingPathComponent("tmp/foo/bar"),
            withIntermediateDirectories: true
        )
        // Strays inside otherwise-valid trees should also be ignored:
        try fm.createDirectory(
            at: root.appendingPathComponent("2026/05/.DS_Store"),
            withIntermediateDirectories: true
        )
        let rootPath = Self.canonical(root)
        let dirs = SessionScanner.allDateDirs(under: root)
            .map { Self.canonical($0).replacingOccurrences(of: rootPath, with: "") }
        #expect(dirs == ["/2026/05/18"])
    }

    @Test func allDateDirs_findsResumedSessionDirOutsideRecencyWindow() throws {
        // Regression test for `codex --resume` of an old session: the
        // resumed rollout lives under the *original* date dir, far outside
        // the recency window, but its jsonl mtime can be fresh. allDateDirs
        // must include the old dir so scanCodex's mtime filter has a chance
        // to pick the file up.
        let root = try makeTmpDir()
        let oldDayDir = root.appendingPathComponent("2025/01/01")
        let recentDayDir = root.appendingPathComponent("2026/05/18")
        try FileManager.default.createDirectory(at: oldDayDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: recentDayDir, withIntermediateDirectories: true)
        let dirs = Set(SessionScanner.allDateDirs(under: root).map(Self.canonical))
        #expect(dirs.contains(Self.canonical(oldDayDir)))
        #expect(dirs.contains(Self.canonical(recentDayDir)))
    }

    // MARK: - Codex sessions dir absent

    // MARK: - Split recency windows (claude vs codex)

    /// Codex rollouts written outside the codex window must be excluded
    /// even when the claude window is wide. Without per-agent windows we
    /// pull stale closed-TUI rollouts into the notch on launch.
    @Test func scan_appliesCodexWindowIndependentlyOfClaudeWindow() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Claude transcript modified 6h ago — within an 8h claude window.
        let claudeRoot = tmpDir.appendingPathComponent("claude-projects")
        let claudeProj = claudeRoot.appendingPathComponent("-Users-test-foo")
        try FileManager.default.createDirectory(at: claudeProj, withIntermediateDirectories: true)
        let claudeFile = claudeProj.appendingPathComponent("claude-old.jsonl")
        try """
            {"type":"user","cwd":"/Users/test/foo","message":{"content":"hello"}}
            """.write(to: claudeFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-6 * 3600)],
            ofItemAtPath: claudeFile.path
        )

        // Codex rollout modified 6h ago — outside a tight 30-min codex
        // window even though it's inside the 8h claude window.
        let codexRoot = tmpDir.appendingPathComponent("codex-sessions")
        let day = currentCodexDayDir(under: codexRoot)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let codexId = "019dec85-b760-71f2-bca7-b1c463f0d36e"
        let codexFile = day.appendingPathComponent(currentCodexRolloutName(id: codexId))
        try """
            {"type":"session_meta","payload":{"id":"\(codexId)","cwd":"/Users/test/bar"}}
            """.write(to: codexFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-6 * 3600)],
            ofItemAtPath: codexFile.path
        )

        let scanner = SessionScanner(projectsDir: claudeRoot, codexSessionsDir: codexRoot)
        let results = scanner.scan(claudeRecencyMinutes: 480, codexRecencyMinutes: 30)
        // Claude session shows up; the equally-old codex session is dropped.
        #expect(results.count == 1)
        #expect(results[0].agent == .claude)
    }

    @Test func scan_singleWindowOverloadAppliesToBothAgents() throws {
        // The convenience overload `scan(recencyMinutes:)` should still
        // exist for callers that want one window for both agents.
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let claudeRoot = tmpDir.appendingPathComponent("claude-projects")
        let codexRoot = tmpDir.appendingPathComponent("codex-sessions")
        try FileManager.default.createDirectory(at: claudeRoot, withIntermediateDirectories: true)

        let scanner = SessionScanner(projectsDir: claudeRoot, codexSessionsDir: codexRoot)
        // Just verify it doesn't crash and returns an empty list.
        let results = scanner.scan(recencyMinutes: 60)
        #expect(results.isEmpty)
    }

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
