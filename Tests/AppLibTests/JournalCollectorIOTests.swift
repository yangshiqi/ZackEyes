import Testing
import Foundation
@testable import AppLib
import Shared

/// #214 — the collector's filesystem half, driven against fixtures.
///
/// The fixtures model the decode boundary as it actually is: real key names,
/// real nesting, timestamps in the shapes both agents emit. A fixture that
/// drifts from the real shape makes every test below meaningless, so shapes
/// were taken from live transcripts, not from memory.
struct JournalCollectorIOTests {

    private var beijing: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        return c
    }

    /// 2026-07-25 12:00 Beijing (04:00 UTC). Verified against `datetime`, not
    /// arithmetic — the first draft of this constant was off by twelve hours
    /// and quietly moved every fixture entry outside the target day.
    private let noonLocal = Date(timeIntervalSince1970: 1_784_952_000)

    private func makeTempDirs() throws -> (root: URL, claude: URL, codex: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("journal-io-\(UUID().uuidString)")
        let claude = root.appendingPathComponent("projects")
        let codex = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        return (root, claude, codex)
    }

    private func writeClaude(_ dir: URL, project: String, session: String, lines: [String]) throws {
        let d = dir.appendingPathComponent(project)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try lines.joined(separator: "\n")
            .write(to: d.appendingPathComponent("\(session).jsonl"),
                   atomically: true, encoding: .utf8)
    }

    private func claudeUser(_ ts: String, _ text: String, cwd: String) -> String {
        #"{"type":"user","cwd":"\#(cwd)","timestamp":"\#(ts)","message":{"role":"user","content":"\#(text)"}}"#
    }

    private func claudeAssistant(_ ts: String, _ text: String, id: String,
                                 input: Int, output: Int) -> String {
        #"{"type":"assistant","timestamp":"\#(ts)","message":{"role":"assistant","id":"\#(id)","content":[{"type":"text","text":"\#(text)"},{"type":"tool_use","name":"Bash"}],"usage":{"input_tokens":\#(input),"output_tokens":\#(output),"cache_read_input_tokens":10,"cache_creation_input_tokens":5}}}"#
    }

    // MARK: - Claude

    @Test("a claude session becomes one slice with facts folded from the same read")
    func claudeSliceParsed() throws {
        let (root, claude, codex) = try makeTempDirs()
        defer { try? FileManager.default.removeItem(at: root) }

        try writeClaude(claude, project: "-Users-a-Work-Zack", session: "s1", lines: [
            claudeUser("2026-07-25T04:10:00.000Z", "修一下压缩标记", cwd: "/Users/a/Work/Zack"),
            claudeAssistant("2026-07-25T04:11:00.000Z", "改好了", id: "m1", input: 100, output: 50),
            claudeUser("2026-07-25T05:00:00.000Z", "再跑一次测试", cwd: "/Users/a/Work/Zack"),
        ])

        let slices = JournalCollector.collect(
            day: noonLocal, claudeProjectsDir: claude, codexSessionsDir: codex,
            calendar: beijing)

        #expect(slices.count == 1)
        let s = try #require(slices.first)
        #expect(s.agent == .claude)
        #expect(s.projectKey == "Zack")
        #expect(s.turnCount == 2)
        #expect(s.toolCallCount == 1)
        #expect(s.tokens.input == 100)
        #expect(s.tokens.output == 50)
        #expect(s.transcriptText.contains("user: 修一下压缩标记"))
        #expect(s.transcriptText.contains("assistant: 改好了"))
    }

    @Test("out-of-day entries are excluded by their own timestamp")
    func outOfDayEntriesExcluded() throws {
        let (root, claude, codex) = try makeTempDirs()
        defer { try? FileManager.default.removeItem(at: root) }

        // File touched today (mtime is now), but one entry belongs to the
        // previous local day: 2026-07-24 23:59 Beijing == 07-24T15:59Z.
        try writeClaude(claude, project: "-Users-a-Work-Zack", session: "s1", lines: [
            claudeUser("2026-07-24T15:59:00.000Z", "昨天的活", cwd: "/Users/a/Work/Zack"),
            claudeUser("2026-07-25T04:10:00.000Z", "今天的活", cwd: "/Users/a/Work/Zack"),
        ])

        let slices = JournalCollector.collect(
            day: noonLocal, claudeProjectsDir: claude, codexSessionsDir: codex,
            calendar: beijing)

        let s = try #require(slices.first)
        #expect(s.turnCount == 1)
        #expect(!s.transcriptText.contains("昨天的活"))
    }

    @Test("system-injected user turns do not count as work")
    func injectedTurnsIgnored() throws {
        let (root, claude, codex) = try makeTempDirs()
        defer { try? FileManager.default.removeItem(at: root) }

        // A session whose only "user" content is machine-injected must not
        // become a slice at all — 20-line probe sessions are noise, and the
        // map stage would spawn an agent for each one.
        try writeClaude(claude, project: "-Users-a-Work-Zack", session: "s1", lines: [
            claudeUser("2026-07-25T04:10:00.000Z",
                       "<local-command-caveat>ran /compact</local-command-caveat>",
                       cwd: "/Users/a/Work/Zack"),
        ])

        let slices = JournalCollector.collect(
            day: noonLocal, claudeProjectsDir: claude, codexSessionsDir: codex,
            calendar: beijing)
        #expect(slices.isEmpty)
    }

    @Test("subagent transcripts are not slices")
    func subagentFilesSkipped() throws {
        let (root, claude, codex) = try makeTempDirs()
        defer { try? FileManager.default.removeItem(at: root) }

        // …/<project>/subagents/agent-x.jsonl — its work already appears in
        // the parent transcript as Task tool calls; promoting it would mint a
        // session the user never opened.
        try writeClaude(claude, project: "-Users-a-Work-Zack/subagents",
                        session: "agent-x", lines: [
            claudeUser("2026-07-25T04:10:00.000Z", "subagent chatter",
                       cwd: "/Users/a/Work/Zack"),
        ])

        let slices = JournalCollector.collect(
            day: noonLocal, claudeProjectsDir: claude, codexSessionsDir: codex,
            calendar: beijing)
        #expect(slices.isEmpty)
    }

    @Test("excluded projects yield nothing; aliased ones publish the alias")
    func configAppliedAtCollectTime() throws {
        let (root, claude, codex) = try makeTempDirs()
        defer { try? FileManager.default.removeItem(at: root) }

        try writeClaude(claude, project: "-Users-a-Work-AcmeBank", session: "s1", lines: [
            claudeUser("2026-07-25T04:10:00.000Z", "客户的活", cwd: "/Users/a/Work/AcmeBank"),
        ])
        try writeClaude(claude, project: "-Users-a-Work-acme-portal", session: "s2", lines: [
            claudeUser("2026-07-25T04:20:00.000Z", "门户的活", cwd: "/Users/a/Work/acme-portal"),
        ])

        let config = JournalCollector.Config(
            aliases: ["acme-portal": "Client A"], excluded: ["AcmeBank"])
        let slices = JournalCollector.collect(
            day: noonLocal, claudeProjectsDir: claude, codexSessionsDir: codex,
            config: config, calendar: beijing)

        #expect(slices.count == 1)
        #expect(slices.first?.projectKey == "Client A")
    }

    // MARK: - Codex

    @Test("a codex rollout in the previous UTC directory still lands in the local day")
    func codexUTCBoundaryCovered() throws {
        let (root, claude, codex) = try makeTempDirs()
        defer { try? FileManager.default.removeItem(at: root) }

        // 2026-07-25 06:00 Beijing == 2026-07-24T22:00Z: the entry lives in
        // the 07/24 UTC directory. Scanning only 07/25 would drop it — that is
        // the first eight hours of every Beijing workday.
        let dir = codex.appendingPathComponent("2026/07/24")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let lines = [
            #"{"type":"session_meta","payload":{"cwd":"/Users/a/Work/nova"}}"#,
            #"{"type":"event_msg","timestamp":"2026-07-24T22:00:00.000Z","payload":{"type":"user_message","message":"修分页"}}"#,
            #"{"type":"response_item","payload":{"type":"function_call","name":"shell"}}"#,
            #"{"type":"event_msg","timestamp":"2026-07-24T22:05:00.000Z","payload":{"type":"agent_message","message":"改完了"}}"#,
            #"{"type":"event_msg","timestamp":"2026-07-24T22:05:01.000Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":200,"cached_input_tokens":80,"output_tokens":40}}}}"#,
        ]
        try lines.joined(separator: "\n")
            .write(to: dir.appendingPathComponent("rollout-x.jsonl"),
                   atomically: true, encoding: .utf8)

        let slices = JournalCollector.collect(
            day: noonLocal, claudeProjectsDir: claude, codexSessionsDir: codex,
            calendar: beijing)

        #expect(slices.count == 1)
        let s = try #require(slices.first)
        #expect(s.agent == .codex)
        #expect(s.projectKey == "nova")
        #expect(s.turnCount == 1)
        #expect(s.toolCallCount == 1)
        // Codex input_tokens includes cached input; `input` stores the
        // uncached remainder so `distinct` means the same for both agents.
        #expect(s.tokens.input == 120)
        #expect(s.tokens.cacheRead == 80)
        #expect(s.tokens.output == 40)
    }

    @Test("both agents' slices come back merged and time-ordered")
    func mergedAndOrdered() throws {
        let (root, claude, codex) = try makeTempDirs()
        defer { try? FileManager.default.removeItem(at: root) }

        try writeClaude(claude, project: "-Users-a-Work-Zack", session: "s1", lines: [
            claudeUser("2026-07-25T06:00:00.000Z", "下午的活", cwd: "/Users/a/Work/Zack"),
        ])
        let dir = codex.appendingPathComponent("2026/07/25")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try [
            #"{"type":"session_meta","payload":{"cwd":"/Users/a/Work/nova"}}"#,
            #"{"type":"event_msg","timestamp":"2026-07-25T01:00:00.000Z","payload":{"type":"user_message","message":"早上的活"}}"#,
        ].joined(separator: "\n")
            .write(to: dir.appendingPathComponent("rollout-y.jsonl"),
                   atomically: true, encoding: .utf8)

        let slices = JournalCollector.collect(
            day: noonLocal, claudeProjectsDir: claude, codexSessionsDir: codex,
            calendar: beijing)

        #expect(slices.map(\.agent) == [.codex, .claude])
    }
}
