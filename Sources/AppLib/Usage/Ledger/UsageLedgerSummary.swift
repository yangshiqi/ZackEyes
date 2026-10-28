import Foundation
import Shared

struct UsageLedgerSummary: Codable, Sendable {
    struct Day: Identifiable, Codable, Sendable {
        var date: Date
        var agent: AgentKind
        var tokens = 0
        var activeSeconds = 0.0
        var id: String { "\(date.timeIntervalSince1970):\(agent.rawValue)" }
    }
    struct Rank: Identifiable, Codable, Sendable {
        var name: String
        var value: Int
        var id: String { name }
    }
    struct Hour: Identifiable, Codable, Sendable {
        var day: Date
        var hour: Int
        var seconds = 0.0
        var id: String { "\(day.timeIntervalSince1970):\(hour)" }
    }
    var days: [Day] = []
    var heatmap: [Hour] = []
    var projects: [Rank] = []
    var models: [Rank] = []
    var tools: [Rank] = []
    var totalTokens = 0
    var activeSeconds = 0.0
    var cacheHitRate: Double?
    var hasHistory = false
    var cacheInput = 0
    var cacheReused = 0

    static func make(
        records: [UsageLedgerRecord], days count: Int, now: Date, calendar: Calendar, rankLimit: Int = 10,
        start: Date? = nil, exclusiveEnd: Date? = nil
    ) -> Self {
        let today = calendar.startOfDay(for: now)
        let upper = exclusiveEnd ?? now
        let count = max(1, min(90, count))
        let dates = (0..<count).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
        guard let cutoff = start ?? dates.first else { return Self() }
        var report = Self()
        report.days = dates.flatMap { day in [AgentKind.claude, .codex].map { Day(date: day, agent: $0) } }
        report.heatmap = dates.flatMap { day in (0..<24).map { Hour(day: day, hour: $0) } }
        let indices = Dictionary(uniqueKeysWithValues: report.days.enumerated().map { ($0.element.id, $0.offset) })
        let hourIndices = Dictionary(
            uniqueKeysWithValues: report.heatmap.enumerated().map { ($0.element.id, $0.offset) })
        // Latest revision wins, including changed final usage and repeated copies.
        var latest: [String: UsageLedgerRecord] = [:]
        for record in records where record.isValid {
            if latest[record.id].map({ record.supersedes($0) }) ?? true { latest[record.id] = record }
        }
        var projects: [String: Int] = [:]
        var models: [String: Int] = [:]
        var tools: [String: Int] = [:]
        var input = 0
        var cached = 0
        var writes = 0
        var work: [String: [DateInterval]] = [:]
        var waits: [String: [DateInterval]] = [:]
        var agents: [String: AgentKind] = [:]
        for record in normalizedTokens(Array(latest.values)) {
            let session = "\(record.agent.rawValue):\(record.session)"
            if let end = record.end, end > cutoff, record.date < upper {
                let interval = DateInterval(start: max(cutoff, record.date), end: min(upper, end))
                if record.kind == .work { work[session, default: []].append(interval) }
                if record.kind == .wait { waits[session, default: []].append(interval) }
                agents[session] = record.agent
            }
            guard record.date >= cutoff, exclusiveEnd.map({ record.date < $0 }) ?? (record.date <= now) else {
                continue
            }
            report.hasHistory = true
            if record.kind == .tokens {
                report.totalTokens += record.tokens
                input += record.input
                cached += record.cacheRead
                writes += record.cacheWrite
                projects[record.project, default: 0] += record.tokens
                models[record.model, default: 0] += record.tokens
                let key = Day(date: calendar.startOfDay(for: record.date), agent: record.agent).id
                if let index = indices[key] { report.days[index].tokens += record.tokens }
            } else if record.kind == .tool, let tool = record.tool {
                tools[tool, default: 0] += 1
            }
        }
        for (session, intervals) in work {
            guard let agent = agents[session] else { continue }
            for interval in subtract(union(intervals), waits: union(waits[session] ?? [])) {
                var cursor = interval.start
                while cursor < interval.end {
                    guard let hour = calendar.dateInterval(of: .hour, for: cursor), hour.end > cursor else { break }
                    let end = min(hour.end, interval.end)
                    let seconds = end.timeIntervalSince(cursor)
                    let day = calendar.startOfDay(for: cursor)
                    if let index = indices[Day(date: day, agent: agent).id] {
                        report.days[index].activeSeconds += seconds
                    }
                    let key = Hour(day: day, hour: calendar.component(.hour, from: cursor)).id
                    if let index = hourIndices[key] { report.heatmap[index].seconds += seconds }
                    report.activeSeconds += seconds
                    report.hasHistory = true
                    cursor = end
                }
            }
        }
        report.cacheInput = input + cached + writes
        report.cacheReused = cached
        if input + cached + writes > 0 { report.cacheHitRate = Double(cached) / Double(input + cached + writes) }
        func ranked(_ counts: [String: Int]) -> [Rank] {
            let values: [Rank] = counts.compactMap { name, value in
                value > 0 ? Rank(name: name, value: value) : nil
            }
            let sorted = values.sorted { left, right in
                left.value == right.value ? left.name < right.name : left.value > right.value
            }
            return Array(sorted.prefix(rankLimit))
        }
        report.projects = ranked(projects)
        report.models = ranked(models)
        report.tools = ranked(tools)
        return report
    }

