import SwiftUI

/// One-glance consumption row: a header line (tokens · est. cost) + per-agent
/// subline, with a 7-day daily-token sparkline on the right. Shared by the
/// real-notch (`UsageBarsView`) and simulated-notch (`SimulatedNotchFullView`)
/// headers. Hovering a sparkline bar rewrites the header to that day's data
/// (the panel is a nonactivating NSPanel, so native `.help()` tooltips don't
/// fire — `.onHover` does). Branchable logic is in the tested static helpers.
struct TodayConsumptionRow: View {
    let days: [DayUsage]   // 7 local-day buckets, oldest → today (rightmost = today)

    /// Which bar the header reflects: the hovered one, else today (last).
    @State private var hoveredIndex: Int? = nil

    private static let accent = Color(red: 0.31, green: 0.80, blue: 0.77)

    private var shownIndex: Int {
        guard !days.isEmpty else { return 0 }
        return hoveredIndex.flatMap { days.indices.contains($0) ? $0 : nil } ?? days.count - 1
    }
    private var shownDay: DayUsage {
        days.isEmpty ? DayUsage(dayStart: .init(timeIntervalSince1970: 0)) : days[shownIndex]
    }
    /// "Today" for the last bucket, otherwise the bar's local date as "M/d".
    private var shownLabel: String {
        guard !days.isEmpty, shownIndex != days.count - 1 else { return "Today" }
        let c = Calendar.current.dateComponents([.month, .day], from: days[shownIndex].dayStart)
        return "\(c.month ?? 0)/\(c.day ?? 0)"
    }

    var body: some View {
        let shown = shownDay
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(shownLabel)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.7))
                    Text("\(Self.humanizeTokens(shown.totalTokens)) tok")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.85))
                    if let cost = Self.costString(Self.combinedCost(shown), floor: shown.anyUnpriced) {
                        Text("· est. \(cost)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Self.accent)
                    }
                }
                if let sub = Self.subline(for: shown) {
                    Text(sub)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.45))
                }
            }
            Spacer(minLength: 8)
            // 7-day daily-token sparkline — right of the text block, spanning both
            // lines. Hover a bar to drive the header above; rightmost = today.
            SparklineView(days: days, hoveredIndex: $hoveredIndex)
                .frame(width: 104, height: 22)
        }
    }

    // MARK: - Pure helpers (unit-tested)

    /// Per-agent subline ("C 1.1M · X 0.3M"); omits a zero agent, nil if both zero.
    static func subline(for day: DayUsage) -> String? {
        var parts: [String] = []
        if day.claudeTokens > 0 { parts.append("C \(humanizeTokens(day.claudeTokens))") }
        if day.codexTokens > 0 { parts.append("X \(humanizeTokens(day.codexTokens))") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// 1_400_000 → "1.4M", 12_000_000 → "12M", 340_000 → "340K", 1234 → "1234".
    nonisolated static func humanizeTokens(_ n: Int) -> String {
        guard n > 0 else { return "0" }
        if n >= 1_000_000 {
            let s = String(format: "%.1f", Double(n) / 1_000_000)
            return (s.hasSuffix(".0") ? String(s.dropLast(2)) : s) + "M"
        }
        if n >= 10_000 {
            return "\(n / 1000)K"   // truncate (avoids 999_999 → "1000K")
        }
        return "\(n)"
    }

    /// Sum of the per-agent costs, or nil if neither agent had priced tokens.
    nonisolated static func combinedCost(_ day: DayUsage) -> Double? {
        switch (day.claudeCostUSD, day.codexCostUSD) {
        case (nil, nil):            return nil
        case let (c?, x?):          return c + x
        case let (c?, nil):         return c
        case let (nil, x?):         return x
        }
    }

    /// "$4.20" / "≥$4.20"; nil when `usd` is nil.
    nonisolated static func costString(_ usd: Double?, floor: Bool) -> String? {
        guard let usd else { return nil }
        let prefix = floor ? "≥$" : "$"
        return prefix + String(format: "%.2f", usd)
    }

    /// Each value as a 0...1 fraction of the max; all-zero (or empty) → zeros.
    nonisolated static func sparklineFractions(_ values: [Int]) -> [Double] {
        guard let mx = values.max(), mx > 0 else { return values.map { _ in 0.0 } }
        return values.map { Double($0) / Double(mx) }
    }
}

/// 7 daily bars, heights normalized to the max. The "active" bar (hovered, or
/// today when not hovering) is brighter. Each day is a full-height, equal-width
/// hover target that reports its index up via `hoveredIndex`.
struct SparklineView: View {
    let days: [DayUsage]
    @Binding var hoveredIndex: Int?

    var body: some View {
        let fractions = TodayConsumptionRow.sparklineFractions(days.map(\.totalTokens))
        let active = hoveredIndex ?? (days.count - 1)
        GeometryReader { geo in
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(days.indices, id: \.self) { idx in
                    Color.clear
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.white.opacity(idx == active ? 0.9 : 0.32))
                                .frame(height: max(1, fractions[idx] * geo.size.height))
                        }
                        .contentShape(Rectangle())
                        .onHover { hovering in
                            if hovering { hoveredIndex = idx }
                            else if hoveredIndex == idx { hoveredIndex = nil }
                        }
                }
            }
        }
    }
}
