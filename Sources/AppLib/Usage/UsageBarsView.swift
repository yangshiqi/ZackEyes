import SwiftUI

/// Compact 5h + 7d usage bars. Shared between the real-notch expanded view
/// (`NotchRootView.expanded`) and any other surface that needs a read-only
/// usage summary. The simulated-notch path uses its own inline variant
/// because it couples the 5h row with a gear menu + update indicator.
struct UsageBarsView<Trailing: View>: View {
    @ObservedObject var usageTracker: UsageTracker
    let trailing: Trailing

    /// `trailing` is placed at the end of the 5h row (same slot the
    /// simulated-notch gear lives in). Default is `EmptyView` — callers
    /// that don't need a trailing element can use `init(usageTracker:)`.
    init(
        usageTracker: UsageTracker,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) {
        self.usageTracker = usageTracker
        self.trailing = trailing()
    }

    var body: some View {
        let snap = usageTracker.snapshot
        VStack(spacing: 8) {
            usageBar(label: "5h", usedPct: snap.fiveHourUsedPct, resetsAt: snap.fiveHourResetsAt) {
                trailing
            }
            usageBar(label: "7d", usedPct: snap.sevenDayUsedPct, resetsAt: snap.sevenDayResetsAt) {
                EmptyView()
            }
            if snap.hasConsumption, let today = snap.dailyUsage.last {
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(height: 1)
                    .padding(.vertical, 2)
                TodayConsumptionRow(today: today, series: snap.dailyUsage.map(\.totalTokens))
            }
        }
    }

    @ViewBuilder
    private func usageBar<T: View>(
        label: String,
        usedPct: Double?,
        resetsAt: Date?,
        @ViewBuilder trailing: () -> T
    ) -> some View {
        let used = usedPct ?? 0
        let remaining = max(0, 100 - used)
        let color = barColor(for: used)
        let hasData = usedPct != nil

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.7))
                    .frame(width: 22, alignment: .leading)

                if hasData {
                    Text(String(format: "%.0f%% remaining", remaining))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(color)
                } else {
                    Text("no data")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.4))
                }

                Spacer(minLength: 0)

                if let reset = resetsAt?.usageResetDisplay {
                    Text("resets in \(reset)")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.45))
                }

                trailing()
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.white.opacity(0.10))
                        .frame(height: 6)
                    if hasData {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(color)
                            .frame(width: geo.size.width * CGFloat(used / 100), height: 6)
                    }
                }
            }
            .frame(height: 6)
        }
    }

    private func barColor(for used: Double) -> Color {
        .usageLevelColor(usedPct: used)
    }
}
