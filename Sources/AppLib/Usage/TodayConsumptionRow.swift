import SwiftUI

/// One-glance "Today" consumption row: humanized today tokens · cost · a 7-day
/// token sparkline, with a per-agent subline. Shared by the real-notch
/// (`UsageBarsView`) and simulated-notch (`SimulatedNotchFullView`) headers.
/// Display-only; all branchable logic is in the tested static helpers below.
struct TodayConsumptionRow: View {
    let today: DayUsage
    let series: [Int]   // 7 daily totalTokens, oldest → today (rightmost = today)

    private static let accent = Color(red: 0.31, green: 0.80, blue: 0.77)

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("Today")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.7))
                Text("\(Self.humanizeTokens(today.totalTokens)) tok")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.85))
                if let cost = Self.costString(Self.combinedCost(today), floor: today.anyUnpriced) {
                    Text("· \(cost)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Self.accent)
                }
                Spacer(minLength: 6)
                SparklineView(values: series)
                    .frame(width: 56, height: 12)
            }
            if let sub = subline {
                Text(sub)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.45))
            }
        }
    }

    private var subline: String? {
        var parts: [String] = []
        if today.claudeTokens > 0 { parts.append("C \(Self.humanizeTokens(today.claudeTokens))") }
        if today.codexTokens > 0 { parts.append("X \(Self.humanizeTokens(today.codexTokens))") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - Pure helpers (unit-tested)

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

/// 7 thin bars, heights normalized to the max; the last bar (today) is brighter.
struct SparklineView: View {
    let values: [Int]
    var body: some View {
        let fractions = TodayConsumptionRow.sparklineFractions(values)
        GeometryReader { geo in
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Array(fractions.enumerated()), id: \.offset) { idx, f in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.white.opacity(idx == fractions.count - 1 ? 0.8 : 0.35))
                        .frame(height: max(1, f * geo.size.height))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
    }
}
