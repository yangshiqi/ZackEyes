import SwiftUI
import AppKit
import Shared

/// Full-content view shown when the simulated notch is morphed into the
/// expanded panel. Layout:
///   - Top: 5h + 7d usage progress bars
///   - Below: scrollable session list
struct SimulatedNotchFullView: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject var usageTracker: UsageTracker
    @ObservedObject var modeStore: NotchModeStore
    @ObservedObject var updateChecker: UpdateChecker
    @ObservedObject var downloader: UpdateDownloader
    var cornerRadius: CGFloat = 22

    var body: some View {
        if viewModel.welcomeVisible {
            // First-launch welcome: overlay replaces usage header + session
            // list. Simulated-notch surface wraps with NotchShape so the
            // welcome shares the silhouette of the dynamic-island pill.
            WelcomeOverlay()
                .background(NotchShape(cornerRadius: cornerRadius).fill(Color.black))
                .clipShape(NotchShape(cornerRadius: cornerRadius))
        } else {
            normalBody
        }
    }

    private var normalBody: some View {
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
        .background(NotchShape(cornerRadius: cornerRadius).fill(Color.black))
        .clipShape(NotchShape(cornerRadius: cornerRadius))
    }

    // MARK: - Usage header

    private var usageHeader: some View {
        let snap = usageTracker.snapshot
        let codexOnly = snap.hasCodexData && !snap.hasClaudeData
        let bothActive = snap.hasClaudeData && snap.hasCodexData

        return VStack(spacing: 4) {
            if bothActive {
                splitUsageRow(
                    label: "5h",
                    windowDuration: TimeWindowProgress.fiveHours,
                    leftPct: snap.fiveHourUsedPct,
                    leftResetsAt: snap.fiveHourResetsAt,
                    rightPct: snap.codexFiveHourUsedPct,
                    rightResetsAt: snap.codexFiveHourResetsAt,
                    leftETA: snap.fiveHourETA,
                    rightETA: snap.codexFiveHourETA,
                    rightLimitReached: snap.codexLimitReached,
                    rightLimitResetsAt: snap.codexLimitResetsAt,
                    trailing: { gearMenu }
                )
                // 7d does NOT inherit the account-level block flag — an
                // out-of-credits / 5h-window block shouldn't paint the 7d row
                // "limit" too. Its own percentage keeps following the selected
                // Spent/Left presentation while the 5h row is the headline block.
                splitUsageRow(
                    label: "7d",
                    windowDuration: TimeWindowProgress.sevenDays,
                    leftPct: snap.sevenDayUsedPct,
                    leftResetsAt: snap.sevenDayResetsAt,
                    rightPct: snap.codexSevenDayUsedPct,
                    rightResetsAt: snap.codexSevenDayResetsAt
                )
            } else {
                // Single-agent path. Claude shows when only Claude (or
                // neither) reports data — preserves existing behavior for
                // Claude-only users and the empty / first-launch state.
                let useCodex = codexOnly
                let codexLimit = useCodex && snap.codexLimitReached
                usageBar(
                    label: "5h",
                    windowDuration: TimeWindowProgress.fiveHours,
                    agent: useCodex ? .codex : .claude,
                    usedPct: useCodex ? snap.codexFiveHourUsedPct : snap.fiveHourUsedPct,
                    resetsAt: useCodex ? snap.codexFiveHourResetsAt : snap.fiveHourResetsAt,
                    eta: useCodex ? snap.codexFiveHourETA : snap.fiveHourETA,
                    limitReached: codexLimit,
                    limitResetsAt: useCodex ? snap.codexLimitResetsAt : nil,
                    trailing: { gearMenu }
                )
                // 7d shows its own usage — only the 5h row carries the
                // account-level block flag (see the split path above). While
                // codex is blocked, 7d still presents its own window according
                // to the selected Spent/Left preference.
                usageBar(
                    label: "7d",
                    windowDuration: TimeWindowProgress.sevenDays,
                    agent: useCodex ? .codex : .claude,
                    usedPct: useCodex ? snap.codexSevenDayUsedPct : snap.sevenDayUsedPct,
                    resetsAt: useCodex ? snap.codexSevenDayResetsAt : snap.sevenDayResetsAt
                )
            }
            if usageTracker.showTodayConsumption, snap.hasConsumption {
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(height: 1)
                    .padding(.top, 2)
                TodayConsumptionRow(days: snap.dailyUsage)
            }
            // #45 — usage freshness footnote (stale numbers shouldn't read as live).
            // #166 review (Gemini): in the split header both agents show, so the one
            // shared footnote must reflect the STALEST data on screen (the oldest of
            // the two per-agent timestamps), not just Claude's. Single-agent uses its
            // own timestamp.
            let freshness: Date? = bothActive
                ? [snap.lastUpdated, snap.codexLastUpdated].compactMap { $0 }.min()
                : (codexOnly ? snap.codexLastUpdated : snap.lastUpdated)
            if snap.hasRealData, let lastUpdated = freshness {
                UsageFreshnessLabel(lastUpdated: lastUpdated)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    /// Side-by-side bar: left half = Claude, right half = Codex. Both 5h
    /// and 7d rows share the same outer column layout
    /// (label / left-half / right-half / gear-or-placeholder) so the two
    /// progress tracks line up horizontally regardless of which row
    /// carries the gear menu.
    @ViewBuilder
    private func splitUsageRow<Trailing: View>(
        label: String,
        windowDuration: TimeInterval,
        leftPct: Double?, leftResetsAt: Date?,
        rightPct: Double?, rightResetsAt: Date?,
        leftETA: CapETA? = nil, rightETA: CapETA? = nil,
        rightLimitReached: Bool = false, rightLimitResetsAt: Date? = nil,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.7))
                .frame(width: 22, alignment: .leading)

            HStack(spacing: 8) {
                splitHalf(agent: .claude, usedPct: leftPct, resetsAt: leftResetsAt,
                          windowDuration: windowDuration, eta: leftETA)
                splitHalf(agent: .codex, usedPct: rightPct, resetsAt: rightResetsAt,
                          windowDuration: windowDuration, eta: rightETA,
                          limitReached: rightLimitReached, limitResetsAt: rightLimitResetsAt)
            }

            // Trailing column: always reserves the same width so both
            // 5h and 7d rows have identical bar tracks underneath.
            ZStack { trailing() }
                .frame(width: gearColumnWidth, height: gearColumnWidth, alignment: .center)
        }
    }

    /// Width reserved for the gear-menu column on every split row.
    private var gearColumnWidth: CGFloat { 22 }

    /// One agent's half of a split row: header (letter + remaining % +
    /// reset countdown) sitting tightly above its progress bar.
    @ViewBuilder
    private func splitHalf(agent: AgentKind, usedPct: Double?, resetsAt: Date?,
                           windowDuration: TimeInterval,
                           eta: CapETA? = nil,
                           limitReached: Bool = false, limitResetsAt: Date? = nil) -> some View {
        let cell = UsageCellState.make(usedPct: usedPct, limitReached: limitReached)
        let used = usedPct ?? 0
        let presentation = ProgressPresentation(
            spentFraction: used / 100,
            mode: usageTracker.progressMode,
            leftDirection: usageTracker.leftProgressDirection
        )
        let color = cell.isExhausted ? Color.usageLimitRed : barColor(for: used)
        let hasData = usedPct != nil || limitReached
        let accent = AgentBadge.accentColor(for: agent)
        // Exhausted: prefer the BLOCK's reset (the binding window codex is
        // actually limited on) over this cell's own window reset — a 5h headline
        // blocked by the 7d window should count down to the 7d reset, not 5h
        // (CodeRabbit PR review). Falls back to the cell reset when no block
        // reset is known.
        let resetDisplay = (cell.isExhausted ? (limitResetsAt ?? resetsAt) : resetsAt)?.usageResetDisplay

        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(agent == .claude ? "C" : "X")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(accent)
                if cell.isExhausted {
                    Text("limit")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Color.usageLimitRed)
                } else if hasData {
                    Text(presentation.explicitLabel)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(color)
                } else {
                    Text("—")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.35))
                }
                // #86/#108 — the ETA badge sits next to the percentage so the
                // trailing slot stays free for the reset countdown. Both matter at
                // once: ETA = when you run dry, reset = when budget comes back, and
                // ETA < reset is exactly the case to show side by side. Mirrors the
                // full-width usageBar layout. CapETABadge self-guards a nil eta
                // (renders nothing), so no outer `if` is needed — matches usageBar.
                // Suppress when exhausted: "runs dry" is meaningless once blocked.
                if !cell.isExhausted { CapETABadge(eta: eta, compact: true) }
                Spacer(minLength: 0)
                if let reset = resetDisplay {
                    Text(reset)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.white.opacity(0.4))
                }
            }
            UsageProgressTrack(
                fillFraction: cell.isExhausted ? 1 : presentation.fraction,
                fillAnchor: cell.isExhausted ? .leading : presentation.anchor,
                hasData: hasData,
                usageColor: color,
                timeMode: usageTracker.timeProgressMode,
                progressMode: usageTracker.progressMode,
                leftProgressDirection: usageTracker.leftProgressDirection,
                timeOverlayOpacity: usageTracker.timeOverlayOpacity,
                resetsAt: resetsAt,
                windowDuration: windowDuration,
                height: 5
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Opens the shared Settings window directly. The old NSMenu duplicated
    /// the status-bar menu and had already drifted out of sync with it.
    private var gearMenu: some View {
        Button {
            NotificationCenter.default.post(name: .settingsWindowRequested, object: nil)
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.85))
                .frame(width: 22, height: 22)
                .overlay(alignment: .topTrailing) {
                    // Red dot persists across all downloader states (idle / downloading / failed)
                    // until the user upgrades — failed downloads must remain visible so the user
                    // doesn't lose the affordance to retry.
                    if updateChecker.availableVersion != nil {
                        Circle()
                            .fill(AppColors.critical.color)
                            .frame(width: 6, height: 6)
                            .offset(x: 2, y: -2)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }


    @ViewBuilder
    private func usageBar<Trailing: View>(
        label: String,
        windowDuration: TimeInterval,
        agent: AgentKind = .claude,
        usedPct: Double?,
        resetsAt: Date?,
        eta: CapETA? = nil,
        limitReached: Bool = false,
        limitResetsAt: Date? = nil,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) -> some View {
        let cell = UsageCellState.make(usedPct: usedPct, limitReached: limitReached)
        let used = usedPct ?? 0
        let presentation = ProgressPresentation(
            spentFraction: used / 100,
            mode: usageTracker.progressMode,
            leftDirection: usageTracker.leftProgressDirection
        )
        let color = cell.isExhausted ? Color.usageLimitRed : barColor(for: used)
        let hasData = usedPct != nil || limitReached
        let accent = AgentBadge.accentColor(for: agent)
        let resetDisplay = (cell.isExhausted ? (limitResetsAt ?? resetsAt) : resetsAt)?.usageResetDisplay

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.7))
                    .frame(width: 22, alignment: .leading)

                // Agent tag — small label so the user knows which agent's
                // quota this bar represents when only one is active.
                Text(agent == .claude ? "Claude" : "Codex")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(accent)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(accent.opacity(0.15))
                    .clipShape(Capsule())

                if cell.isExhausted {
                    Text("limit reached")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Color.usageLimitRed)
                } else if hasData {
                    Text(presentation.explicitLabel)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(color)
                } else {
                    Text("no data")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.4))
                }

                if !cell.isExhausted { CapETABadge(eta: eta) }   // #86 — cap ETA badge (5h only)

                Spacer(minLength: 0)

                if let reset = resetDisplay {
                    Text("resets in \(reset)")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.45))
                }

                trailing()
            }

            UsageProgressTrack(
                fillFraction: cell.isExhausted ? 1 : presentation.fraction,
                fillAnchor: cell.isExhausted ? .leading : presentation.anchor,
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

    // MARK: - Helpers

    private func barColor(for used: Double) -> Color {
        .usageLevelColor(usedPct: used)
    }

}

public extension Notification.Name {
    static let hotkeyConfigChanged = Notification.Name("hotkeyConfigChanged")
    static let compactAgentChanged = Notification.Name("compactAgentChanged")
    static let notchVisibilityChanged = Notification.Name("notchVisibilityChanged")
    static let notchMoveModeRequested = Notification.Name("notchMoveModeRequested")
    static let notchResetPositionRequested = Notification.Name("notchResetPositionRequested")
}
