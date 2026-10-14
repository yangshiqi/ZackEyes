import Foundation

@MainActor
public final class UsageLedgerService: ObservableObject {
    @Published private(set) var summary = UsageLedgerSummary()
    @Published private(set) var days = 30
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastSuccessfulScan: Date?

    private let store: UsageLedgerStore
    private let collect: @Sendable () async throws -> UsageLedgerCollector.Scan
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
        self.init(store: UsageLedgerStore(url: ledgerURL), collect: { try await collector.scan() })
    }

    init(
        store: UsageLedgerStore, collect: @escaping @Sendable () async throws -> UsageLedgerCollector.Scan,
        now: @escaping @Sendable () -> Date = { Date() }, calendar: Calendar = .current
    ) {
        self.store = store
        self.collect = collect
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
        await refresh()
    }
    func refresh() async {
        guard !isLoading else { return }
        let token = generation
        isLoading = true
        defer { if token == generation { isLoading = false } }
        do {
            let scan = try await collect()
            try Task.checkCancellation()
            guard token == generation else { return }
            try await store.upsert(scan.records)
            let issues = scan.issues + (await store.warnings)
            var selected = days
            var report = try await store.summary(days: selected, now: now(), calendar: calendar)
            // A range change while the scan awaited must publish that new range.
            while selected != days {
                selected = days
                report = try await store.summary(days: selected, now: now(), calendar: calendar)
            }
            try Task.checkCancellation()
            guard token == generation else { return }
            summary = report
            errorMessage = issues.isEmpty ? nil : issues.joined(separator: "\n")
            if issues.isEmpty { lastSuccessfulScan = now() }
        } catch is CancellationError {
            // A dismissed Settings task or shutdown must not publish stale state.
        } catch {
            guard token == generation else { return }
            errorMessage = error.localizedDescription
        }
    }
}
