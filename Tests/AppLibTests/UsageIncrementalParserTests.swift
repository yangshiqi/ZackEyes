import Foundation
import Shared
import Testing

@testable import AppLib

struct UsageIncrementalParserTests {
    @Test func restartPreservesWorkQuestionAndCounterStateWithoutContent() throws {
        let stamp = "2026-10-13T10:00:00Z"
        let rows: [[String: Any]] = [
            [
                "type": "user", "timestamp": stamp, "sessionId": "RAW-SESSION", "cwd": "/PRIVATE-PATH/Project",
                "message": ["content": "PRIVATE-PROMPT"],
            ],
            [
                "type": "assistant", "timestamp": "2026-10-13T10:01:00Z",
                "message": [
                    "id": "RAW-MESSAGE", "model": "model",
                    "content": [
                        [
                            "type": "tool_use", "id": "RAW-TOOL", "name": "AskUserQuestion",
                            "input": ["question": "PRIVATE-QUESTION"],
                        ]
                    ],
                ],
            ],
            [
                "type": "user", "timestamp": "2026-10-13T10:05:00Z",
                "message": [
                    "content": [["type": "tool_result", "tool_use_id": "RAW-TOOL", "content": "PRIVATE-RESULT"]]
                ],
            ],
            [
                "type": "assistant", "timestamp": "2026-10-13T10:10:00Z",
                "message": [
                    "id": "answer", "stop_reason": "end_turn", "content": "PRIVATE-REPLY",
                    "usage": ["input_tokens": 100, "output_tokens": 20],
                ],
            ],
        ]
        let source = UsageLedgerRecord.identity("source")
        var state = UsageLedgerParser.seed(objects: rows, agent: .claude, sourceID: source)
        let first = UsageLedgerParser.consume(objects: Array(rows.prefix(2)), state: &state)
        let saved = try JSONEncoder().encode(state)
        let text = String(decoding: saved, as: UTF8.self)
        for forbidden in ["PRIVATE", "RAW-SESSION", "RAW-TOOL", "RAW-MESSAGE", "question", "content", "input"] {
            #expect(!text.contains(forbidden))
        }
        state = try JSONDecoder().decode(UsageLedgerParser.State.self, from: saved)
        let rest = UsageLedgerParser.consume(objects: Array(rows.dropFirst(2)), state: &state)
        let full = UsageLedgerParser.parse(text: try lines(rows), agent: .claude, sourceID: source)
        #expect(
            UsageLedgerSummary.make(
                records: first + rest, days: 7, now: UsageLedgerTests.start, calendar: UsageLedgerTests.utc
            ).totalTokens
                == UsageLedgerSummary.make(
                    records: full, days: 7, now: UsageLedgerTests.start, calendar: UsageLedgerTests.utc
                ).totalTokens)
        let merged = Dictionary((first + rest).map { ($0.id, $0) }, uniquingKeysWith: { $1.supersedes($0) ? $1 : $0 })
        #expect(merged == Dictionary(uniqueKeysWithValues: full.map { ($0.id, $0) }))
        #expect(state.rowIndex == rows.count)
    }
    @Test func codexCumulativeMetadataAndResetSurviveChunks() throws {
        let rows: [[String: Any]] = [
            ["type": "session_meta", "payload": ["id": "RAW-CODEX", "cwd": "/work/Project"]],
            ["type": "turn_context", "payload": ["model": "gpt-test"]],
            [
                "type": "event_msg", "timestamp": "2026-10-13T10:00:00Z",
                "payload": [
                    "type": "token_count",
                    "info": [
                        "total_token_usage": ["input_tokens": 100, "output_tokens": 20, "cached_input_tokens": 40]
                    ],
                ],
            ],
            [
                "type": "event_msg", "timestamp": "2026-10-13T11:00:00Z",
                "payload": [
                    "type": "token_count", "info": ["total_token_usage": ["input_tokens": 150, "output_tokens": 40]],
                ],
            ],
        ]
        let source = UsageLedgerRecord.identity("codex")
        var state = UsageLedgerParser.seed(objects: rows, agent: .codex, sourceID: source)
        let a = UsageLedgerParser.consume(objects: Array(rows.prefix(3)), state: &state)
        state = try JSONDecoder().decode(UsageLedgerParser.State.self, from: JSONEncoder().encode(state))
        let b = UsageLedgerParser.consume(objects: Array(rows.dropFirst(3)), state: &state)
        #expect(a + b == UsageLedgerParser.parse(text: try lines(rows), agent: .codex, sourceID: source))
    }
    func lines(_ rows: [[String: Any]]) throws -> String {
        try rows.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(
            separator: "\n") + "\n"
    }
}
