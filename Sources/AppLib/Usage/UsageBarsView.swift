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

                if let reset = relativeReset(resetsAt) {
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
        switch used {
        case ..<50: return Color(red: 0.31, green: 0.80, blue: 0.77)
        case ..<85: return Color(red: 0.96, green: 0.65, blue: 0.14)
        default:    return Color(red: 0.95, green: 0.30, blue: 0.30)
        }
    }

    private func relativeReset(_ date: Date?) -> String? {
        guard let date = date else { return nil }
        let interval = date.timeIntervalSinceNow
        if interval <= 0 { return "now" }
        let hours = Int(interval) / 3600
        let mins = (Int(interval) % 3600) / 60
        let days = hours / 24
        if days >= 1 { return "\(days)d" }
        if hours > 0 { return "\(hours)h \(mins)m" }
        return "\(mins)m"
    }
}