    /// Counter observations are merged across all files and persisted scans
    /// before differencing, so copied/truncated prefixes cannot mint tokens.
    private static func normalizedTokens(_ records: [UsageLedgerRecord]) -> [UsageLedgerRecord] {
        var result = records.filter { $0.kind != .counter }
        let groups = Dictionary(grouping: records.filter { $0.kind == .counter }, by: { $0.session })
        for counters in groups.values {
            let sorted = counters.sorted { left, right in
                if left.date != right.date { return left.date < right.date }
                if left.input + left.output != right.input + right.output { return left.input + left.output < right.input + right.output }
                if (left.baseline == true) != (right.baseline == true) { return right.baseline == true }
                return left.id < right.id
            }
            var previous = (input: 0, output: 0, read: 0, write: 0)
            var pending: UsageLedgerRecord?
            for counter in sorted {
                if counter.baseline == true {
                    previous = (counter.input, counter.output, counter.cacheRead, counter.cacheWrite)
                    pending = nil
                    continue
                }
                if let gap = pending {
                    let deltas = [counter.input - gap.input, counter.output - gap.output,
                                  counter.cacheRead - gap.cacheRead, counter.cacheWrite - gap.cacheWrite]
                    if deltas.allSatisfy({ (0...1_000_000_000).contains($0) }) {
                        previous = (gap.input, gap.output, gap.cacheRead, gap.cacheWrite)
                    }
                    pending = nil
                }
                if counter.input < previous.input || counter.output < previous.output { previous = (0, 0, 0, 0) }
                let input = max(0, counter.input - previous.input)
                let output = max(0, counter.output - previous.output)
                let read = max(0, counter.cacheRead - previous.read)
                let write = max(0, counter.cacheWrite - previous.write)
                if input + output + read + write == 0 {
                    previous = (counter.input, counter.output, counter.cacheRead, counter.cacheWrite)
                    continue
                }
                var delta = counter
                delta.kind = .tokens
                delta.baseline = nil
                delta.input = max(0, input - read - write)
                delta.output = output
                delta.cacheRead = read
                delta.cacheWrite = write
                if delta.isValid {
                    previous = (counter.input, counter.output, counter.cacheRead, counter.cacheWrite)
                    result.append(delta)
                } else {
                    pending = counter
                }
            }
        }
        return result
    }

    private static func union(_ intervals: [DateInterval]) -> [DateInterval] {
        var result: [DateInterval] = []
        for interval in intervals.sorted(by: { $0.start < $1.start }) {
            if let last = result.last, last.end >= interval.start {
                result[result.count - 1] = DateInterval(start: last.start, end: max(last.end, interval.end))
            } else {
                result.append(interval)
            }
        }
        return result
    }
    private static func subtract(_ intervals: [DateInterval], waits: [DateInterval]) -> [DateInterval] {
        var result: [DateInterval] = []
        for interval in intervals {
            var cursor = interval.start
            for wait in waits where wait.end > cursor && wait.start < interval.end {
                if wait.start > cursor {
                    result.append(DateInterval(start: cursor, end: min(wait.start, interval.end)))
                }
                cursor = max(cursor, wait.end)
                if cursor >= interval.end { break }
            }
            if cursor < interval.end { result.append(DateInterval(start: cursor, end: interval.end)) }
        }
        return result
    }
}
