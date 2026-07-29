import SwiftUI
import Shared

/// Data-driven quota bars. Shared between the real-notch expanded view
/// (`NotchRootView.expanded`) and any other surface that needs a read-only
/// usage summary. The simulated-notch path uses its own inline variant because
/// it supports split-agent rows plus the update badge.
struct UsageBarsView<Trailing: View>: View {
    @ObservedObject var usageTracker: UsageTracker
    let trailing: Trailing

    /// `trailing` is placed at the end of the first visible quota row, or the
    /// empty-state row when no window exists, so settings never disappear.
    init(
        usageTracker: UsageTracker,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) {
        self.usageTracker = usageTracker
        self.trailing = trailing()
    }

    var body: some View {
        let snap = usageTracker.snapshot
        let agent = snap.displayAgent(preferred: usageTracker.compactAgent)
        let presentation = snap.quotaWindowPresentation(for: agent)
        VStack(spacing: 8) {
            if presentation.windows.isEmpty {
                quotaEmptyState(snapshot: snap, agent: agent) { trailing }
            } else {
                ForEach(presentation.windows, id: \.self) { window in
                    usageBar(
                        label: window.label,
                        usedPct: snap.usedPct(for: window, agent: agent),
                        resetsAt: snap.resetsAt(for: window, agent: agent),
                        windowDuration: window.duration,
                        eta: snap.eta(for: window, agent: agent)
                    ) {
                        if window == presentation.primary { trailing }
                    }
                }
            }
            if usageTracker.showTodayConsumption, snap.hasConsumption {
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(height: 1)
                    .padding(.vertical, 2)
                TodayConsumptionRow(days: snap.dailyUsage)
            }
            // #45 — usage freshness footnote (stale numbers shouldn't read as live).
            let freshness = agent == .codex ? snap.codexLastUpdated : snap.lastUpdated
            if snap.hasRealData, let lastUpdated = freshness {
                UsageFreshnessLabel(lastUpdated: lastUpdated)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    @ViewBuilder
    private func quotaEmptyState<T: View>(
        snapshot: UsageTracker.Snapshot,
        agent: AgentKind,
        @ViewBuilder trailing: () -> T
    ) -> some View {
        HStack(spacing: 6) {
            if agent == .codex && snapshot.codexLimitReached {
                Text("limit reached")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color.usageLimitRed)
            } else {
                Text(snapshot.hasAuthoritativeQuotaReading(for: agent)
                     ? "no active quota windows"
                     : "no quota data")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.4))
            }
            Spacer(minLength: 0)
            if agent == .codex,
               snapshot.codexLimitReached,
               let reset = snapshot.codexLimitResetsAt?.usageResetDisplay {
                Text("resets in \(reset)")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.45))
            }
            trailing()
        }
    }

    @ViewBuilder
    private func usageBar<T: View>(
        label: String,
        usedPct: Double?,
        resetsAt: Date?,
        windowDuration: TimeInterval,
        eta: CapETA? = nil,
        @ViewBuilder trailing: () -> T
    ) -> some View {
        let used = usedPct ?? 0
        let presentation = ProgressPresentation(
            usedFraction: used / 100,
            mode: usageTracker.progressMode,
            leftDirection: usageTracker.leftProgressDirection
        )
        let color = barColor(for: used)
        let hasData = usedPct != nil

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.7))
                    .frame(width: 22, alignment: .leading)

                if hasData {
                    Text(presentation.explicitLabel)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(color)
                } else {
                    Text("no data")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.4))
                }

                // #86 — cap ETA badge (5h row only). Renders nothing for the
                // calm states so the row stays as before.
                CapETABadge(eta: eta)

                Spacer(minLength: 0)

                if let reset = resetsAt?.usageResetDisplay {
                    Text("resets in \(reset)")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.45))
                }

                trailing()
            }

            UsageProgressTrack(
                fillFraction: presentation.fraction,
                fillAnchor: presentation.anchor,
                hasData: hasData,
                usageColor: color,
                timeMode: usageTracker.timeProgressMode,
                progressMode: usageTracker.progressMode,
                leftProgressDirection: usageTracker.leftProgressDirection,
                timeOverlayOpacity: usageTracker.timeOverlayOpacity,
                resetsAt: resetsAt,
                windowDuration: windowDuration
            )
        }
    }

    private func barColor(for used: Double) -> Color {
        .usageLevelColor(usedPct: used)
    }
}
