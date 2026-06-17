import Testing
import Foundation
@testable import AppLib

/// #116 — Claude Code writes subagent transcripts to a `subagents/` subdir and
/// Workflow-tool agent transcripts to a `wf_<runId>/` subdir, BOTH nested under
/// `<projectDir>/<sessionId>/`. `computeSnapshot` must descend into them, else
/// deep-research / workflow runs (where most tokens are burned by subagents)
/// massively under-count the Today row, `tokens5h/7d`, and the burn-rate input.
@MainActor
struct UsageTrackerSubagentTests {
    private static func tmpDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private static func line(ts: String, id: String?, input: Int, output: Int = 0,
                             model: String = "claude-opus-4-8") -> String {
        let idField = id.map { "\"id\":\"\($0)\"," } ?? ""
        return "{\"type\":\"assistant\",\"timestamp\":\"\(ts)\",\"message\":{\(idField)\"model\":\"\(model)\",\"usage\":{\"input_tokens\":\(input),\"output_tokens\":\(output),\"cache_read_input_tokens\":0,\"cache_creation_input_tokens\":0}}}"
    }

    private static func write(_ line: String, to dir: URL, name: String) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try line.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }

    /// Main + `subagents/` + `wf_*/` token usage must ALL be tallied.
    @Test func subagentAndWorkflowTokensAreCounted() throws {
        let now = Date()
        let ts = Self.iso(now)
        let projects = try Self.tmpDir()
        let proj = projects.appendingPathComponent("p")
        let session = proj.appendingPathComponent("session-1")

        // Main transcript (already counted today).
        try Self.write(Self.line(ts: ts, id: "msg_main", input: 100), to: proj, name: "session-1.jsonl")
        // Task-subagent transcript (currently MISSED).
        try Self.write(Self.line(ts: ts, id: "msg_sub", input: 200),
                       to: session.appendingPathComponent("subagents"), name: "agent-1.jsonl")
        // Workflow-tool agent transcript (currently MISSED).
        try Self.write(Self.line(ts: ts, id: "msg_wf", input: 400),
                       to: session.appendingPathComponent("wf_run42"), name: "agent-2.jsonl")

        let cal = Calendar.current
        let r = UsageTracker.computeSnapshot(projectsDir: projects, calendar: cal, now: now)
        #expect(r.snapshot.tokens5h == 700)     // 100 + 200 + 400
        #expect(r.snapshot.tokens7d == 700)
        #expect(r.snapshot.messages5h == 3)     // main + subagent + workflow
        let today = cal.startOfDay(for: now)
        #expect(r.daily[today]?["claude-opus-4-8"]?.input == 700)
    }

    /// Global message.id dedup must still span the recursion: an id shared by a
    /// main transcript and a nested subagent file (resume/fork replay) counts once.
    @Test func dedupSpansNestedSubagentFiles() throws {
        let now = Date()
        let ts = Self.iso(now)
        let projects = try Self.tmpDir()
        let proj = projects.appendingPathComponent("p")
        let session = proj.appendingPathComponent("session-1")

        try Self.write(Self.line(ts: ts, id: "msg_dup", input: 100), to: proj, name: "session-1.jsonl")
        try Self.write(Self.line(ts: ts, id: "msg_dup", input: 100),
                       to: session.appendingPathComponent("subagents"), name: "agent-1.jsonl")

        let r = UsageTracker.computeSnapshot(projectsDir: projects, calendar: .current, now: now)
        #expect(r.snapshot.tokens7d == 100)     // same id → counted once across the tree
    }
}
