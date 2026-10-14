import Foundation
import Testing

@testable import RemoteCore

struct RemoteCoreTests {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    func fixture(_ state: RemoteSessionState = .working) -> RemoteSnapshot {
        RemoteSnapshot(
            observedAt: now,
            sessions: [
                RemoteSessionSnapshot(
                    id: "session", agent: .claude, state: state, cwd: "/work/Project", model: "model", tool: "Bash",
                    lastActivity: now)
            ])
    }
    @Test func framingHandlesPartialAndMultipleSnapshots() throws {
        let first = fixture()
        let second = fixture(.idle)
        let a = try RemoteFrameCodec.encode(first)
        let b = try RemoteFrameCodec.encode(second)
        var framer = RemoteLineFramer()
        #expect(try framer.push(Data(a.prefix(10))).isEmpty)
        #expect(try framer.push(Data(a.dropFirst(10)) + b) == [first, second])
        #expect(
            try RemoteFrameCodec.decode(RemoteFrameCodec.encode(RemoteSnapshot(observedAt: now, sessions: []))).sessions
                .isEmpty)
    }
    @Test func rejectsOversizeVersionDuplicateAndContentInjection() throws {
        var bad = fixture()
        bad.version = 2
        #expect(throws: (any Error).self) { try RemoteFrameCodec.encode(bad) }
        bad = fixture()
        bad.sessions += bad.sessions
        #expect(throws: (any Error).self) { try RemoteFrameCodec.encode(bad) }
        bad = fixture()
        bad.sessions[0].cwd = "/bad\npath"
        #expect(throws: (any Error).self) { try RemoteFrameCodec.encode(bad) }
        var framer = RemoteLineFramer()
        #expect(throws: (any Error).self) {
            try framer.push(Data(repeating: 65, count: RemoteFrameCodec.maxFrameBytes + 1))
        }
        #expect(throws: (any Error).self) { try RemoteFrameCodec.decode(Data("not-json".utf8)) }
    }
    func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func write(_ objects: [[String: Any]], to url: URL, modified: Date? = nil) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lines = try objects.map { try JSONSerialization.data(withJSONObject: $0) }
        try lines.reduce(into: Data()) {
            $0.append($1)
            $0.append(10)
        }.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified ?? now], ofItemAtPath: url.path)
    }
    func stamp(_ second: Double) -> String { ISO8601DateFormatter().string(from: now.addingTimeInterval(second)) }

    @Test func observesClaudeQuestionCompletionWithoutContent() throws {
        let r = try root()
        defer { try? FileManager.default.removeItem(at: r) }
        let file = r.appendingPathComponent("claude/project/session.jsonl")
        let question: [[String: Any]] = [
            [
                "type": "user", "timestamp": stamp(-20), "cwd": "/work/Project",
                "message": ["content": "PRIVATE-PROMPT"],
            ],
            [
                "type": "assistant", "timestamp": stamp(-10),
                "message": [
                    "model": "claude-test",
                    "content": [
                        [
                            "type": "tool_use", "id": "q", "name": "AskUserQuestion",
                            "input": ["questions": "PRIVATE-QUESTION"],
                        ]
                    ],
                ],
            ],
        ]
        try write(question, to: file)
        var scanner = RemoteTranscriptScanner(
            claudeRoot: r.appendingPathComponent("claude"), codexRoot: r.appendingPathComponent("codex"))
        let initial = try scanner.snapshot(now: now)
        #expect(initial.sessions.count == 1)
        #expect(initial.sessions[0].state == .waiting)
        #expect(initial.sessions[0].projectName == "Project")
        #expect(initial.sessions[0].model == "claude-test")
        let wire = String(data: try RemoteFrameCodec.encode(initial), encoding: .utf8)!
        #expect(!wire.contains("PRIVATE"))
        try write(
            question + [
                [
                    "type": "user", "timestamp": stamp(-5),
                    "message": ["content": [["type": "tool_result", "tool_use_id": "q", "content": "PRIVATE-ANSWER"]]],
                ],
                [
                    "type": "assistant", "timestamp": stamp(0),
                    "message": ["stop_reason": "end_turn", "content": "PRIVATE-REPLY"],
                ],
            ], to: file)
        #expect(try scanner.snapshot(now: now).sessions.first?.state == .idle)
    }
    @Test func codexMetadataAndRecordedTaskStates() throws {
        let r = try root()
        defer { try? FileManager.default.removeItem(at: r) }
        let file = r.appendingPathComponent("codex/2023/11/14/rollout.jsonl")
        let objects: [[String: Any]] = [
            ["type": "session_meta", "payload": ["id": "codex-id", "cwd": "/work/API"]],
            ["type": "turn_context", "payload": ["model": "gpt-test"]],
            ["type": "event_msg", "timestamp": stamp(-5), "payload": ["type": "task_started"]],
        ]
        try write(objects, to: file)
        var scanner = RemoteTranscriptScanner(
            claudeRoot: r.appendingPathComponent("claude"), codexRoot: r.appendingPathComponent("codex"))
        let initial = try scanner.snapshot(now: now)
        #expect(initial.sessions.first?.agent == .codex)
        #expect(initial.sessions.first?.id == "codex-id")
        #expect(initial.sessions.first?.state == .working)
        try write(
            objects + [
                [
                    "type": "event_msg", "timestamp": stamp(0),
                    "payload": ["type": "task_complete", "last_agent_message": "PRIVATE"],
                ]
            ], to: file)
        #expect(try scanner.snapshot(now: now).sessions.first?.state == .idle)
    }
    @Test func recencySymlinksEmptyAndUnknownAreHonest() throws {
        let r = try root()
        defer { try? FileManager.default.removeItem(at: r) }
        let claude = r.appendingPathComponent("claude")
        let codex = r.appendingPathComponent("codex")
        let old = claude.appendingPathComponent("old.jsonl")
        try write(
            [["type": "user", "timestamp": stamp(-9 * 3600), "message": ["content": "old"]]], to: old,
            modified: now.addingTimeInterval(-9 * 3600))
        let meta = codex.appendingPathComponent("meta.jsonl")
        try write([["type": "session_meta", "payload": ["id": "meta", "cwd": "/work/Unknown"]]], to: meta)
        try FileManager.default.createSymbolicLink(
            at: claude.appendingPathComponent("linked.jsonl"), withDestinationURL: meta)
        var scanner = RemoteTranscriptScanner(claudeRoot: claude, codexRoot: codex)
        let result = try scanner.snapshot(now: now)
        #expect(result.sessions.count == 1)
        #expect(result.sessions[0].state == .unknown)
        try FileManager.default.removeItem(at: meta)
        #expect(try scanner.snapshot(now: now).sessions.isEmpty)
    }
    @Test func newClaudeTurnClearsCancelledQuestionAndIgnoresSynthetic() throws {
        let r = try root()
        defer { try? FileManager.default.removeItem(at: r) }
        let file = r.appendingPathComponent("claude/session.jsonl")
        try write(
            [
                [
                    "type": "assistant", "timestamp": stamp(-10),
                    "message": ["content": [["type": "tool_use", "id": "q", "name": "AskUserQuestion"]]],
                ],
                ["type": "user", "timestamp": stamp(-5), "message": ["content": "<article>Real new task</article>"]],
                [
                    "type": "assistant", "timestamp": stamp(-1),
                    "message": ["model": "<synthetic>", "content": "Informational"],
                ],
            ], to: file)
        var scanner = RemoteTranscriptScanner(
            claudeRoot: r.appendingPathComponent("claude"), codexRoot: r.appendingPathComponent("codex"))
        let session = try #require(scanner.snapshot(now: now).sessions.first)
        #expect(session.state == .working)
        #expect(session.lastActivity == now.addingTimeInterval(-5))
        #expect(session.model == nil)
    }
    @Test func omittedMiddleCannotLeakQuestionStateIntoTail() throws {
        let r = try root()
        defer { try? FileManager.default.removeItem(at: r) }
        let file = r.appendingPathComponent("claude/session.jsonl")
        var objects: [[String: Any]] = [
            [
                "type": "assistant", "timestamp": stamp(-20), "cwd": "/work/Project",
                "message": [
                    "model": "claude-test", "content": [["type": "tool_use", "id": "old", "name": "AskUserQuestion"]],
                ],
            ]
        ]
        for _ in 0..<1500 { objects.append(["type": "progress", "padding": String(repeating: "x", count: 200)]) }
        objects.append([
            "type": "assistant", "timestamp": stamp(-1),
            "message": ["content": [["type": "tool_use", "id": "new", "name": "Bash"]]],
        ])
        try write(objects, to: file)
        var scanner = RemoteTranscriptScanner(
            claudeRoot: r.appendingPathComponent("claude"), codexRoot: r.appendingPathComponent("codex"))
        let session = try #require(scanner.snapshot(now: now).sessions.first)
        #expect(session.state == .working)
        #expect(session.model == "claude-test")
        #expect(session.projectName == "Project")
    }
    @Test func replacementWithSameSizeAndMtimeInvalidatesCache() throws {
        let r = try root()
        defer { try? FileManager.default.removeItem(at: r) }
        let file = r.appendingPathComponent("claude/session.jsonl")
        let object: [[String: Any]] = [
            ["type": "user", "timestamp": stamp(0), "cwd": "/work/First", "message": ["content": "task"]]
        ]
        try write(object, to: file)
        var scanner = RemoteTranscriptScanner(
            claudeRoot: r.appendingPathComponent("claude"), codexRoot: r.appendingPathComponent("codex"))
        #expect(try scanner.snapshot(now: now).sessions.first?.projectName == "First")
        let replacement = r.appendingPathComponent("replacement.jsonl")
        var changed = object
        changed[0]["cwd"] = "/work/Other"
        try write(changed, to: replacement)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: replacement, to: file)
        #expect(try scanner.snapshot(now: now).sessions.first?.projectName == "Other")
    }

}
