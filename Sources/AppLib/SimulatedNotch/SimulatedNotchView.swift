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
                    .stroke(AppColors.activity.color, lineWidth: 2)
            }
        }
        .contentShape(NotchShape(cornerRadius: 14))
        .onTapGesture {
            onTap?()
        }
    }

    // MARK: - Status icon (animated sparkles / dot)

    private var statusIcon: some View {
        CompactStatusIcon(
            attention: CompactAttention.make(
                from: Array(viewModel.sessionStore.sessions.values)
            ),
            aggregateState: viewModel.aggregateState,
            workingColor: AppColors.activity.color
        )
    }

    // MARK: - Compact content (shown when not hovered)

    @ViewBuilder
    private var compactContent: some View {
        let snap = usageTracker.snapshot
        let agent = snap.displayAgent(preferred: modeStore.compactAgent)
        let fivePct = snap.fiveHourUsedPct(for: agent)
        let sevenPct = snap.sevenDayUsedPct(for: agent)
        let eta = (agent == .codex) ? snap.codexFiveHourETA : snap.fiveHourETA
        // #86 — imminent cap (≤30 min) takes the 5h slot; 7d stays put.
        if let urgent = eta?.pillUrgentLabel {
            urgentETAChip(urgent)
        } else {
            percentageChip(label: "5h", usedPct: fivePct)
        }
        Text("·")
            .font(.system(size: 12))
            .foregroundColor(.white.opacity(0.3))
        percentageChip(label: "7d", usedPct: sevenPct)
    }

    @ViewBuilder
    private func urgentETAChip(_ label: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "bolt.fill").font(.system(size: 10, weight: .bold))
            Text(label).font(.system(size: 13, weight: .semibold, design: .monospaced))
        }
        .foregroundColor(AppColors.critical.color)
    }

    @ViewBuilder
    private func percentageChip(label: String, usedPct: Double?) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.55))
            Text(progressString(usedPct: usedPct))
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundColor(quotaColor(usedPct: usedPct))
        }
    }

    /// "82%" if real data exists, otherwise "—" or estimated value.
    private func progressString(usedPct: Double?) -> String {
        if let used = usedPct {
            let presentation = ProgressPresentation(
                usedFraction: used / 100,
                mode: usageTracker.progressMode,
                leftDirection: usageTracker.leftProgressDirection
            )
            return "\(presentation.percent)%"
        }
        // No real data — show em-dash to make it clear we're guessing
        return "—"
    }

    private func quotaColor(usedPct: Double?) -> Color {
        let usedRatio: Double
        if let used = usedPct {
            usedRatio = used / 100.0
        } else {
            return AppColors.noData.color.opacity(0.4)
        }
        return .usageLevelColor(usedPct: usedRatio * 100)
    }


    // MARK: - Expanded content (shown on hover)

    @ViewBuilder
    private var expandedContent: some View {
        let snap = usageTracker.snapshot
        let agent = snap.displayAgent(preferred: modeStore.compactAgent)
        let fivePct = snap.fiveHourUsedPct(for: agent)
        let fiveResets = (agent == .codex) ? snap.codexFiveHourResetsAt : snap.fiveHourResetsAt
        let sevenPct = snap.sevenDayUsedPct(for: agent)
        let sevenResets = (agent == .codex) ? snap.codexSevenDayResetsAt : snap.sevenDayResetsAt

        usageStat(
            label: "5h",
            usedPct: fivePct,
            resetsAt: fiveResets,
            eta: (agent == .codex) ? snap.codexFiveHourETA : snap.fiveHourETA
        )

        Rectangle()
            .fill(Color.white.opacity(0.15))
            .frame(width: 1, height: 14)

        usageStat(
            label: "7d",
            usedPct: sevenPct,
            resetsAt: sevenResets
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
    private func usageStat(label: String, usedPct: Double?, resetsAt: Date?,
                           eta: CapETA? = nil) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.white.opacity(0.55))
            Text(progressString(usedPct: usedPct))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(quotaColor(usedPct: usedPct))
            // #86/#108 — show the ETA badge AND the reset countdown; they don't
            // compete (ETA = when you run dry, reset = when budget returns), and
            // an urgent ETA like ⚡~10min is exactly when you want both. CapETABadge
            // self-guards a nil eta (renders nothing), so no outer `if` is needed.
            CapETABadge(eta: eta, compact: true)
            if let reset = resetsAt?.usageResetDisplay {
                Text(reset)
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.4))
            }
        }
    }

}

// `NotchShape` now lives in Sources/AppLib/Notch/NotchShape.swift (shared by
// the real-notch and simulated paths). The simulated path keeps its original
// look via the back-compat `NotchShape(cornerRadius:)` initializer.
