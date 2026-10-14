import Foundation

@MainActor
public final class UsageLedgerService: ObservableObject {
    @Published private(set) var summary = UsageLedgerSummary()
    @Published private(set) var days = 30
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastSuccessfulScan: Date?

    private let store: UsageLedgerStore
    @Published private(set) var completedFiles = 0
    @Published private(set) var totalFiles = 0

    private typealias Batch = @Sendable (UsageLedgerCollector.Scan) async throws -> Void
    private let collect: @Sendable (@escaping Batch) async throws -> UsageLedgerCollector.Scan
    private let now: @Sendable () -> Date
    private let calendar: Calendar
    private var loop: Task<Void, Never>?
    private var generation = 0

    public convenience init(
        claudeRoot: URL = URL(fileURLWithPath: NSHomeDirectory() + "/.claude/projects"),
        codexRoot: URL = URL(fileURLWithPath: NSHomeDirectory() + "/.codex/sessions"),
        ledgerURL: URL = URL(fileURLWithPath: NSHomeDirectory() + "/.zackeyes/usage/history-v1.jsonl")
    ) {
        let collector = UsageLedgerCollector(claudeRoot: claudeRoot, codexRoot: codexRoot)
        self.init(store: UsageLedgerStore(url: ledgerURL), collectBatches: { try await collector.scan(onBatch: $0) })
    }

    convenience init(
        store: UsageLedgerStore, collect: @escaping @Sendable () async throws -> UsageLedgerCollector.Scan,
        now: @escaping @Sendable () -> Date = { Date() }, calendar: Calendar = .current
    ) {
        self.init(store: store, collectBatches: { _ in try await collect() }, now: now, calendar: calendar)
    }

    init(
        store: UsageLedgerStore,
        collectBatches:
            @escaping @Sendable (@escaping @Sendable (UsageLedgerCollector.Scan) async throws -> Void) async throws ->
            UsageLedgerCollector.Scan,
        now: @escaping @Sendable () -> Date = { Date() }, calendar: Calendar = .current
    ) {
        self.store = store
        self.collect = collectBatches
        self.now = now
        self.calendar = calendar
    }

    public func start() {
        stop()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }
    public func stop() {
        generation += 1
        loop?.cancel()
        loop = nil
        isLoading = false
    }
    func setDays(_ value: Int) async {
        guard [7, 30, 90].contains(value) else { return }
        days = value
        if isLoading {
            do { try await publishSummary(token: generation) } catch is CancellationError {} catch {
                errorMessage = error.localizedDescription
            }
        } else {
            await refresh()
        }
    }
    func refresh() async {
        guard !isLoading else { return }
        let token = generation
        isLoading = true
        defer { if token == generation { isLoading = false } }
        do {
            // Persisted history remains usable while a cold scan/backfill runs.
            try await publishSummary(token: token)
            completedFiles = 0
            totalFiles = 0
            let scan = try await collect { [weak self] batch in
                try await self?.accept(batch, token: token)
            }
            try await accept(scan, token: token)
            if errorMessage == nil { lastSuccessfulScan = now() }
        } catch is CancellationError {
            // A dismissed Settings task or shutdown must not publish stale state.
        } catch {
            guard token == generation else { return }
            errorMessage = error.localizedDescription
        }
    }
    private func accept(_ scan: UsageLedgerCollector.Scan, token: Int) async throws {
        try Task.checkCancellation()
        guard token == generation else { throw CancellationError() }
        if !scan.records.isEmpty, try await store.upsert(scan.records) {
            try await publishSummary(token: token)
        }
        let issues = scan.issues + (await store.warnings)
        guard token == generation else { throw CancellationError() }
        completedFiles = scan.scannedFiles
        totalFiles = scan.totalFiles
        errorMessage = issues.isEmpty ? nil : issues.joined(separator: "\n")
    }
    private func publishSummary(token: Int) async throws {
        var selected = days
        var report = try await store.summary(days: selected, now: now(), calendar: calendar)
        while selected != days {
            selected = days
            report = try await store.summary(days: selected, now: now(), calendar: calendar)
        }
        try Task.checkCancellation()
        guard token == generation else { throw CancellationError() }
        summary = report
    }

}
