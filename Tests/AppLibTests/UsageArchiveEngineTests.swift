import Foundation
import Testing

@testable import AppLib

struct UsageArchiveEngineTests {
    @Test func dailyScheduleAndRestartOnlySettleOnce() async throws {
        let root = try UsageLedgerStorageTests().folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = UsageArchiveDatabase(url: root.appendingPathComponent("archive.sqlite"))
        let engine = UsageArchiveEngine(
            database: db, claudeRoot: root.appendingPathComponent("claude"),
            codexRoot: root.appendingPathComponent("codex"), legacyURL: root.appendingPathComponent("history.jsonl"),
            throttle: false)
        let today = UsageLedgerTests.utc.startOfDay(for: UsageLedgerTests.start)
        _ = try await engine.run(
            mode: .automatic, now: today.addingTimeInterval(3600), calendar: UsageLedgerTests.utc, startup: true)
        #expect(
            try await !engine.isDue(now: today.addingTimeInterval(7200), calendar: UsageLedgerTests.utc, startup: true))
        var shifted = UsageLedgerTests.utc
        shifted.timeZone = TimeZone(secondsFromGMT: 3600)!
        #expect(try await engine.isDue(now: today.addingTimeInterval(3600), calendar: shifted))
        #expect(try await !engine.isDue(now: today.addingTimeInterval(86400 + 7200), calendar: UsageLedgerTests.utc))
        #expect(try await engine.isDue(now: today.addingTimeInterval(86400 + 10800), calendar: UsageLedgerTests.utc))
        #expect(
            try await engine.isDue(
                now: today.addingTimeInterval(86400 * 3), calendar: UsageLedgerTests.utc, startup: true))
    }
}

extension UsageArchiveEngineTests {
    @Test func legacyImportCannotMarkUnscannedYesterdayCompleteAndZoneChangesAreDue() async throws {
        let root = try UsageLedgerStorageTests().folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("history.jsonl")
        var bytes = try JSONEncoder().encode(UsageLedgerStorageTests().record())
        bytes.append(10)
        try bytes.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let db = UsageArchiveDatabase(url: root.appendingPathComponent("archive.sqlite"))
        let engine = UsageArchiveEngine(
            database: db, claudeRoot: root.appendingPathComponent("claude"),
            codexRoot: root.appendingPathComponent("codex"), legacyURL: file, throttle: false)
        let now = UsageLedgerTests.start.addingTimeInterval(86400)
        _ = try await engine.run(mode: .legacy, now: now, calendar: UsageLedgerTests.utc)
        #expect(try await engine.lastSettlement(calendar: UsageLedgerTests.utc) == nil)
        #expect(try await engine.isDue(now: now, calendar: UsageLedgerTests.utc, startup: true))
        _ = try await engine.run(mode: .automatic, now: now, calendar: UsageLedgerTests.utc, startup: true)
        var changed = UsageLedgerTests.utc
        changed.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        #expect(try await engine.isDue(now: now, calendar: changed, startup: true))
    }
}

extension UsageArchiveEngineTests {
    @Test func firstFilePublishesPartialArchivesBeforeRemainingSettlement() async throws {
        let root = try UsageLedgerStorageTests().folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("claude")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        for i in 0..<2 {
            let file = source.appendingPathComponent("\(i).jsonl")
            let text =
                UsageLedgerTests.claude(
                    0, type: "assistant", message: ["id": "\(i)", "usage": ["input_tokens": 100, "output_tokens": 0]])
                + "\n"
            let padding =
                UsageLedgerTests.line(["type": "progress", "padding": String(repeating: "x", count: 800_000)]) + "\n"
            try Data((text + padding).utf8).write(to: file)
        }
        let db = UsageArchiveDatabase(url: root.appendingPathComponent("archive.sqlite"))
        let engine = UsageArchiveEngine(
            database: db, claudeRoot: source, codexRoot: root.appendingPathComponent("none"),
            legacyURL: root.appendingPathComponent("none"), throttle: false)
        let task = Task {
            try await engine.run(
                mode: .automatic, now: UsageLedgerTests.start.addingTimeInterval(86400), calendar: UsageLedgerTests.utc,
                force: true
            ) { progress in
                if progress.archivesUpdated {
                    let partial = try? await db.summary(
                        days: 7, now: UsageLedgerTests.start.addingTimeInterval(86400), calendar: UsageLedgerTests.utc)
                    #expect(partial?.totalTokens == 100)
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        }
        do {
            _ = try await task.value
            Issue.record("Expected cancellation after partial archive")
        } catch is CancellationError {}
        let checkpoints = try await [
            db.checkpoint(source: UsageLedgerRecord.identity(source.appendingPathComponent("0.jsonl").path)),
            db.checkpoint(source: UsageLedgerRecord.identity(source.appendingPathComponent("1.jsonl").path)),
        ]
        let saved = try #require(checkpoints.compactMap { $0 }.first)
        let cursor = try #require(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        #expect(cursor["finished"] as? Bool == false)
        #expect(try await engine.lastSettlement(calendar: UsageLedgerTests.utc) == nil)
        #expect(
            try await db.summary(
                days: 7, now: UsageLedgerTests.start.addingTimeInterval(86400), calendar: UsageLedgerTests.utc
            ).totalTokens == 100)
    }
}

extension UsageArchiveEngineTests {
    @Test func partialNewDayCounterIncludesItsPreWindowBaseline() async throws {
        let root = try UsageLedgerStorageTests().folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("codex")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let rows: [[String: Any]] = [
            ["type": "session_meta", "payload": ["id": "session", "cwd": "/work/Project"]],
            [
                "type": "event_msg", "timestamp": UsageLedgerTests.stamp(-86400 * 10),
                "payload": [
                    "type": "token_count",
                    "info": [
                        "total_token_usage": ["input_tokens": 100, "output_tokens": 10, "cached_input_tokens": 20]
                    ],
                ],
            ],
            [
                "type": "event_msg", "timestamp": UsageLedgerTests.stamp(0),
                "payload": [
                    "type": "token_count",
                    "info": [
                        "total_token_usage": ["input_tokens": 150, "output_tokens": 30, "cached_input_tokens": 40]
                    ],
                ],
            ],
            ["type": "progress", "padding": String(repeating: "x", count: 800_000)],
        ]
        let text = rows.map(UsageLedgerTests.line).joined(separator: "\n") + "\n"
        try Data(text.utf8).write(to: source.appendingPathComponent("source.jsonl"))
        let db = UsageArchiveDatabase(url: root.appendingPathComponent("archive.sqlite"))
        let engine = UsageArchiveEngine(
            database: db, claudeRoot: root.appendingPathComponent("none"), codexRoot: source,
            legacyURL: root.appendingPathComponent("none"), throttle: false)
        let task = Task {
            try await engine.run(
                mode: .automatic, now: UsageLedgerTests.start.addingTimeInterval(86400), calendar: UsageLedgerTests.utc,
                force: true
            ) { progress in
                if progress.archivesUpdated {
                    let partial = try? await db.summary(
                        days: 7, now: UsageLedgerTests.start.addingTimeInterval(86400), calendar: UsageLedgerTests.utc)
                    #expect(partial?.totalTokens == 50)
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        }
        do {
            _ = try await task.value
            Issue.record("Expected cancellation after partial archive")
        } catch is CancellationError {}
    }
}
