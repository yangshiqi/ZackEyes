import Foundation
import Shared
import Testing

@testable import AppLib

struct UsageLedgerTests {
    static let start = Date(timeIntervalSince1970: 1_792_000_000)
    static var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }
    static func line(_ object: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), encoding: .utf8)!
    }
    static func stamp(_ offset: Double) -> String {
        ISO8601DateFormatter().string(from: start.addingTimeInterval(offset))
    }
    static func claude(_ offset: Double, type: String, message: [String: Any]) -> String {
        line([
            "type": type, "timestamp": stamp(offset), "sessionId": "session-a", "cwd": "/private/client/Project",
            "message": message,
        ])
    }
    static func report(_ records: [UsageLedgerRecord]) -> UsageLedgerSummary {
        UsageLedgerSummary.make(records: records, days: 7, now: start.addingTimeInterval(3600), calendar: utc)
    }

    @Test func claudeRevisionsAndPrivacy() throws {
        let first = Self.claude(
            0, type: "assistant",
            message: [
                "id": "message-a", "model": "model-a", "content": [["type": "text", "text": "PRIVATE-REPLY"]],
                "usage": [
                    "input_tokens": 100, "output_tokens": 10, "cache_read_input_tokens": 300,
                    "cache_creation_input_tokens": 20,
                ],
            ])
        let final = Self.claude(
            1, type: "assistant",
            message: [
                "id": "message-a", "model": "model-a", "content": [["type": "text", "text": "PRIVATE-REPLY"]],
                "usage": [
                    "input_tokens": 100, "output_tokens": 30, "cache_read_input_tokens": 300,
                    "cache_creation_input_tokens": 20,
                ],
            ])
        let records = UsageLedgerParser.parse(text: first + "\n" + final, agent: .claude, sourceID: "private-source")
        let report = Self.report(records)
        #expect(report.totalTokens == 150)
        #expect(report.cacheHitRate == 300.0 / 420.0)
        #expect(report.projects.first?.name == "Project")
        let encoded = String(data: try JSONEncoder().encode(records), encoding: .utf8)!
        for secret in ["PRIVATE-REPLY", "private-source", "/private/client", "session-a", "message-a"] {
            #expect(!encoded.contains(secret))
        }
        let copy = UsageLedgerParser.parse(text: final, agent: .claude, sourceID: "copied-source")
        #expect(Self.report(records + copy).totalTokens == 150)
    }

    @Test func codexCumulativeDeltasCopiesAndReset() {
        let meta = Self.line(["type": "session_meta", "payload": ["id": "codex-session", "cwd": "/home/me/API"]])
        let model = Self.line(["type": "turn_context", "payload": ["model": "gpt-test"]])
        func tokens(_ second: Double, _ input: Int, _ cached: Int, _ output: Int) -> String {
            Self.line([
                "type": "event_msg", "timestamp": Self.stamp(second),
                "payload": [
                    "type": "token_count",
                    "info": [
                        "total_token_usage": [
                            "input_tokens": input, "cached_input_tokens": cached, "output_tokens": output,
                        ]
                    ],
                ],
            ])
        }
        let text = [
            meta, model, tokens(0, 100, 40, 10), tokens(1, 100, 40, 10), tokens(2, 150, 60, 20), tokens(3, 20, 5, 3),
        ].joined(separator: "\n")
        let records = UsageLedgerParser.parse(text: text, agent: .codex, sourceID: "one")
        // 150 - 60 + 20, then a reset segment 20 - 5 + 3.
        #expect(Self.report(records).totalTokens == 128)
        #expect(
            Self.report(records + UsageLedgerParser.parse(text: text, agent: .codex, sourceID: "copy")).totalTokens
                == 128)
        #expect(Self.report(records).models.first?.name == "gpt-test")
    }

    @Test func sparseAndDenseTenMinuteToolsAgree() {
        let call = Self.claude(
            0, type: "assistant",
            message: [
                "id": "tool-msg",
                "content": [
                    ["type": "tool_use", "id": "call-a", "name": "Bash", "input": ["command": "PRIVATE-COMMAND"]]
                ],
            ])
        let result = Self.claude(
            600, type: "user",
            message: ["content": [["type": "tool_result", "tool_use_id": "call-a", "content": "PRIVATE-RESULT"]]])
        let sparse = UsageLedgerParser.parse(text: call + "\n" + result, agent: .claude, sourceID: "source")
        let chatter = (1..<10).map {
            Self.claude(
                Double($0 * 60), type: "assistant",
                message: ["id": "think-\($0)", "content": [["type": "thinking", "thinking": "PRIVATE-THOUGHT"]]])
        }
        let dense = UsageLedgerParser.parse(
            text: ([call] + chatter + [result]).joined(separator: "\n"), agent: .claude, sourceID: "source")
        #expect(Self.report(sparse).activeSeconds == 600)
        #expect(Self.report(dense).activeSeconds == 600)
        #expect(Self.report(sparse).tools.first?.name == "Bash")
        #expect(Self.report(sparse).tools.first?.value == 1)
    }

    @Test func unionAndQuestionWaitSubtraction() {
        func event(_ time: Double, _ name: String, _ id: String, result: Bool = false) -> String {
            Self.claude(
                time, type: result ? "user" : "assistant",
                message: [
                    "content": [
                        result
                            ? ["type": "tool_result", "tool_use_id": id] : ["type": "tool_use", "id": id, "name": name]
                    ]
                ])
        }
        let text = [
            event(0, "Bash", "a"), event(100, "Write", "b"), event(200, "AskUserQuestion", "q"),
            event(400, "", "q", result: true), event(500, "", "b", result: true), event(600, "", "a", result: true),
        ].joined(separator: "\n")
        #expect(Self.report(UsageLedgerParser.parse(text: text, agent: .claude, sourceID: "x")).activeSeconds == 400)
    }

    @Test func fallbackDoesNotBridgeAnIdleNightOrStretchOpenActivity() {
        let text = [
            Self.claude(0, type: "assistant", message: ["content": "one"]),
            Self.claude(600, type: "assistant", message: ["content": "two"]),
        ].joined(separator: "\n")
        #expect(Self.report(UsageLedgerParser.parse(text: text, agent: .claude, sourceID: "x")).activeSeconds == 300)
        let isolated = Self.claude(0, type: "assistant", message: ["content": "one"])
        #expect(Self.report(UsageLedgerParser.parse(text: isolated, agent: .claude, sourceID: "x")).activeSeconds == 0)
    }

    @Test func calendarSplitsMidnightAndRepeatedDSTHour() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        let iso = ISO8601DateFormatter()
        let beginning = iso.date(from: "2026-11-01T05:30:00Z")!
        let end = iso.date(from: "2026-11-01T07:30:00Z")!
        let work = UsageLedgerRecord(
            id: "work", session: "session", agent: .claude, project: "Project", model: "Unknown", date: beginning,
            kind: .work, end: end)
        let report = UsageLedgerSummary.make(records: [work], days: 7, now: end, calendar: cal)
        #expect(report.activeSeconds == 7200)
        #expect(report.heatmap.reduce(0) { $0 + $1.seconds } == 7200)
        #expect(report.heatmap.filter { $0.hour == 1 }.reduce(0) { $0 + $1.seconds } == 5400)
        let midnight = iso.date(from: "2026-10-15T00:00:00Z")!
        let split = UsageLedgerRecord(
            id: "split", session: "session", agent: .codex, project: "Project", model: "Unknown",
            date: midnight.addingTimeInterval(-60), kind: .work, end: midnight.addingTimeInterval(60))
        let daily = UsageLedgerSummary.make(
            records: [split], days: 7, now: midnight.addingTimeInterval(100), calendar: Self.utc)
        #expect(daily.days.filter { $0.activeSeconds > 0 }.count == 2)
        #expect(daily.days.count == 14)
    }

    @Test func missingMetadataAndInvalidCountersAreSafe() {
        let text = Self.line([
            "type": "assistant", "timestamp": Self.stamp(0),
            "message": ["usage": ["input_tokens": 0, "output_tokens": 12]],
        ])
        let report = Self.report(UsageLedgerParser.parse(text: text, agent: .claude, sourceID: "x"))
        #expect(report.totalTokens == 12)
        #expect(report.projects.first?.name == "Unknown")
        #expect(report.cacheHitRate == nil)
    }
    @Test func codexQuestionWaitDoesNotCountAsWork() {
        func event(_ t: Double, _ kind: String) -> String {
            Self.line(["type": "event_msg", "timestamp": Self.stamp(t), "payload": ["type": kind]])
        }
        let call = Self.line([
            "type": "response_item", "timestamp": Self.stamp(100),
            "payload": [
                "type": "function_call", "call_id": "question", "name": "request_user_input",
                "arguments": "PRIVATE-PROMPT",
            ],
        ])
        let result = Self.line([
            "type": "response_item", "timestamp": Self.stamp(500),
            "payload": ["type": "function_call_output", "call_id": "question", "output": "PRIVATE-ANSWER"],
        ])
        let records = UsageLedgerParser.parse(
            text: [event(0, "task_started"), call, result, event(600, "task_complete")].joined(separator: "\n"),
            agent: .codex, sourceID: "x")
        #expect(Self.report(records).activeSeconds == 200)
    }

    @Test func partialCodexCopiesAreMergedBeforeDifferencing() {
        let meta = Self.line(["type": "session_meta", "payload": ["id": "one-session"]])
        func row(_ t: Double, _ total: Int) -> String {
            Self.line([
                "type": "event_msg", "timestamp": Self.stamp(t),
                "payload": [
                    "type": "token_count", "info": ["total_token_usage": ["input_tokens": total, "output_tokens": 0]],
                ],
            ])
        }
        let whole = UsageLedgerParser.parse(
            text: [meta, row(0, 100), row(1, 150)].joined(separator: "\n"), agent: .codex, sourceID: "whole")
        let partial = UsageLedgerParser.parse(
            text: [meta, row(1, 150)].joined(separator: "\n"), agent: .codex, sourceID: "partial")
        #expect(Self.report(whole + partial).totalTokens == 150)
        #expect(Self.report(partial + whole).totalTokens == 150)
    }

    @Test func oldOrPartialClaudeCopiesCannotUndoCompleteUsage() {
        func row(_ t: Double, _ usage: [String: Any]) -> String {
            Self.claude(t, type: "assistant", message: ["id": "shared-message", "usage": usage])
        }
        let newest = UsageLedgerParser.parse(
            text: row(2, ["input_tokens": 100, "output_tokens": 30]), agent: .claude, sourceID: "new")
        let old = UsageLedgerParser.parse(
            text: row(1, ["input_tokens": 100, "output_tokens": 10]), agent: .claude, sourceID: "old")
        let partial = UsageLedgerParser.parse(text: row(3, ["output_tokens": 30]), agent: .claude, sourceID: "partial")
        #expect(Self.report(newest + old + partial).totalTokens == 130)
        #expect(Self.report(partial + old + newest).totalTokens == 130)
    }

    @Test func invalidNumericObservationsAreRejected() {
        for invalid: Any in [-1, 1e100, true, 1.5] {
            let row = Self.claude(
                0, type: "assistant", message: ["usage": ["input_tokens": invalid, "output_tokens": 12]])
            #expect(Self.report(UsageLedgerParser.parse(text: row, agent: .claude, sourceID: "x")).totalTokens == 0)
        }
    }

    @Test func injectedUserMetadataDoesNotCreateWork() {
        let injected = Self.claude(
            0, type: "user", message: ["content": "<local-command-caveat>PRIVATE-METADATA</local-command-caveat>"])
        let answer = Self.claude(600, type: "assistant", message: ["content": "answer", "stop_reason": "end_turn"])
        #expect(
            Self.report(UsageLedgerParser.parse(text: injected + "\n" + answer, agent: .claude, sourceID: "x"))
                .activeSeconds == 0)
    }

}
