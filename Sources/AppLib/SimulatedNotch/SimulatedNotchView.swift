import SwiftUI
import Shared

/// Compact / expanded Dynamic Island-style content for the simulated notch.
///
/// - Collapsed: narrow pill with just a status dot.
/// - Compact (session active): working icon + 5h token bar.
/// - Expanded (on hover): full stats with 5h + 7d token counts and active session name.
struct SimulatedNotchView: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject var usageTracker: UsageTracker
    let isExpanded: Bool

    @State private var workingPulse: Double = 1.0

    var body: some View {
        HStack(spacing: 10) {
            statusIcon

            if isExpanded {
                expandedContent
            } else {
                compactContent
            }
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            // Notch-like shape: rounded bottom corners, flat top (merges with menu bar)
            NotchShape(cornerRadius: 14)
                .fill(Color.black)
        )
    }

    // MARK: - Status icon (animated sparkles / dot)

    private var statusIcon: some View {
        Group {
            switch viewModel.aggregateState {
            case .waiting:
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(Color(red: 0.96, green: 0.65, blue: 0.14))
            case .working:
                Image(systemName: "sparkles")
                    .font(.system(size: 11))
                    .foregroundColor(Color(red: 0.31, green: 0.80, blue: 0.77))
                    .scaleEffect(workingPulse)
                    .onAppear {
                        withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                            workingPulse = 1.2
                        }
                    }
            case .idle, .stopped:
                Image(systemName: "sparkles")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.35))
            }
        }
        .frame(width: 14, height: 14)
    }

    // MARK: - Compact content (shown when not hovered)

    @ViewBuilder
    private var compactContent: some View {
        // Show remaining percentage for both windows — 5h and 7d
        percentageChip(label: "5h",
                        tokens: usageTracker.snapshot.tokens5h,
                        scale: .fiveHour)
        Text("·")
            .font(.system(size: 9))
            .foregroundColor(.white.opacity(0.3))
        percentageChip(label: "7d",
                        tokens: usageTracker.snapshot.tokens7d,
                        scale: .sevenDay)
    }

    @ViewBuilder
    private func percentageChip(label: String, tokens: Int, scale: TokenScale) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.white.opacity(0.5))
            Text("\(remainingPercentString(tokens, scale: scale))")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(remainingColor(tokens, scale: scale))
        }
    }

    private func remainingPercentString(_ tokens: Int, scale: TokenScale) -> String {
        let limit: Double
        switch scale {
        case .fiveHour: limit = 3_000_000
        case .sevenDay: limit = 30_000_000
        }
        let used = min(1.0, Double(tokens) / limit)
        let remaining = max(0, 1.0 - used)
        return String(format: "%.0f%%", remaining * 100)
    }

    /// Green when plenty remaining, orange when low, red when very low.
    private func remainingColor(_ tokens: Int, scale: TokenScale) -> Color {
        let limit: Double
        switch scale {
        case .fiveHour: limit = 3_000_000
        case .sevenDay: limit = 30_000_000
        }
        let used = min(1.0, Double(tokens) / limit)
        switch used {
        case ..<0.5: return Color(red: 0.31, green: 0.80, blue: 0.77)  // teal
        case ..<0.85: return Color(red: 0.96, green: 0.65, blue: 0.14) // orange
        default: return Color(red: 0.95, green: 0.30, blue: 0.30)      // red
        }
    }

    // MARK: - Expanded content (shown on hover)

    @ViewBuilder
    private var expandedContent: some View {
        // 5h window
        usageStat(
            label: "5h",
            tokens: usageTracker.snapshot.tokens5h,
            messages: usageTracker.snapshot.messages5h,
            scale: .fiveHour
        )

        Rectangle()
            .fill(Color.white.opacity(0.15))
            .frame(width: 1, height: 14)

        // 7d window
        usageStat(
            label: "7d",
            tokens: usageTracker.snapshot.tokens7d,
            messages: usageTracker.snapshot.messages7d,
            scale: .sevenDay
        )

        Spacer(minLength: 4)

        // Active session count
        if viewModel.sessionStore.sessions.count > 0 {
            Text("\(viewModel.sessionStore.sessions.count)")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
            Image(systemName: "bubble.left.fill")
                .font(.system(size: 9))
                .foregroundColor(.white.opacity(0.6))
        }
    }

    @ViewBuilder
    private func usageStat(label: String, tokens: Int, messages: Int, scale: TokenScale) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.white.opacity(0.55))
            Text(formatTokens(tokens))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(tokenColor(tokens, scale: scale))
            Text("· \(messages)m")
                .font(.system(size: 9))
                .foregroundColor(.white.opacity(0.4))
        }
    }

    // MARK: - Formatting

    private func formatTokens(_ n: Int) -> String {
        switch n {
        case ..<1_000: return "\(n)"
        case ..<1_000_000: return String(format: "%.1fk", Double(n) / 1_000)
        default: return String(format: "%.2fM", Double(n) / 1_000_000)
        }
    }

    private enum TokenScale {
        case fiveHour, sevenDay
    }

    /// Approximate color thresholds — no subscriber quota data, so we pick
    /// sane defaults. Adjust as Claude Code exposes real limits later.
    private func tokenColor(_ tokens: Int, scale: TokenScale) -> Color {
        let limit: Int
        switch scale {
        case .fiveHour: limit = 3_000_000   // rough target
        case .sevenDay: limit = 30_000_000
        }
        let ratio = Double(tokens) / Double(limit)
        switch ratio {
        case ..<0.5: return Color(red: 0.31, green: 0.80, blue: 0.77)  // teal
        case ..<0.85: return Color(red: 0.96, green: 0.65, blue: 0.14) // orange
        default: return Color(red: 0.95, green: 0.30, blue: 0.30)      // red
        }
    }
}

/// A pill-shaped notch: flat top, rounded bottom corners (hangs from the menu bar area).
struct NotchShape: Shape {
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - cornerRadius))
        p.addQuadCurve(
            to: CGPoint(x: rect.maxX - cornerRadius, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        p.addLine(to: CGPoint(x: rect.minX + cornerRadius, y: rect.maxY))
        p.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - cornerRadius),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        p.closeSubpath()
        return p
    }
}
