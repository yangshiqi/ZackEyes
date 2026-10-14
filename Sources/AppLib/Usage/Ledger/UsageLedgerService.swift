import Foundation

@MainActor
public final class UsageLedgerService: ObservableObject {
    @Published private(set) var summary = UsageLedgerSummary()
    @Published private(set) var days = 30
    @Published private(set) var isLoading = false
    @Published private(set) var isPaused = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var settledThrough: Date?
    @Published private(set) var progress = UsageArchiveEngine.Progress(phase: "")
    private let database: UsageArchiveDatabase
    private let engine: UsageArchiveEngine
    private let now: @Sendable () -> Date
    private let calendar: @Sendable () -> Calendar
    private var loop: Task<Void, Never>?
    private var job: Task<Void, Never>?
    private var generation = 0
    private var refreshGeneration = 0
    private var mode: UsageArchiveEngine.Mode = .automatic

    public convenience init(
        claudeRoot: URL = URL(fileURLWithPath: NSHomeDirectory() + "/.claude/projects"),
        codexRoot: URL = URL(fileURLWithPath: NSHomeDirectory() + "/.codex/sessions"),
        ledgerURL: URL = URL(fileURLWithPath: NSHomeDirectory() + "/.zackeyes/usage/history-v1.jsonl")
    ) {
        let database = UsageArchiveDatabase(
            url: ledgerURL.deletingLastPathComponent().appendingPathComponent("archive-v1.sqlite"))
        let engine = UsageArchiveEngine(
            database: database, claudeRoot: claudeRoot, codexRoot: codexRoot, legacyURL: ledgerURL)
        self.init(database: database, engine: engine)
    }
    init(
        database: UsageArchiveDatabase, engine: UsageArchiveEngine,
        now: @escaping @Sendable () -> Date = { Date() }, calendar: @escaping @Sendable () -> Calendar = { .current }
    ) {
        self.database = database
        self.engine = engine
        self.now = now
        self.calendar = calendar
    }
    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            await self?.refresh()
            await self?.tick(startup: true)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                if !Task.isCancelled { await self?.tick() }
            }
        }
    }
    public func stop() {
        generation += 1
        loop?.cancel()
        loop = nil
        job?.cancel()
        job = nil
        isLoading = false
    }
    func tick(startup: Bool = false) async {
        guard !isLoading else { return }
        let token = generation
        do {
            isPaused = try await database.metadata("paused") == Data([1])
            if let pending = try await engine.pendingMode(), pending != .automatic {
                mode = pending
                isPaused = true
            }
            guard !isPaused else { return }
            let due = try await engine.isDue(now: now(), calendar: calendar(), startup: startup)
            guard token == generation, !Task.isCancelled else { return }
            if due { begin(.automatic) } else { await refresh() }
        } catch { errorMessage = error.localizedDescription }
    }
    func setDays(_ value: Int) async {
        guard [7, 30, 90].contains(value) else { return }
        days = value
        await refresh()
    }
    /// UI refreshes read only daily blobs, including while an import is running.
    func refresh() async {
        refreshGeneration += 1
        let refreshToken = refreshGeneration
        let token = generation
        do {
            var selected = days
            var zone = calendar()
            var report = try await database.summary(days: selected, now: now(), calendar: zone)
            while selected != days || UsageArchiveDatabase.zone(zone) != UsageArchiveDatabase.zone(calendar()) {
                selected = days
                zone = calendar()
                report = try await database.summary(days: selected, now: now(), calendar: zone)
            }
            let last = try await engine.lastSettlement(calendar: zone)
            guard token == generation, refreshToken == refreshGeneration, !Task.isCancelled, selected == days,
                UsageArchiveDatabase.zone(zone) == UsageArchiveDatabase.zone(calendar())
            else { return }
            summary = report
            settledThrough = last.flatMap { zone.date(byAdding: .day, value: -1, to: $0) }
        } catch is CancellationError {} catch { if token == generation { errorMessage = error.localizedDescription } }
    }
    func updateNow() { begin(.automatic) }
    func importLegacy() { begin(.legacy) }
    func importHistory() { begin(.history) }
    func pause() async {
        isPaused = true
        job?.cancel()
        do { try await database.setMetadata("paused", Data([1])) } catch { errorMessage = error.localizedDescription }
    }
    func resume() { begin(mode) }
    func waitForJob() async { await job?.value }

    private func begin(_ next: UsageArchiveEngine.Mode) {
        guard job == nil else { return }
        mode = next
        isPaused = false
        isLoading = true
        errorMessage = nil
        progress = .init(phase: "Preparing background statistics")
        let token = generation
        let date = now()
        let zone = calendar()
        job = Task(priority: .background) { [weak self] in
            guard let self else { return }
            defer {
                if token == self.generation {
                    self.job = nil
                    self.isLoading = false
                }
            }
            do {
                try Task.checkCancellation()
                try await self.database.setMetadata("paused", Data())
                let outcome = try await self.engine.run(mode: next, now: date, calendar: zone, force: true) {
                    [weak self] progress in
                    await self?.publish(progress, token: token)
                }
                try Task.checkCancellation()
                guard token == self.generation else { return }
                await self.refresh()
                self.errorMessage = outcome.issues.isEmpty ? nil : outcome.issues.joined(separator: "\n")
            } catch is CancellationError {} catch {
                if token == self.generation {
                    self.errorMessage = error.localizedDescription
                    self.isPaused = true
                }
            }
        }
    }
    private func publish(_ value: UsageArchiveEngine.Progress, token: Int) {
        if token == generation { progress = value }
    }
}
