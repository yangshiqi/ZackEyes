import Foundation
import Shared

/// Single-flight jobs; the scheduler checks only completion metadata, never transcript roots.
actor UsageArchiveEngine {
    enum Mode: String, Codable, Sendable { case automatic, history, legacy }
    struct Progress: Sendable {
        var phase: String
        var completed = 0
        var total = 0
        var bytes = 0
        var archivesUpdated = false
    }
    struct Outcome: Sendable {
        var issues: [String] = []
        var bytesRead = 0
    }
    let database: UsageArchiveDatabase
    private let importer: UsageArchiveImporter
    private let claudeRoot: URL
    private let codexRoot: URL
    private let legacyURL: URL
    private var busy = false
    private var lastPartialPublication = Date.distantPast
    private var lastAttempt: [String: Date] = [:]
    init(database: UsageArchiveDatabase, claudeRoot: URL, codexRoot: URL, legacyURL: URL, throttle: Bool = true) {
        self.database = database
        self.claudeRoot = claudeRoot
        self.codexRoot = codexRoot
        self.legacyURL = legacyURL
        importer = UsageArchiveImporter(database: database, throttle: throttle, codexRoot: codexRoot)
    }
    private let counterVersionKey = "codex-wide-counter-version"
    private func needsCounterUpgrade() async throws -> Bool {
        try await database.metadata(counterVersionKey) != Data(String(UsageArchiveImporter.counterVersion).utf8)
    }
    private func historyRetryDue(now: Date) async throws -> Bool {
        if let data = try await database.metadata("codex-history-retry"),
           let last = try? JSONDecoder().decode(Date.self, from: data),
           now.timeIntervalSince(last) < 86_400 { return false }
        let incomplete = try await database.hasIncompleteCodexHistory()
        // Cache an empty dependency check too, so the scheduler does not scan
        // checkpoint JSON repeatedly when every history is already resolved.
        if !incomplete {
            try await database.setMetadata("codex-history-retry", JSONEncoder().encode(now))
        }
        return incomplete
    }
    private func settlementKey(_ calendar: Calendar) -> String { "settled:" + UsageArchiveDatabase.zone(calendar) }
    func lastSettlement(calendar: Calendar) async throws -> Date? {
        try await database.metadata(settlementKey(calendar)).map { try JSONDecoder().decode(Date.self, from: $0) }
    }
    func pendingMode() async throws -> Mode? {
        guard let data = try await database.metadata("pending"), !data.isEmpty else { return nil }
        return try JSONDecoder().decode(Mode.self, from: data)
    }
    func isDue(now: Date, calendar: Calendar, startup: Bool = false) async throws -> Bool {
        if busy { return false }
        if let pending = try await pendingMode(), pending != .automatic { return false }
        if let lastAttempt = lastAttempt[UsageArchiveDatabase.zone(calendar)], now.timeIntervalSince(lastAttempt) < 3600
        {
            return false
        }
        if try await needsCounterUpgrade() { return true }
        if try await historyRetryDue(now: now) { return true }
        let today = calendar.startOfDay(for: now)
        if let zone = try await database.metadata("last-zone"),
            String(decoding: zone, as: UTF8.self) != UsageArchiveDatabase.zone(calendar)
        {
            return true
        }
        if let last = try await lastSettlement(calendar: calendar), last >= today { return false }
        return startup || calendar.component(.hour, from: now) >= 3
    }
    func run(
        mode: Mode, now: Date, calendar: Calendar, startup: Bool = false, force: Bool = false,
        onProgress: @Sendable (Progress) async -> Void = { _ in }
    ) async throws -> Outcome {
        guard !busy else { return Outcome() }
        if mode == .automatic && !force {
            guard try await isDue(now: now, calendar: calendar, startup: startup) else { return Outcome() }
        }
        guard !busy else { return Outcome() }
        busy = true
        lastPartialPublication = .distantPast
        await importer.beginRun()
        defer { busy = false }
        if mode == .automatic { lastAttempt[UsageArchiveDatabase.zone(calendar)] = now }
        try await database.setMetadata("pending", JSONEncoder().encode(mode))
        let today = calendar.startOfDay(for: now)
        let previous = try await lastSettlement(calendar: calendar)
        let recent = calendar.date(byAdding: .day, value: -3, to: today)!
        let cutoff = min(recent, previous ?? recent)
        var outcome = Outcome()
        let counterUpgradeNeeded = try await needsCounterUpgrade()
        let upgradingCounters = mode != .legacy && counterUpgradeNeeded
        var completedCounterUpgrade = true
        let retryingHistories = mode == .automatic ? try await historyRetryDue(now: now) : false
        if mode == .legacy {
            await onProgress(Progress(phase: "Importing saved counts", total: 1))
            let result = try await importer.importFile(legacyURL, agent: .claude, cutoff: nil, legacy: true) { bytes in
                await onProgress(Progress(phase: "Importing saved counts", total: 1, bytes: bytes))
            }
            outcome.bytesRead += result.bytesRead
            if result.rejected > 0 {
                outcome.issues.append("Skipped invalid saved counts; imported history may be incomplete.")
            }
        } else {
            let discovered = try discover(since: mode == .automatic ? cutoff : nil, includeOlderCodex: upgradingCounters || retryingHistories)
            completedCounterUpgrade = discovered.issues.isEmpty
            outcome.issues += discovered.issues
            for (index, candidate) in discovered.files.enumerated() {
                try Task.checkCancellation()
                let phase = mode == .automatic ? "Settling completed days" : "Importing older transcripts"
                await onProgress(Progress(phase: phase, completed: index, total: discovered.files.count))
                do {
                    let result = try await importer.importFile(
                        candidate.url, agent: candidate.agent, cutoff: mode == .automatic ? cutoff : nil,
                        upgradeOnly: (upgradingCounters || retryingHistories) && mode == .automatic && candidate.agent == .codex && candidate.modified < cutoff
                    ) { bytes in
                        let value = Progress(
                            phase: phase, completed: index, total: discovered.files.count, bytes: bytes)
                        await onProgress(value)
                        if mode == .automatic {
                            await self.publishPartial(value, today: today, calendar: calendar, onProgress: onProgress)
                        }
                    }
                    outcome.bytesRead += result.bytesRead
                    if result.rejected > 0 {
                        outcome.issues.append(
                            "Skipped invalid or oversized observations; some estimates may be incomplete.")
                    }
                } catch is CancellationError { throw CancellationError() } catch {
                    completedCounterUpgrade = false
                    outcome.issues.append(
                        "A \(candidate.agent.rawValue) transcript could not be imported; saved counts remain available."
                    )
                }
            }
        }
        if mode == .automatic, retryingHistories {
            try await database.setMetadata("codex-history-retry", JSONEncoder().encode(now))
        }
        var first = cutoff
        if mode != .automatic {
            first = try await database.firstDate().map { calendar.startOfDay(for: $0) } ?? recent
        }
        // A new timezone generation is built entirely from indexed counts, without source rereads.
        else if previous == nil {
            first = calendar.date(byAdding: .day, value: -90, to: today)!
        }
        // Counts outside the UI horizon remain indexed; do not build an unbounded number of daily blobs.
        first = max(first, calendar.date(byAdding: .day, value: -90, to: today)!)
        var dates = Set(try await database.dirtyDays(calendar: calendar).filter { $0 < today })
        var cursor = calendar.startOfDay(for: first)
        while cursor < today {
            dates.insert(cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor), next > cursor else { break }
            cursor = next
        }
        let ordered = dates.sorted()
        for (index, day) in ordered.enumerated() {
            try Task.checkCancellation()
            await onProgress(Progress(phase: "Saving daily archives", completed: index, total: ordered.count))
            try await database.archive(day: day, calendar: calendar)
            await Task.yield()
        }
        try Task.checkCancellation()
        outcome.issues = Array(Set(outcome.issues)).sorted()
        if outcome.issues.isEmpty && mode != .legacy {
            try await database.setMetadata(settlementKey(calendar), JSONEncoder().encode(today))
            try await database.setMetadata("last-zone", Data(UsageArchiveDatabase.zone(calendar).utf8))
            lastAttempt.removeValue(forKey: UsageArchiveDatabase.zone(calendar))
        }
        if upgradingCounters, completedCounterUpgrade {
            try await database.setMetadata(counterVersionKey, Data(String(UsageArchiveImporter.counterVersion).utf8))
        }
        try await database.setMetadata("pending", Data())
        return outcome
    }
    private func publishPartial(
        _ progress: Progress, today: Date, calendar: Calendar,
        onProgress: @Sendable (Progress) async -> Void
    ) async {
        guard Date().timeIntervalSince(lastPartialPublication) >= 30 else { return }
        lastPartialPublication = Date()
        do {
            var dates = Set(try await database.dirtyDays(calendar: calendar).filter { $0 < today })
            for offset in 1...3 {
                if let day = calendar.date(byAdding: .day, value: -offset, to: today) { dates.insert(day) }
            }
            for day in dates.sorted() {
                try Task.checkCancellation()
                try await database.archive(day: day, calendar: calendar)
            }
            var updated = progress
            updated.archivesUpdated = true
            await onProgress(updated)
        } catch {
            // The final settlement retries/reports storage failures. Committed source chunks remain resumable.
        }
    }
    private struct Candidate {
        var url: URL
        var agent: AgentKind
        var modified: Date
    }
    private func discover(since: Date?, includeOlderCodex: Bool = false) throws -> (files: [Candidate], issues: [String]) {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [
            .isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .contentModificationDateKey,
        ]
        var files: [Candidate] = []
        var issues: [String] = []
        for (root, agent) in [(claudeRoot, AgentKind.claude), (codexRoot, .codex)] {
            guard fm.fileExists(atPath: root.path) else { continue }
            guard (try? root.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true else {
                issues.append("Skipped a linked transcript root.")
                continue
            }
            var failed = false
            guard
                let walker = fm.enumerator(
                    at: root, includingPropertiesForKeys: Array(keys),
                    errorHandler: { _, _ in
                        failed = true
                        return true
                    })
            else {
                issues.append("Could not list local transcripts.")
                continue
            }
            for case let file as URL in walker {
                try Task.checkCancellation()
                guard let values = try? file.resourceValues(forKeys: keys) else {
                    failed = true
                    continue
                }
                if values.isSymbolicLink == true {
                    walker.skipDescendants()
                    continue
                }
                guard file.pathExtension == "jsonl", values.isRegularFile == true,
                    let modified = values.contentModificationDate, (includeOlderCodex && agent == .codex) || (since.map({ modified >= $0 }) ?? true)
                else { continue }
                files.append(Candidate(url: file, agent: agent, modified: modified))
            }
            if failed { issues.append("Some transcript directories could not be read.") }
        }
        return (files.sorted { $0.modified > $1.modified }, issues)
    }
}
