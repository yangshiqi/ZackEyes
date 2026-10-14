import Foundation
import Shared
import Testing

@testable import AppLib

struct UsageLedgerStorageTests {
    func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func record(_ tokens: Int = 100, at: Date = UsageLedgerTests.start) -> UsageLedgerRecord {
        UsageLedgerRecord(
            id: "record", session: "session", agent: .claude, project: "Project", model: "model", date: at,
            kind: .tokens, input: tokens)
    }
    @Test func repeatedRestartedAndRevisedWritesRemainAppendOnly() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("usage/history.jsonl")
        let store = UsageLedgerStore(url: url)
        try await store.upsert([record()])
        let original = try Data(contentsOf: url)
        try await store.upsert([record()])
        #expect(try Data(contentsOf: url) == original)
        try await store.upsert([record(150, at: UsageLedgerTests.start.addingTimeInterval(1))])
        #expect(try Data(contentsOf: url).starts(with: original))
        let restored = UsageLedgerStore(url: url)
        let summary = try await restored.summary(
            days: 7, now: UsageLedgerTests.start.addingTimeInterval(100), calendar: UsageLedgerTests.utc)
        #expect(summary.totalTokens == 150)
        // An older copy found after restart cannot undo the final count.
        try await restored.upsert([record()])
        #expect(
            try await restored.summary(
                days: 7, now: UsageLedgerTests.start.addingTimeInterval(100), calendar: UsageLedgerTests.utc
            ).totalTokens == 150)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }
    @Test func interruptedTailDoesNotPoisonFutureRecords() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("ledger.jsonl")
        try Data("{\"version\":1,\"id\":\"interrupted".utf8).write(to: url)
        let store = UsageLedgerStore(url: url)
        try await store.upsert([record()])
        let reloaded = UsageLedgerStore(url: url)
        #expect(
            try await reloaded.summary(
                days: 7, now: UsageLedgerTests.start.addingTimeInterval(1), calendar: UsageLedgerTests.utc
            ).totalTokens == 100)
        #expect(!(await reloaded.warnings).isEmpty)
    }
    @Test func unsupportedVersionAndSymlinkAreNotOverwritten() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("ledger.jsonl")
        let original = Data("{\"version\":999}\n".utf8)
        try original.write(to: url)
        await #expect(throws: (any Error).self) { try await UsageLedgerStore(url: url).upsert([record()]) }
        #expect(try Data(contentsOf: url) == original)
        let link = root.appendingPathComponent("link.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        await #expect(throws: (any Error).self) { try await UsageLedgerStore(url: link).upsert([record()]) }
        #expect(try Data(contentsOf: url) == original)
    }
    @Test func collectorCachesNestedTranscriptsAndRetainsDeletedHistory() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let claude = root.appendingPathComponent("claude/Project/session/subagents")
        let codex = root.appendingPathComponent("codex")
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        let file = claude.appendingPathComponent("agent.jsonl")
        let line = UsageLedgerTests.claude(
            0, type: "assistant", message: ["id": "one", "usage": ["input_tokens": 100, "output_tokens": 20]])
        try Data(line.utf8).write(to: file)
        let collector = UsageLedgerCollector(claudeRoot: root.appendingPathComponent("claude"), codexRoot: codex)
        let first = try await collector.scan()
        #expect(first.parsedFiles == 1)
        #expect(first.records.reduce(0) { $0 + $1.tokens } == 120)
        #expect(try await collector.scan().parsedFiles == 0)
        let store = UsageLedgerStore(url: root.appendingPathComponent("ledger.jsonl"))
        try await store.upsert(first.records)
        try FileManager.default.removeItem(at: file)
        try await store.upsert(collector.scan().records)
        #expect(
            try await store.summary(
                days: 7, now: UsageLedgerTests.start.addingTimeInterval(1), calendar: UsageLedgerTests.utc
            ).totalTokens == 120)
    }
    @Test func invalidSourceObservationsAreReportedAndLinkedSourcesSkipped() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let claude = root.appendingPathComponent("claude")
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        let invalid = UsageLedgerTests.claude(
            0, type: "assistant", message: ["usage": ["input_tokens": 1e100, "output_tokens": 12]])
        try Data(invalid.utf8).write(to: claude.appendingPathComponent("invalid.jsonl"))
        let outside = root.appendingPathComponent("secret.jsonl")
        try Data(
            UsageLedgerTests.claude(
                0, type: "assistant", message: ["usage": ["input_tokens": 900, "output_tokens": 10]]
            ).utf8
        ).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: claude.appendingPathComponent("link.jsonl"), withDestinationURL: outside)
        let scan = try await UsageLedgerCollector(claudeRoot: claude, codexRoot: root.appendingPathComponent("codex"))
            .scan()
        #expect(scan.records.filter { $0.kind == .tokens }.isEmpty)
        #expect(!scan.issues.isEmpty)
    }

}
