import SwiftUI
import Shared

/// Compact / expanded Dynamic Island-style content for the simulated notch.
///
/// - Collapsed: narrow pill with just a status dot.
/// - Compact (session active): status + currently available quota windows.
/// - Expanded (on hover): quota stats and active session count.
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
        let presentation = snap.quotaWindowPresentation(for: agent)

        if let primary = presentation.primary {
            compactQuotaContent(primary, snapshot: snap, agent: agent)
        } else {
            quotaPlaceholder(snapshot: snap, agent: agent)
        }
        if let secondary = presentation.secondary {
            Text("·")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.3))
            compactQuotaContent(secondary, snapshot: snap, agent: agent)
        }
    }

    @ViewBuilder
    private func compactQuotaContent(
        _ window: UsageQuotaWindow,
        snapshot: UsageTracker.Snapshot,
        agent: AgentKind
    ) -> some View {
        if window == .fiveHour,
           let urgent = snapshot.eta(for: window, agent: agent)?.pillUrgentLabel {
            HStack(spacing: 3) {
                Image(systemName: "bolt.fill").font(.system(size: 10, weight: .bold))
                Text(urgent).font(.system(size: 13, weight: .semibold, design: .monospaced))
            }
            .foregroundColor(AppColors.critical.color)
        } else {
            percentageChip(
                label: window.label,
                usedPct: snapshot.usedPct(for: window, agent: agent)
            )
        }
    }

    @ViewBuilder
    private func quotaPlaceholder(
        snapshot: UsageTracker.Snapshot,
        agent: AgentKind
    ) -> some View {
        if agent == .codex && snapshot.codexLimitReached {
            Text("limit")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(Color.usageLimitRed)
        } else {
            Text(snapshot.hasAuthoritativeQuotaReading(for: agent) ? "no active cap" : "quota —")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(AppColors.noData.color.opacity(0.5))
        }
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
        let presentation = snap.quotaWindowPresentation(for: agent)

        if let primary = presentation.primary {
            usageStat(
                label: primary.label,
                usedPct: snap.usedPct(for: primary, agent: agent),
                resetsAt: snap.resetsAt(for: primary, agent: agent),
                eta: snap.eta(for: primary, agent: agent)
            )
        } else {
            quotaPlaceholder(snapshot: snap, agent: agent)
        }

        if let secondary = presentation.secondary {
            Rectangle()
                .fill(Color.white.opacity(0.15))
                .frame(width: 1, height: 14)

            usageStat(
                label: secondary.label,
                usedPct: snap.usedPct(for: secondary, agent: agent),
                resetsAt: snap.resetsAt(for: secondary, agent: agent),
                eta: snap.eta(for: secondary, agent: agent)
            )
        }

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
