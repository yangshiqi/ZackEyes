import Charts
import Shared
import SwiftUI

struct UsageLedgerView: View {
    @ObservedObject var ledger: UsageLedgerService
    private let accent = AppColors.activity.color

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Picker(
                    "Period",
                    selection: Binding(get: { ledger.days }, set: { value in Task { await ledger.setDays(value) } })
                ) {
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                }
                .pickerStyle(.segmented)
                .frame(width: 240)
                Spacer()
                if ledger.isLoading { ProgressView().controlSize(.small) }
                Button("Refresh") { Task { await ledger.refresh() } }
                Button("Update now") { ledger.updateNow() }.disabled(ledger.isLoading || ledger.isPaused)
            }
            Toggle("Include cached reads", isOn: Binding(
                get: { ledger.includeCacheReads },
                set: { value in Task { await ledger.setIncludeCacheReads(value) } }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .help("Include reused input tokens in totals, daily charts, and project/model rankings.")
            if ledger.isLoading {
                Text(
                    ledger.progress.total > 0
                        ? "\(ledger.progress.phase): \(ledger.progress.completed) of \(ledger.progress.total) · \(ByteCountFormatter.string(fromByteCount: Int64(ledger.progress.bytes), countStyle: .file))"
                        : ledger.progress.phase
                )
                .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            }
            HStack {
                Button("Import saved history") { ledger.importLegacy() }.disabled(ledger.isLoading || ledger.isPaused)
                Button("Import older transcripts") { ledger.importHistory() }.disabled(
                    ledger.isLoading || ledger.isPaused)
                if ledger.isLoading && !ledger.isPaused {
                    Button("Pause") { Task { await ledger.pause() } }
                }
                if ledger.isPaused { Button("Resume") { ledger.resume() }.disabled(ledger.isLoading) }
            }.controlSize(.small)
            if ledger.isPaused {
                Text("Background statistics paused. Saved daily archives remain available.").font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Text("Through yesterday · Today is not settled · Local counts only")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Text(
                "Automatic setup covers the last three completed days. Import earlier history to extend coverage; saved counts survive source removal."
            )
            .font(.system(size: 11)).foregroundStyle(.secondary)
            if let error = ledger.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(AppColors.attention.color)
                    .textSelection(.enabled)
            }
            if let date = ledger.settledThrough {
                Text("Settled through: \(date.formatted(date:.abbreviated,time:.omitted))")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if !ledger.isLoading && !ledger.summary.hasHistory {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No local history yet").font(.headline)
                    Text(
                        "Recent completed days are settled in the background at 03:00, with catch-up after sleep or restart. Import saved history or older transcripts to add earlier days. Removed transcripts cannot be backfilled; saved counts are preserved."
                    )
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            }
            HStack(spacing: 24) {
                metric("Tokens", value: ledger.summary.totalTokens.formatted())
                metric("Agent-hours (est.)", value: String(format: "%.2f", ledger.summary.activeSeconds / 3600))
                metric(
                    "Cache hit rate",
                    value: ledger.summary.cacheHitRate.map { String(format: "%.0f%%", $0 * 100) } ?? "—")
            }
            HStack(spacing: 16) {
                agentTotal(.claude)
                agentTotal(.codex)
            }
            chart(title: "Daily tokens", hours: false)
            chart(title: "Estimated agent-hours", hours: true)
            Text(
                "Hours estimate elapsed work from task/tool intervals, merge overlaps, and exclude recorded question waits. Missing boundaries use short, capped activity gaps; unobserved approval waits may remain included. Concurrent sessions add agent-hours. Cache hit rate counts reused input, not output."
            )
            .font(.system(size: 11)).foregroundStyle(.secondary)
            ranking("Top projects · tokens", items: ledger.summary.projects)
            ranking("Top models · tokens", items: ledger.summary.models)
            ranking("Top tools · calls", items: ledger.summary.tools)
            heatmap
            Text(
                "Only counts, project/model/tool names and timing metadata are kept in ~/.zackeyes/usage/. No prompts, replies or tool arguments are stored. Daily counts follow your current local timezone."
            )
            .font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
            Text(ledger.includeCacheReads
                ? "Token totals include cached reads."
                : "Token totals exclude cached reads; cache writes are included.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .task { await ledger.refresh() }
    }
    private func agentTotal(_ agent: AgentKind) -> some View {
        let values = ledger.summary.days.filter { $0.agent == agent }
        let tokens = values.reduce(0) { $0 + $1.tokens }
        let hours = values.reduce(0) { $0 + $1.activeSeconds } / 3600
        return VStack(alignment: .leading, spacing: 3) {
            Text(agent == .claude ? "Claude totals" : "Codex totals")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(AgentBadge.accentColor(for: agent))
            Text("\(tokens.formatted()) tokens · \(String(format: "%.2f", hours)) h (est.)")
                .font(.system(size: 11)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 18, weight: .semibold)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func chart(title: String, hours: Bool) -> some View {
        UsageDailyChart(title: title, hours: hours, days: ledger.summary.days)
    }
    private func ranking(_ title: String, items: [UsageLedgerSummary.Rank]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 13, weight: .semibold))
            if items.isEmpty { Text("No observations").font(.system(size: 11)).foregroundStyle(.secondary) }
            ForEach(items) { item in
                HStack {
                    Text(item.name).lineLimit(1)
                    Spacer()
                    Text(item.value.formatted()).monospacedDigit()
                }
                .font(.system(size: 12))
                .accessibilityElement(children: .combine)
            }
        }
        .padding(12).background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }
    private var heatmap: some View {
        let rows = Dictionary(grouping: ledger.summary.heatmap, by: { $0.day })
        let maximum = max(1, ledger.summary.heatmap.map(\.seconds).max() ?? 0)
        return VStack(alignment: .leading, spacing: 8) {
            Text("Active hours · local time").font(.system(size: 13, weight: .semibold))
            HStack {
                Text("Day").frame(width: 50, alignment: .leading)
                Text("00")
                Spacer()
                Text("06")
                Spacer()
                Text("12")
                Spacer()
                Text("18")
                Spacer()
                Text("23")
            }.font(.system(size: 9)).foregroundStyle(.secondary)
            LazyVStack(spacing: 3) {
                ForEach(rows.keys.sorted(), id: \.self) { day in
                    HStack(spacing: 3) {
                        Text(day.formatted(.dateTime.month(.twoDigits).day(.twoDigits)))
                            .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                            .frame(width: 50, alignment: .leading)
                        ForEach(rows[day] ?? []) { hour in
                            Rectangle().fill(
                                accent.opacity(hour.seconds > 0 ? 0.2 + 0.8 * hour.seconds / maximum : 0.06)
                            )
                            .frame(maxWidth: .infinity).frame(height: 10)
                            .help(
                                "\(day.formatted(date:.abbreviated,time:.omitted)) \(hour.hour):00 · \(Int((hour.seconds/60).rounded())) active agent-minutes"
                            )
                        }
                    }
                }
            }
        }
    }
}

/// Each chart owns its hover state so moving between charts cannot leave a stale date.
private struct UsageDailyChart: View {
        let title: String
        let hours: Bool
        let days: [UsageLedgerSummary.Day]
        @State private var hoveredDate: Date?

        private var hoveredDays: [UsageLedgerSummary.Day] {
                guard let hoveredDate else { return [] }
                return days.filter { Calendar.current.isDate($0.date, inSameDayAs: hoveredDate) }
        }

        var body: some View {
                VStack(alignment: .leading, spacing: 10) {
                        Text(title).font(.system(size: 13, weight: .semibold))
                        Chart(days) { day in
                                BarMark(
                                        x: .value("Day", day.date, unit: .day),
                                        y: .value(title, hours ? day.activeSeconds / 3600 : Double(day.tokens))
                                )
                                .foregroundStyle(by: .value("Agent", day.agent == .claude ? "Claude" : "Codex"))
                                .position(by: .value("Agent", day.agent.rawValue))
                        }
                        .chartForegroundStyleScale([
                                "Claude": AgentBadge.accentColor(for: .claude),
                                "Codex": AgentBadge.accentColor(for: .codex),
                        ])
                        .chartOverlay { proxy in
                                GeometryReader { geometry in
                                        Color.clear.contentShape(Rectangle())
                                                .onContinuousHover { phase in
                                                        switch phase {
                                                        case .active(let location):
                                                                guard let plotFrame = proxy.plotFrame,
                                                                        geometry[plotFrame].contains(location)
                                                                else {
                                                                        hoveredDate = nil
                                                                        return
                                                                }
                                                                hoveredDate = proxy.value(
                                                                        atX: location.x - geometry[plotFrame].minX, as: Date.self)
                                                        case .ended:
                                                                hoveredDate = nil
                                                        }
                                                }
                                }
                        }
                        .overlay(alignment: .topTrailing) {
                                if let day = hoveredDays.first {
                                        VStack(alignment: .leading, spacing: 4) {
                                                Text(
                                                        day.date.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).weekday(.wide))
                                                )
                                                .fontWeight(.semibold)
                                                ForEach(hoveredDays) { value in
                                                        Text(
                                                                "\(value.agent == .claude ? "Claude" : "Codex"): \(hours ? String(format: "%.2f h (est.)", value.activeSeconds / 3600) : value.tokens.formatted() + " tokens")"
                                                        )
                                                }
                                                if !hours {
                                                        Text("Total: \(hoveredDays.reduce(0) { $0 + $1.tokens }.formatted()) tokens")
                                                                .fontWeight(.semibold)
                                                }
                                        }
                                        .font(.system(size: 11)).monospacedDigit()
                                        .padding(8)
                                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                                        .allowsHitTesting(false)
                                }
                        }
                        .frame(height: 150)
                        .onChange(of: days.map(\.id)) { _, _ in hoveredDate = nil }
                }
        }
}
