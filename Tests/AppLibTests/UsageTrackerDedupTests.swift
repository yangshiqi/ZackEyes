import Testing
import Foundation
@testable import AppLib

/// #88 — Claude Code writes multiple assistant JSONL lines that SHARE one
/// `message.id`, each repeating the SAME `usage` (the content blocks of one API
/// response). Summing every line over-counts tokens/cost (~1.94x on real data).
/// These tests pin the dedup-by-message.id behavior of `computeSnapshot`.
@MainActor
struct UsageTrackerDedupTests {
    private static func tmpDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// One assistant line. `id == nil` omits the `message.id` field entirely
    /// (mirrors lines that legitimately carry no id — must NOT be collapsed).
    private static func line(ts: String, id: String?, input: Int, output: Int = 0,
                             model: String = "claude-opus-4-8") -> String {
        let idField = id.map { "\"id\":\"\($0)\"," } ?? ""
        return "{\"type\":\"assistant\",\"timestamp\":\"\(ts)\",\"message\":{\(idField)\"model\":\"\(model)\",\"usage\":{\"input_tokens\":\(input),\"output_tokens\":\(output),\"cache_read_input_tokens\":0,\"cache_creation_input_tokens\":0}}}"
    }

    private static func write(_ lines: [String], to dir: URL, name: String) throws {
        try lines.joined(separator: "\n").write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }

    @Test func duplicateMessageIdCountedOnce() throws {
        let now = Date()
        let projects = try Self.tmpDir()
        let p = projects.appendingPathComponent("p")
        try FileManager.default.createDirectory(at: p, withIntermediateDirectories: true)
        let ts = Self.iso(now)
        // msg_A repeated 3x (same usage), msg_B once.
        try Self.write([
            Self.line(ts: ts, id: "msg_A", input: 100),
            Self.line(ts: ts, id: "msg_A", input: 100),
            Self.line(ts: ts, id: "msg_A", input: 100),
            Self.line(ts: ts, id: "msg_B", input: 50),
        ], to: p, name: "s.jsonl")

        let r = UsageTracker.computeSnapshot(projectsDir: projects, calendar: .current, now: now)
        #expect(r.snapshot.tokens5h == 150)        // 100 + 50, NOT 350
        #expect(r.snapshot.tokens7d == 150)
        #expect(r.snapshot.messages5h == 2)        // 2 distinct responses, NOT 4
    }

    @Test func linesWithoutMessageIdAreNotCollapsed() throws {
        let now = Date()
        let projects = try Self.tmpDir()
        let p = projects.appendingPathComponent("p")
        try FileManager.default.createDirectory(at: p, withIntermediateDirectories: true)
        let ts = Self.iso(now)
        // No id on either line — each must be counted (do not collapse to one).
        try Self.write([
            Self.line(ts: ts, id: nil, input: 100),
            Self.line(ts: ts, id: nil, input: 100),
        ], to: p, name: "s.jsonl")

        let r = UsageTracker.computeSnapshot(projectsDir: projects, calendar: .current, now: now)
        #expect(r.snapshot.tokens5h == 200)
    }

    @Test func duplicateMessageIdAcrossFilesCountedOnce() throws {
        let now = Date()
        let projects = try Self.tmpDir()
        let ts = Self.iso(now)
        // Same id in two different project dirs/files (resume/fork) → count once.
        for sub in ["p1", "p2"] {
            let d = projects.appendingPathComponent(sub)
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            try Self.write([Self.line(ts: ts, id: "msg_X", input: 100)], to: d, name: "\(sub).jsonl")
        }

        let r = UsageTracker.computeSnapshot(projectsDir: projects, calendar: .current, now: now)
        #expect(r.snapshot.tokens7d == 100)        // global dedup across files
    }

    @Test func dailyTallyDedupsByMessageId() throws {
        let now = Date()
        let projects = try Self.tmpDir()
        let p = projects.appendingPathComponent("p")
        try FileManager.default.createDirectory(at: p, withIntermediateDirectories: true)
        let ts = Self.iso(now)
        try Self.write([
            Self.line(ts: ts, id: "msg_A", input: 100),
            Self.line(ts: ts, id: "msg_A", input: 100),
        ], to: p, name: "s.jsonl")

        let cal = Calendar.current
        let r = UsageTracker.computeSnapshot(projectsDir: projects, calendar: cal, now: now)
        let today = cal.startOfDay(for: now)
        #expect(r.daily[today]?["claude-opus-4-8"]?.input == 100)   // counted once
    }
}
