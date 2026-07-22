import SwiftUI
import AppKit
import Shared

struct NotchRootView: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject var usageTracker: UsageTracker
    /// Real notch height (`screen.safeAreaInsets.top`) piped down so the
    /// compact pill knows exactly how tall to be. Matches the menu-bar
    /// strip height.
    let notchHeight: CGFloat
    /// Real notch width (from `auxiliaryTopLeftArea`/`auxiliaryTopRightArea`)
    /// piped down so the compact pill reserves a center gap exactly over the
    /// hardware notch and flanks it with content (issue #64 — Dynamic Island
    /// layout, mirroring DynamicNotchKit / boring.notch).
    let notchWidth: CGFloat
    /// Called with the gear's backing view so AppKit can anchor the shared menu.
    let showMenu: (NSView) -> Void

    @State private var gearHost = HostViewBox()

    var body: some View {
        // Top-aligned ZStack inside the fixed-size 280pt host. In compact
        // state only the pill (notchHeight tall) is drawn — the rest is
        // transparent. In expanded state the full panel fills the host.
        ZStack(alignment: .top) {
            switch viewModel.panelState {
            case .compact:
                NotchCompactView(
                    viewModel: viewModel,
                    usageTracker: usageTracker,
                    notchWidth: notchWidth
                )
                .frame(height: notchHeight)
                .frame(maxWidth: .infinity, alignment: .top)

            case .expanded:
                // Both welcome and normal branches share the same real-notch
                // silhouette — lift the background + clip out of the Group so
                // we don't duplicate them on each side.
                Group {
                    if viewModel.welcomeVisible {
                        // First-launch welcome: overlay replaces the whole
                        // expanded layout (no usage bars, no session list).
                        WelcomeOverlay()
                    } else {
                        VStack(spacing: 0) {
                            UsageBarsView(usageTracker: usageTracker) {
                                gearButton
                            }
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
                    }
                }
                .background(Color.black)
                // Same notch silhouette as the compact pill, with larger radii
                // for the bigger panel: flat top flush to the screen edge,
                // top-outer corners flaring into the bezel, rounded bottom —
                // the expanded panel grows out of the hardware notch.
                .clipShape(NotchShape(topCornerRadius: 10, bottomCornerRadius: 22))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Plain AppKit-style button (not SwiftUI `Menu`) — a nonactivating
    /// panel with a black background renders `Menu`'s label with a
    /// window-chrome tint that's effectively invisible. Popping an
    /// NSMenu via the host NSView sidesteps the rendering problem and
    /// anchors the menu to the gear's real screen rect.
    private var gearButton: some View {
        Button {
            if let view = gearHost.view {
                showMenu(view)
            }
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.85))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(HostViewProbe(box: gearHost))
    }
}

/// Always-visible compact pill, laid out Dynamic-Island style around the
/// physical notch (issue #64). `CenteredNotchLayout` gives the two sides equal
/// extents based on the wider measured side, keeping the exclusion region fixed
/// on the screen center even when status/percentage widths differ (#180).
struct NotchCompactView: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject var usageTracker: UsageTracker
    let notchWidth: CGFloat

    /// Extra clearance split evenly around the runtime hardware-notch width.
    private let notchClearance: CGFloat = 16
    private let outerPadding: CGFloat = 14

    var body: some View {
        let snapshot = usageTracker.snapshot
        let agent = snapshot.displayAgent(preferred: usageTracker.compactAgent)
        let presentation = snapshot.quotaWindowPresentation(for: agent)

        CenteredNotchLayout(
            exclusionWidth: notchWidth + notchClearance,
            outerPadding: outerPadding
        ) {
            HStack(spacing: 6) {
                statusIcon
                primaryContent(
                    presentation.primary,
                    snapshot: snapshot,
                    agent: agent
                )
            }
            HStack(spacing: 0) {
                if let secondary = presentation.secondary {
                    quotaContent(secondary, snapshot: snapshot, agent: agent)
                }
            }
        }
        .frame(maxHeight: .infinity)
        .fixedSize(horizontal: true, vertical: false)
        .background(Color.black)
        // Flat top flush to the bezel, top-outer corners flaring into it, and
        // rounded bottom — the pill fuses with the hardware notch.
        .clipShape(NotchShape(topCornerRadius: 8, bottomCornerRadius: 14))
        .frame(maxWidth: .infinity)
    }

    // MARK: - Status icon (left edge)

    @ViewBuilder
    private var statusIcon: some View {
        CompactStatusIcon(
            attention: CompactAttention.make(
                from: Array(viewModel.sessionStore.sessions.values)
            ),
            aggregateState: viewModel.aggregateState,
            workingColor: viewModel.statusColor
        )
    }

    @ViewBuilder
    private func primaryContent(
        _ window: UsageQuotaWindow?,
        snapshot: UsageTracker.Snapshot,
        agent: AgentKind
    ) -> some View {
        if let window {
            quotaContent(window, snapshot: snapshot, agent: agent)
        } else if agent == .codex && snapshot.codexLimitReached {
            Text("limit")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(Color.usageLimitRed)
        } else if snapshot.hasAuthoritativeQuotaReading(for: agent) {
            Text("no active cap")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(AppColors.noData.color.opacity(0.65))
        } else {
            Text("quota —")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(AppColors.noData.color.opacity(0.45))
        }
    }

    @ViewBuilder
    private func quotaContent(
        _ window: UsageQuotaWindow,
        snapshot: UsageTracker.Snapshot,
        agent: AgentKind
    ) -> some View {
        if window == .fiveHour, let urgent = snapshot.eta(for: window, agent: agent)?.pillUrgentLabel {
            HStack(spacing: 3) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 9, weight: .bold))
                Text(urgent)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
            }
            .foregroundColor(AppColors.critical.color)
        } else {
            usageChip(
                label: window.label,
                usedPct: snapshot.usedPct(for: window, agent: agent)
            )
        }
    }

    // MARK: - Usage chip

    @ViewBuilder
    private func usageChip(label: String, usedPct: Double?) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white.opacity(0.55))
            Text(progressString(usedPct))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(quotaColor(usedPct))
        }
    }

    private func progressString(_ usedPct: Double?) -> String {
        guard let used = usedPct else { return "—" }
        let presentation = ProgressPresentation(
            usedFraction: used / 100,
            mode: usageTracker.progressMode,
            leftDirection: usageTracker.leftProgressDirection
        )
        return "\(presentation.percent)%"
    }

    private func quotaColor(_ usedPct: Double?) -> Color {
        guard let used = usedPct else { return AppColors.noData.color.opacity(0.4) }
        return .usageLevelColor(usedPct: used)
    }
}
