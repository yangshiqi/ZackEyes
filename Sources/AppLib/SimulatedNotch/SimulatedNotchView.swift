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
    @ObservedObject var modeStore: NotchModeStore
    let isExpanded: Bool
    var onTap: (() -> Void)? = nil

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
        .background(NotchShape(cornerRadius: 14).fill(Color.black))
        .overlay {
            // Move-mode cue: an accent border so the user knows the pill is
            // currently draggable (entered via gear menu → "Move Notch").
            if modeStore.isMovingNotch {
                NotchShape(cornerRadius: 14)
                    .stroke(Color(red: 0.31, green: 0.80, blue: 0.77), lineWidth: 2)
            }
        }
        .contentShape(NotchShape(cornerRadius: 14))
        .onTapGesture {
            onTap?()
        }
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
        let snap = usageTracker.snapshot
        let agent = modeStore.compactAgent
        let fivePct = (agent == .codex) ? snap.codexFiveHourUsedPct : snap.fiveHourUsedPct
        let sevenPct = (agent == .codex) ? snap.codexSevenDayUsedPct : snap.sevenDayUsedPct
        percentageChip(label: "5h", usedPct: fivePct, fallbackTokens: snap.tokens5h, scale: .fiveHour)
        Text("·")
            .font(.system(size: 12))
            .foregroundColor(.white.opacity(0.3))
        percentageChip(label: "7d", usedPct: sevenPct, fallbackTokens: snap.tokens7d, scale: .sevenDay)
    }

    @ViewBuilder
    private func percentageChip(label: String, usedPct: Double?, fallbackTokens: Int, scale: TokenScale) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.55))
            Text(remainingString(usedPct: usedPct, fallbackTokens: fallbackTokens, scale: scale))
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundColor(remainingColor(usedPct: usedPct, fallbackTokens: fallbackTokens, scale: scale))
        }
    }

    /// "82%" if real data exists, otherwise "—" or estimated value.
    private func remainingString(usedPct: Double?, fallbackTokens: Int, scale: TokenScale) -> String {
        if let used = usedPct {
            let remaining = max(0, 100.0 - used)
            return String(format: "%.0f%%", remaining)
        }
        // No real data — show em-dash to make it clear we're guessing
        return "—"
    }

    private func remainingColor(usedPct: Double?, fallbackTokens: Int, scale: TokenScale) -> Color {
        let usedRatio: Double
        if let used = usedPct {
            usedRatio = used / 100.0
        } else {
            return .white.opacity(0.4)  // gray when no data
        }
        switch usedRatio {
        case ..<0.5: return Color(red: 0.31, green: 0.80, blue: 0.77)  // teal
        case ..<0.85: return Color(red: 0.96, green: 0.65, blue: 0.14) // orange
        default: return Color(red: 0.95, green: 0.30, blue: 0.30)      // red
        }
    }


    // MARK: - Expanded content (shown on hover)

    @ViewBuilder
    private var expandedContent: some View {
        let snap = usageTracker.snapshot
        let agent = modeStore.compactAgent
        let fivePct = (agent == .codex) ? snap.codexFiveHourUsedPct : snap.fiveHourUsedPct
        let fiveResets = (agent == .codex) ? snap.codexFiveHourResetsAt : snap.fiveHourResetsAt
        let sevenPct = (agent == .codex) ? snap.codexSevenDayUsedPct : snap.sevenDayUsedPct
        let sevenResets = (agent == .codex) ? snap.codexSevenDayResetsAt : snap.sevenDayResetsAt

        usageStat(
            label: "5h",
            usedPct: fivePct,
            resetsAt: fiveResets,
            scale: .fiveHour
        )

        Rectangle()
            .fill(Color.white.opacity(0.15))
            .frame(width: 1, height: 14)

        usageStat(
            label: "7d",
            usedPct: sevenPct,
            resetsAt: sevenResets,
            scale: .sevenDay
        )

        Spacer(minLength: 4)

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
    private func usageStat(label: String, usedPct: Double?, resetsAt: Date?, scale: TokenScale) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.white.opacity(0.55))
            Text(remainingString(usedPct: usedPct, fallbackTokens: 0, scale: scale))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(remainingColor(usedPct: usedPct, fallbackTokens: 0, scale: scale))
            if let reset = resetsAt?.usageResetDisplay {
                Text(reset)
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.4))
            }
        }
    }

    // MARK: - Types

    private enum TokenScale {
        case fiveHour, sevenDay
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
