import Testing
import Foundation
@testable import AppLib
import Shared

/// Focused on the pure parser path. The kqueue-based watcher is exercised
/// indirectly via integration; here we lock in the JSONL → CodexTaskCompleteEvent
/// mapping plus the trailing-partial-line buffering contract.
struct CodexJsonlTailerTests {

    private let sid = "019dec85-b760-71f2-bca7-b1c463f0d36e"
    private let cwd: String? = "/Users/test/proj"
    private let path = "/tmp/rollout-x.jsonl"

    // MARK: - Session metadata

    @Test func parseSessionMetaCwdHandlesLongFirstLine() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        let file = tmpDir.appendingPathComponent("rollout-x.jsonl")
        let largeInstructions = String(repeating: "x", count: 20_000)
        try """
            {"type":"session_meta","payload":{"id":"\(sid)","cwd":"/Users/test/Obsidian Vault","base_instructions":{"text":"\(largeInstructions)"}}}
            {"type":"event_msg","payload":{"type":"user_message","message":"hi"}}\n
            """.write(to: file, atomically: true, encoding: .utf8)

        let parsed = CodexJsonlTailer.parseSessionMetaCwd(at: file)
        #expect(parsed == "/Users/test/Obsidian Vault")
    }

    @Test func discoverRecentRolloutsReturnsOnlyFreshJsonlFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }

        let day = root
            .appendingPathComponent("2026")
            .appendingPathComponent("05")
            .appendingPathComponent("05")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)

        let fresh = day.appendingPathComponent("rollout-2026-05-05T01-02-03-019df6d7-aaaa-bbbb-cccc-dddddddddddd.jsonl")
        let old = day.appendingPathComponent("rollout-2026-05-05T01-02-03-019df6d7-aaaa-bbbb-cccc-eeeeeeeeeeee.jsonl")
        let other = day.appendingPathComponent("notes.txt")
        try "{}\n".write(to: fresh, atomically: true, encoding: .utf8)
        try "{}\n".write(to: old, atomically: true, encoding: .utf8)
        try "ignore\n".write(to: other, atomically: true, encoding: .utf8)

        let freshDate = Date(timeIntervalSince1970: 1_777_962_840)
        let oldDate = freshDate.addingTimeInterval(-7200)
        try FileManager.default.setAttributes([.modificationDate: freshDate], ofItemAtPath: fresh.path)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.modificationDate: freshDate], ofItemAtPath: other.path)

        let files = CodexJsonlTailer.discoverRecentRollouts(
            rootDir: root,
            cutoff: freshDate.addingTimeInterval(-3600)
        )

        #expect(files.map(\.standardizedFileURL) == [fresh.standardizedFileURL])
    }

    // MARK: - Single chunk, one task_complete

    @Test func parsesTaskStartedEvent() {
        var pending = ""
        let chunk = """
            {"type":"event_msg","payload":{"type":"task_started","turn_id":"t1","started_at":"2026-05-05T06:34:00.000Z"}}\n
            """

        let events = CodexJsonlTailer.parseTaskLifecycleEvents(
            chunk: chunk, pending: &pending,
            sessionId: sid, cwd: cwd, transcriptPath: path
        )

        #expect(events.count == 1)
        guard case let .started(event) = events[0] else {
            Issue.record("Expected task_started event")
            return
        }
        #expect(event.sessionId == sid)
        #expect(event.cwd == cwd)
        #expect(event.turnId == "t1")
        #expect(event.startedAt?.timeIntervalSince1970 == 1_777_962_840)
        #expect(event.transcriptPath == path)
        #expect(pending == "")
    }

    @Test func parsesSingleTaskCompleteEvent() {
        var pending = ""
        let chunk = """
            {"type":"event_msg","payload":{"type":"task_started","turn_id":"t1"}}
            {"type":"event_msg","payload":{"type":"task_complete","turn_id":"t1","last_agent_message":"all done","completed_at":1777795294,"duration_ms":130735}}\n
            """
        let events = CodexJsonlTailer.parseTaskCompleteEvents(
            chunk: chunk, pending: &pending,
            sessionId: sid, cwd: cwd, transcriptPath: path
        )
        #expect(events.count == 1)
        #expect(events[0].sessionId == sid)
        #expect(events[0].cwd == cwd)
        #expect(events[0].lastAgentMessage == "all done")
        #expect(events[0].turnId == "t1")
        #expect(events[0].durationMs == 130735)
        #expect(events[0].completedAt?.timeIntervalSince1970 == 1777795294)
        #expect(events[0].transcriptPath == path)
        #expect(pending == "")
        #expect(events[0].shouldNotifyUser)
    }

    @Test func internalApprovalTaskCompleteDoesNotNotifyUser() {
        var pending = ""
        let chunk = """
            {"type":"event_msg","payload":{"type":"task_complete","turn_id":"approval","last_agent_message":"{\\"risk_level\\":\\"low\\",\\"user_authorization\\":\\"high\\",\\"outcome\\":\\"allow\\",\\"rationale\\":\\"Routine cache write.\\"}","completed_at":1777795294,"duration_ms":130735}}\n
            """
        let events = CodexJsonlTailer.parseTaskCompleteEvents(
            chunk: chunk, pending: &pending,
            sessionId: sid, cwd: cwd, transcriptPath: path
        )
        #expect(events.count == 1)
        #expect(events[0].shouldNotifyUser == false)
    }

    @Test func terseInternalApprovalTaskCompleteDoesNotNotifyUser() {
        var pending = ""
        let chunk = """
            {"type":"event_msg","payload":{"type":"task_complete","turn_id":"approval","last_agent_message":"{\\"outcome\\":\\"allow\\"}","completed_at":1777795294,"duration_ms":130735}}\n
            """
        let events = CodexJsonlTailer.parseTaskCompleteEvents(
            chunk: chunk, pending: &pending,
            sessionId: sid, cwd: cwd, transcriptPath: path
        )
        #expect(events.count == 1)
        #expect(events[0].shouldNotifyUser == false)
    }

    @Test func emptyTaskCompleteDoesNotNotifyUser() {
        var pending = ""
        let chunk = """
            {"type":"event_msg","payload":{"type":"task_complete","turn_id":"empty","last_agent_message":null,"completed_at":1777795294,"duration_ms":130735}}\n
            """
        let events = CodexJsonlTailer.parseTaskCompleteEvents(
            chunk: chunk, pending: &pending,
            sessionId: sid, cwd: cwd, transcriptPath: path
        )
        #expect(events.count == 1)
        #expect(events[0].shouldNotifyUser == false)
    }

    @Test func parsesTokenCountContextEvent() {
        var pending = ""
        let chunk = """
            {"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":120000,"cached_input_tokens":64000,"output_tokens":4000,"reasoning_output_tokens":1000,"total_tokens":125000},"last_token_usage":{"total_tokens":9000},"model_context_window":250000},"rate_limits":{}}}\n
            """

        let events = CodexJsonlTailer.parseTaskLifecycleEvents(
            chunk: chunk, pending: &pending,
            sessionId: sid, cwd: cwd, transcriptPath: path
        )

        #expect(events.count == 1)
        guard case let .tokenCount(event) = events.first else {
            Issue.record("Expected token_count event")
            return
        }
        #expect(event.sessionId == sid)
        #expect(event.cwd == cwd)
        #expect(abs(event.contextUsedPct - 3.6) < 0.0001)
        #expect(event.contextWindowSize == 250000)
        #expect(event.transcriptPath == path)
        #expect(pending == "")
    }

    @Test func parsesTurnContextPolicyEvent() {
        var pending = ""
        // Single turn_context row that carries both model + policy fields.
        // The parser should emit BOTH lifecycle events for one row.
        let chunk = """
            {"type":"turn_context","payload":{"cwd":"/proj","model":"gpt-5.5","approval_policy":"never","sandbox_policy":{"type":"danger-full-access","network_access":true}}}\n
            """

        let events = CodexJsonlTailer.parseTaskLifecycleEvents(
            chunk: chunk, pending: &pending,
            sessionId: sid, cwd: cwd, transcriptPath: path
        )

        #expect(events.count == 2)
        guard case let .modelChanged(modelEvent) = events[0] else {
            Issue.record("Expected modelChanged event first")
            return
        }
        guard case let .policyChanged(policyEvent) = events[1] else {
            Issue.record("Expected policyChanged event second")
            return
        }
        #expect(modelEvent.modelDisplayName == "gpt-5.5")
        #expect(policyEvent.approvalPolicy == "never")
        #expect(policyEvent.sandboxType == "danger-full-access")
        #expect(policyEvent.sessionId == sid)
        #expect(policyEvent.cwd == cwd)
    }

    @Test func turnContextWithOnlyApprovalEmitsPolicyOnly() {
        var pending = ""
        let chunk = """
            {"type":"turn_context","payload":{"cwd":"/proj","approval_policy":"on-request"}}\n
            """
        let events = CodexJsonlTailer.parseTaskLifecycleEvents(
            chunk: chunk, pending: &pending,
            sessionId: sid, cwd: cwd, transcriptPath: path
        )
        #expect(events.count == 1)
        guard case let .policyChanged(policyEvent) = events.first else {
            Issue.record("Expected single policyChanged event")
            return
        }
        #expect(policyEvent.approvalPolicy == "on-request")
        #expect(policyEvent.sandboxType == nil)
    }

    @Test func parseInitialTurnContextReturnsCombinedStruct() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        let file = tmpDir.appendingPathComponent("rollout-x.jsonl")
        try """
            {"type":"session_meta","payload":{"id":"\(sid)","cwd":"/proj"}}
            {"type":"turn_context","payload":{"cwd":"/proj","model":"gpt-5.5","approval_policy":"never","sandbox_policy":{"type":"workspace-write"}}}
            {"type":"event_msg","payload":{"type":"user_message","message":"hi"}}\n
            """.write(to: file, atomically: true, encoding: .utf8)

        let ctx = try #require(CodexJsonlTailer.parseInitialTurnContext(at: file))
        #expect(ctx.model == "gpt-5.5")
        #expect(ctx.approvalPolicy == "never")
        #expect(ctx.sandboxType == "workspace-write")
    }

    @Test func parsesTurnContextModelEventOnly() {
        var pending = ""
        // Pure model — no policy fields → exactly one event (.modelChanged).
        let chunk = """
            {"type":"turn_context","payload":{"cwd":"/proj","model":"gpt-5.5","turn_id":"t1"}}\n
            """

        let events = CodexJsonlTailer.parseTaskLifecycleEvents(
            chunk: chunk, pending: &pending,
            sessionId: sid, cwd: cwd, transcriptPath: path
        )

        #expect(events.count == 1)
        guard case let .modelChanged(event) = events.first else {
            Issue.record("Expected modelChanged event")
            return
        }
        #expect(event.sessionId == sid)
        #expect(event.cwd == cwd)
        #expect(event.modelDisplayName == "gpt-5.5")
        #expect(event.transcriptPath == path)
        #expect(pending == "")
    }

    @Test func turnContextWithoutModelOrPolicyIsIgnored() {
        var pending = ""
        // Both rows are devoid of model/approval/sandbox — nothing to emit.
        let chunk = """
            {"type":"turn_context","payload":{"cwd":"/proj","turn_id":"t0"}}
            {"type":"turn_context","payload":{"cwd":"/proj","model":"","turn_id":"t1"}}\n
            """

        let events = CodexJsonlTailer.parseTaskLifecycleEvents(
            chunk: chunk, pending: &pending,
            sessionId: sid, cwd: cwd, transcriptPath: path
        )

        #expect(events.isEmpty)
    }

    @Test func parseInitialTurnContextModelReadsFromFile() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        let file = tmpDir.appendingPathComponent("rollout-x.jsonl")
        try """
            {"type":"session_meta","payload":{"id":"\(sid)","cwd":"/proj"}}
            {"type":"turn_context","payload":{"cwd":"/proj","model":"gpt-5.5","turn_id":"t1"}}
            {"type":"event_msg","payload":{"type":"user_message","message":"hi"}}\n
            """.write(to: file, atomically: true, encoding: .utf8)

        #expect(CodexJsonlTailer.parseInitialTurnContextModel(at: file) == "gpt-5.5")
    }

    @Test func parseSessionMetaSubagentHandlesStringShape() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        let file = tmpDir.appendingPathComponent("rollout-x.jsonl")
        try """
            {"type":"session_meta","payload":{"id":"\(sid)","cwd":"/proj","source":{"subagent":"review"},"thread_source":"subagent"}}\n
            """.write(to: file, atomically: true, encoding: .utf8)

        #expect(CodexJsonlTailer.parseSessionMetaSubagent(at: file) == "review")
    }

    @Test func parseSessionMetaSubagentHandlesObjectShape() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        let file = tmpDir.appendingPathComponent("rollout-x.jsonl")
        try """
            {"type":"session_meta","payload":{"id":"\(sid)","cwd":"/proj","source":{"subagent":{"other":"guardian"}},"thread_source":"subagent"}}\n
            """.write(to: file, atomically: true, encoding: .utf8)

        #expect(CodexJsonlTailer.parseSessionMetaSubagent(at: file) == "guardian")
    }

    @Test func parseSessionMetaSubagentReturnsNilForMainThread() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        let file = tmpDir.appendingPathComponent("rollout-x.jsonl")
        try """
            {"type":"session_meta","payload":{"id":"\(sid)","cwd":"/proj","originator":"codex-tui","thread_source":"user"}}\n
            """.write(to: file, atomically: true, encoding: .utf8)

        #expect(CodexJsonlTailer.parseSessionMetaSubagent(at: file) == nil)
    }

    @Test func parseInitialTurnContextModelReturnsNilWhenAbsent() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        let file = tmpDir.appendingPathComponent("rollout-x.jsonl")
        try """
            {"type":"session_meta","payload":{"id":"\(sid)","cwd":"/proj"}}
            {"type":"event_msg","payload":{"type":"user_message","message":"hi"}}\n
            """.write(to: file, atomically: true, encoding: .utf8)

        #expect(CodexJsonlTailer.parseInitialTurnContextModel(at: file) == nil)
    }

    // MARK: - Multiple events in one chunk

    @Test func parsesMultipleTaskCompleteEventsInOrder() {
        var pending = ""
        let chunk = """
            {"type":"event_msg","payload":{"type":"task_complete","turn_id":"a","last_agent_message":"first","completed_at":1000,"duration_ms":100}}
            {"type":"event_msg","payload":{"type":"agent_message","message":"between"}}
            {"type":"event_msg","payload":{"type":"task_complete","turn_id":"b","last_agent_message":"second","completed_at":2000,"duration_ms":200}}\n
            """
        let events = CodexJsonlTailer.parseTaskCompleteEvents(
            chunk: chunk, pending: &pending,
            sessionId: sid, cwd: cwd, transcriptPath: path
        )
        #expect(events.count == 2)
        #expect(events[0].turnId == "a")
        #expect(events[0].lastAgentMessage == "first")
        #expect(events[1].turnId == "b")
        #expect(events[1].lastAgentMessage == "second")
    }

    // MARK: - Trailing partial line buffered for next call

    @Test func partialTrailingLineBuffersAcrossCalls() {
        var pending = ""

        // First chunk ends mid-line — the parser must hold onto it.
        let firstChunk = """
            {"type":"event_msg","payload":{"type":"task_complete","turn_id":"t1","last_agent_message":"complete one","completed_at":1,"duration_ms":1}}
            {"type":"event_m
            """
        let first = CodexJsonlTailer.parseTaskCompleteEvents(
            chunk: firstChunk, pending: &pending,
            sessionId: sid, cwd: cwd, transcriptPath: path
        )
        #expect(first.count == 1)
        #expect(first[0].turnId == "t1")
        #expect(pending.contains("\"event_m"))

        // Second chunk completes the buffered line + adds another event.
        let secondChunk = """
            sg","payload":{"type":"task_complete","turn_id":"t2","last_agent_message":"complete two","completed_at":2,"duration_ms":2}}
            {"type":"event_msg","payload":{"type":"task_complete","turn_id":"t3","last_agent_message":"complete three","completed_at":3,"duration_ms":3}}\n
            """
        let second = CodexJsonlTailer.parseTaskCompleteEvents(
            chunk: secondChunk, pending: &pending,
            sessionId: sid, cwd: cwd, transcriptPath: path
        )
        #expect(second.count == 2)
        #expect(second[0].turnId == "t2")
        #expect(second[1].turnId == "t3")
        #expect(pending == "")
    }

    // MARK: - Other event types are ignored

    @Test func ignoresNonTaskCompleteLines() {
        var pending = ""
        let chunk = """
            {"type":"session_meta","payload":{"id":"x","cwd":"/proj"}}
            {"type":"event_msg","payload":{"type":"user_message","message":"hi"}}
            {"type":"event_msg","payload":{"type":"agent_message","message":"hello"}}
            {"type":"event_msg","payload":{"type":"token_count","rate_limits":{}}}
            {"type":"response_item","payload":{"type":"reasoning","summary":[]}}\n
            """
        let events = CodexJsonlTailer.parseTaskCompleteEvents(
            chunk: chunk, pending: &pending,
            sessionId: sid, cwd: cwd, transcriptPath: path
        )
        #expect(events.isEmpty)
    }

    // MARK: - Malformed JSON lines are skipped, not fatal

    @Test func skipsMalformedJsonLines() {
        var pending = ""
        let chunk = """
            not json at all
            {"type":"event_msg","payload":{"type":"task_complete","turn_id":"good","last_agent_message":"ok","completed_at":5,"duration_ms":5}}
            {"another":"valid json but wrong shape"}\n
            """
        let events = CodexJsonlTailer.parseTaskCompleteEvents(
            chunk: chunk, pending: &pending,
            sessionId: sid, cwd: cwd, transcriptPath: path
        )
        #expect(events.count == 1)
        #expect(events[0].turnId == "good")
    }

    // MARK: - Empty chunk leaves pending intact

    @Test func emptyChunkKeepsPendingUnchanged() {
        var pending = "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\""
        let events = CodexJsonlTailer.parseTaskCompleteEvents(
            chunk: "", pending: &pending,
            sessionId: sid, cwd: cwd, transcriptPath: path
        )
        #expect(events.isEmpty)
        #expect(pending.contains("task_complete"))
    }

    // MARK: - Int millis fallback for completed_at

    @Test func acceptsCompletedAtInMilliseconds() {
        var pending = ""
        let chunk = """
            {"type":"event_msg","payload":{"type":"task_complete","turn_id":"ms","last_agent_message":"done","completed_at":1777795294000,"duration_ms":50}}\n
            """
        let events = CodexJsonlTailer.parseTaskCompleteEvents(
            chunk: chunk, pending: &pending,
            sessionId: sid, cwd: cwd, transcriptPath: path
        )
        #expect(events.count == 1)
        #expect(events[0].completedAt?.timeIntervalSince1970 == 1777795294)
    }
}
