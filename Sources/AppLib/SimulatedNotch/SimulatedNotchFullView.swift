import SwiftUI

/// Full-content view shown when the simulated notch is morphed into the
/// expanded panel. Layout:
///   - Top: 5h + 7d usage progress bars
///   - Below: scrollable session list
struct SimulatedNotchFullView: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject var usageTracker: UsageTracker
    var cornerRadius: CGFloat = 22

    var body: some View {
        VStack(spacing: 0) {
            usageHeader
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)

            Divider()
                .background(Color.white.opacity(0.08))

            ScrollView(.vertical, showsIndicators: false) {
                NotchExpandedView(viewModel: viewModel)
                    .background(Color.clear)
            }
        }
        .background(
            NotchShape(cornerRadius: cornerRadius)
                .fill(Color.black)
        )
        .clipShape(NotchShape(cornerRadius: cornerRadius))
    }

    // MARK: - Usage header

    private var usageHeader: some View {
        let snap = usageTracker.snapshot
        return VStack(spacing: 8) {
            usageBar(
                label: "5h",
                usedPct: snap.fiveHourUsedPct,
                resetsAt: snap.fiveHourResetsAt
            )
            usageBar(
                label: "7d",
                usedPct: snap.sevenDayUsedPct,
                resetsAt: snap.sevenDayResetsAt
            )
        }
    }

    @ViewBuilder
    private func usageBar(label: String, usedPct: Double?, resetsAt: Date?) -> some View {
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
            }

            // Progress bar
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

    // MARK: - Helpers

    /// Green when plenty remaining → orange → red.
    private func barColor(for used: Double) -> Color {
        switch used {
        case ..<50: return Color(red: 0.31, green: 0.80, blue: 0.77)  // teal
        case ..<85: return Color(red: 0.96, green: 0.65, blue: 0.14)  // orange
        default:    return Color(red: 0.95, green: 0.30, blue: 0.30)  // red
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
