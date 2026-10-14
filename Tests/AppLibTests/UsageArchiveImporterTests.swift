import Foundation
import Shared
import Testing

@testable import AppLib

struct UsageArchiveImporterTests {
    @Test func unchangedRestartReadsZeroAndAppendReadsOnlySuffix() async throws {
        let root = try UsageLedgerStorageTests().folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("source.jsonl")
        let first =
            UsageLedgerTests.claude(
                0, type: "assistant", message: ["id": "a", "usage": ["input_tokens": 100, "output_tokens": 0]]) + "\n"
        let second =
            UsageLedgerTests.claude(
                10, type: "assistant", message: ["id": "b", "usage": ["input_tokens": 50, "output_tokens": 0]]) + "\n"
        try Data(first.utf8).write(to: url)
        let db = UsageArchiveDatabase(url: root.appendingPathComponent("archive.sqlite"))
        let importer = UsageArchiveImporter(database: db, throttle: false)
        _ = try await importer.importFile(url, agent: .claude, cutoff: nil)
        let restarted = UsageArchiveImporter(
            database: UsageArchiveDatabase(url: root.appendingPathComponent("archive.sqlite")), throttle: false)
        #expect(try await restarted.importFile(url, agent: .claude, cutoff: nil).bytesRead == 0)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(second.utf8))
        try handle.close()
        let append = try await restarted.importFile(url, agent: .claude, cutoff: nil)
        #expect(append.parsedBytes == second.utf8.count)
        #expect(
            try await db.records(start: UsageLedgerTests.start, end: UsageLedgerTests.start.addingTimeInterval(100))
                .filter { $0.kind == .tokens }.reduce(0) { $0 + $1.tokens } == 150)
    }
    @Test func automaticPartialCoverageRewindsForExplicitHistory() async throws {
        let root = try UsageLedgerStorageTests().folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("source.jsonl")
        let rows =
            UsageLedgerTests.claude(
                -86400 * 10, type: "assistant",
                message: ["id": "old", "usage": ["input_tokens": 100, "output_tokens": 0]]) + "\n"
            + UsageLedgerTests.claude(
                0, type: "assistant", message: ["id": "new", "usage": ["input_tokens": 50, "output_tokens": 0]]) + "\n"
        try Data(rows.utf8).write(to: file)
        let db = UsageArchiveDatabase(url: root.appendingPathComponent("archive.sqlite"))
        let importer = UsageArchiveImporter(database: db, throttle: false)
        _ = try await importer.importFile(
            file, agent: .claude, cutoff: UsageLedgerTests.start.addingTimeInterval(-86400))
        #expect(
            try await db.records(
                start: UsageLedgerTests.start.addingTimeInterval(-86400 * 20),
                end: UsageLedgerTests.start.addingTimeInterval(100)
            ).filter { $0.kind == .tokens }.count == 1)
        #expect(try await importer.importFile(file, agent: .claude, cutoff: nil).parsedBytes > 0)
        #expect(
            try await db.records(
                start: UsageLedgerTests.start.addingTimeInterval(-86400 * 20),
                end: UsageLedgerTests.start.addingTimeInterval(100)
            ).filter { $0.kind == .tokens }.count == 2)
    }
}

extension UsageArchiveImporterTests {
    @Test func partialLineReplacementAndTruncationKeepCounts() async throws {
        let root = try UsageLedgerStorageTests().folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("source.jsonl")
        let db = UsageArchiveDatabase(url: root.appendingPathComponent("archive.sqlite"))
        let importer = UsageArchiveImporter(database: db, throttle: false)
        let first = UsageLedgerTests.claude(
            0, type: "assistant", message: ["id": "a", "usage": ["input_tokens": 100, "output_tokens": 0]])
        let second = UsageLedgerTests.claude(
            10, type: "assistant", message: ["id": "b", "usage": ["input_tokens": 50, "output_tokens": 0]])
        try Data((first + "\n" + String(second.prefix(30))).utf8).write(to: file)
        _ = try await importer.importFile(file, agent: .claude, cutoff: nil)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((String(second.dropFirst(30)) + "\n").utf8))
        try handle.close()
        _ = try await importer.importFile(file, agent: .claude, cutoff: nil)
        // Atomic replacement with a shorter prefix does not erase durable observations.
        try Data((first + "\n").utf8).write(to: file, options: .atomic)
        _ = try await importer.importFile(file, agent: .claude, cutoff: nil)
        try Data((second + "\n").utf8).write(to: file)
        _ = try await importer.importFile(file, agent: .claude, cutoff: nil)
        let records = try await db.records(
            start: UsageLedgerTests.start, end: UsageLedgerTests.start.addingTimeInterval(100))
        #expect(records.filter { $0.kind == .tokens }.reduce(0) { $0 + $1.tokens } == 150)
    }
    @Test func invalidAndOversizedWarningsSurviveCancellationAndZeroByteRestart() async throws {
        let root = try UsageLedgerStorageTests().folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("source.jsonl")
        let db = UsageArchiveDatabase(url: root.appendingPathComponent("archive.sqlite"))
        try Data(("not-json\n" + String(repeating: "x", count: 1_200_000) + "\n").utf8).write(to: file)
        let importer = UsageArchiveImporter(database: db, throttle: false)
        let task = Task {
            try await importer.importFile(file, agent: .claude, cutoff: nil) { _ in
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {}
        let result = try await importer.importFile(file, agent: .claude, cutoff: nil)
        #expect(result.rejected == 2)
        let restart = try await UsageArchiveImporter(database: db, throttle: false).importFile(
            file, agent: .claude, cutoff: nil)
        #expect(restart.bytesRead == 0 && restart.rejected == 2)
    }
    @Test func legacyImportIsReadOnlyDeduplicatedAndRejectsFutureVersions() async throws {
        let root = try UsageLedgerStorageTests().folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("legacy.jsonl")
        var bytes = try JSONEncoder().encode(UsageLedgerStorageTests().record())
        bytes.append(10)
        try bytes.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let db = UsageArchiveDatabase(url: root.appendingPathComponent("archive.sqlite"))
        let importer = UsageArchiveImporter(database: db, throttle: false)
        _ = try await importer.importFile(file, agent: .claude, cutoff: nil, legacy: true)
        #expect(try await importer.importFile(file, agent: .claude, cutoff: nil, legacy: true).bytesRead == 0)
        #expect(try Data(contentsOf: file) == bytes)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"version\":999}\n".utf8))
        try handle.close()
        await #expect(throws: (any Error).self) {
            _ = try await importer.importFile(file, agent: .claude, cutoff: nil, legacy: true)
        }
        #expect(try Data(contentsOf: file) == bytes + Data("{\"version\":999}\n".utf8))
    }
}
