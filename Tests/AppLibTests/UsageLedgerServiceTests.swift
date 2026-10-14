import Foundation
import Testing

@testable import AppLib

private actor LedgerScanGate {
    var calls = 0
    var ready = false
    var continuation: CheckedContinuation<Void, Never>?
    func collect() async -> UsageLedgerCollector.Scan {
        calls += 1
        if !ready { await withCheckedContinuation { continuation = $0 } }
        return UsageLedgerCollector.Scan(records: [UsageLedgerStorageTests().record()], issues: [], parsedFiles: 1)
    }
    func release() {
        ready = true
        continuation?.resume()
        continuation = nil
    }
}

private actor LedgerBatchGate {
    var published = false
    var continuation: CheckedContinuation<Void, Never>?
    func collect(_ publish: @Sendable (UsageLedgerCollector.Scan) async throws -> Void) async throws
        -> UsageLedgerCollector.Scan
    {
        let first = UsageLedgerCollector.Scan(
            records: [UsageLedgerStorageTests().record()], issues: [], parsedFiles: 1, scannedFiles: 1, totalFiles: 2)
        try await publish(first)
        published = true
        await withCheckedContinuation { continuation = $0 }
        return UsageLedgerCollector.Scan(
            records: first.records, issues: [], parsedFiles: 2, scannedFiles: 2, totalFiles: 2)
    }
    func release() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
struct UsageLedgerServiceTests {
    @Test func firstCollectionAndRangeChanges() async throws {
        let root = try UsageLedgerStorageTests().folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = LedgerScanGate()
        await gate.release()
        let service = UsageLedgerService(
            store: UsageLedgerStore(url: root.appendingPathComponent("ledger.jsonl")),
            collect: { await gate.collect() }, now: { UsageLedgerTests.start.addingTimeInterval(3600) },
            calendar: UsageLedgerTests.utc)
        await service.refresh()
        #expect(service.summary.totalTokens == 100)
        #expect(service.lastSuccessfulScan != nil)
        #expect(service.errorMessage == nil)
        await service.setDays(7)
        #expect(service.days == 7)
        #expect(service.summary.days.count == 14)
        await service.setDays(90)
        #expect(service.summary.days.count == 180)
    }
    @Test func savedHistoryAppearsBeforeSlowCollectionFinishes() async throws {
        let root = try UsageLedgerStorageTests().folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = UsageLedgerStore(url: root.appendingPathComponent("ledger.jsonl"))
        try await store.upsert([UsageLedgerStorageTests().record()])
        let gate = LedgerScanGate()
        let service = UsageLedgerService(
            store: store, collect: { await gate.collect() },
            now: { UsageLedgerTests.start.addingTimeInterval(3600) }, calendar: UsageLedgerTests.utc)
        let work = Task { await service.refresh() }
        for _ in 0..<1000 {
            if await gate.calls > 0 { break }
            await Task.yield()
        }
        #expect(service.isLoading)
        #expect(service.summary.totalTokens == 100)
        await gate.release()
        await work.value
    }
    @Test func firstBatchIsDurableAndVisibleBeforeBackfillCompletes() async throws {
        let root = try UsageLedgerStorageTests().folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("ledger.jsonl")
        let gate = LedgerBatchGate()
        let service = UsageLedgerService(
            store: UsageLedgerStore(url: url),
            collectBatches: { try await gate.collect($0) },
            now: { UsageLedgerTests.start.addingTimeInterval(3600) }, calendar: UsageLedgerTests.utc)
        let work = Task { await service.refresh() }
        for _ in 0..<1000 {
            if await gate.published { break }
            await Task.yield()
        }
        #expect(service.isLoading)
        #expect(service.summary.totalTokens == 100)
        #expect(service.completedFiles == 1 && service.totalFiles == 2)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(service.lastSuccessfulScan == nil)
        await service.setDays(7)
        #expect(service.summary.days.count == 14)
        #expect(service.isLoading)
        await gate.release()
        await work.value
        #expect(!service.isLoading && service.completedFiles == 2)
        #expect(service.summary.totalTokens == 100)
        #expect(service.lastSuccessfulScan != nil)
    }
    @Test func stopPreventsStalePublicationAndOverlappingScan() async throws {
        let root = try UsageLedgerStorageTests().folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = LedgerScanGate()
        let url = root.appendingPathComponent("ledger.jsonl")
        let service = UsageLedgerService(
            store: UsageLedgerStore(url: url), collect: { await gate.collect() },
            now: { UsageLedgerTests.start.addingTimeInterval(3600) }, calendar: UsageLedgerTests.utc)
        let work = Task { await service.refresh() }
        for _ in 0..<1000 {
            if await gate.calls > 0 { break }
            await Task.yield()
        }
        #expect(service.isLoading)
        await service.refresh()
        #expect(await gate.calls == 1)
        service.stop()
        await gate.release()
        await work.value
        #expect(!service.isLoading)
        #expect(service.summary.totalTokens == 0)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
    @Test func persistenceFailuresAndPartialScansAreVisible() async throws {
        let root = try UsageLedgerStorageTests().folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("ledger.jsonl")
        try Data("{\"version\":999}\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let gate = LedgerScanGate()
        await gate.release()
        let service = UsageLedgerService(store: UsageLedgerStore(url: url), collect: { await gate.collect() })
        await service.refresh()
        #expect(service.errorMessage?.contains("unsupported") == true)
        #expect(service.lastSuccessfulScan == nil)
        let partial = UsageLedgerService(
            store: UsageLedgerStore(url: root.appendingPathComponent("other.jsonl")),
            collect: { .init(records: [], issues: ["Some transcripts were unreadable."], parsedFiles: 0) })
        await partial.refresh()
        #expect(partial.errorMessage?.contains("unreadable") == true)
        #expect(partial.lastSuccessfulScan == nil)
    }
}
