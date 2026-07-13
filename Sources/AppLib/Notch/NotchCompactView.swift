import SwiftUI
import AppKit

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
/// physical notch (issue #64): a center `Spacer` exactly as wide as the
/// hardware notch keeps that region empty (so nothing lands under the cutout),
/// with the always-on 5h/7d usage chips + status flanking it on the left/right
/// menu-bar strips. `fixedSize` shrinks the black `NotchShape` to wrap tightly
/// around content+notch (instead of a fixed 420pt bar), so the pill hugs the
/// real notch — mirroring DynamicNotchKit / boring.notch's compact layout. The
/// island is therefore a bit wider than the bare notch: that extra width is the
/// always-on info the user asked to keep visible.
struct NotchCompactView: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject var usageTracker: UsageTracker
    let notchWidth: CGFloat

    /// Extra clearance added to the center gap so minor left/right content
    /// asymmetry can't push a glyph under the (centered) physical notch.
    private let notchClearance: CGFloat = 16

    var body: some View {
        HStack(spacing: 6) {
            statusIcon
            leftContent
            // Reserve the hardware-notch footprint: an explicit fixed-width gap
            // (NOT a Spacer — under `.fixedSize` a Spacer collapses toward zero,
            // which would pull both chips into the center, behind the physical
            // notch cutout, making them invisible — issue #64).
            Color.clear.frame(width: notchWidth + notchClearance)
            rightContent
        }
        .padding(.horizontal, 14)
        .frame(maxHeight: .infinity)
        // Shrink to content width so the black shape hugs the notch instead of
        // spanning the whole 420pt host.
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

    // MARK: - Left content (visible, left of notch)

    @ViewBuilder
    private var leftContent: some View {
        let snapshot = usageTracker.snapshot
        let agent = snapshot.displayAgent(preferred: usageTracker.compactAgent)
        let eta = agent == .codex ? snapshot.codexFiveHourETA : snapshot.fiveHourETA
        // #86 — when the 5h cap is imminent (≤30 min), the urgent ETA takes the
        // left slot over the normal quota chip: the pill stays quota-only until
        // it matters, then surfaces the countdown.
        if let urgent = eta?.pillUrgentLabel {
            urgentETAChip(urgent)
        } else {
            // Always-on 5h chip (issue #64) — the working/waiting state is shown
            // by the status icon, and the detailed status text lives in the
            // hover-expanded panel, so the quota chip stays visible at all times.
            usageChip(label: "5h", usedPct: snapshot.fiveHourUsedPct(for: agent))
        }
    }

    @ViewBuilder
    private func urgentETAChip(_ label: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 9, weight: .bold))
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
        }
        .foregroundColor(AppColors.critical.color)
    }

    // MARK: - Right content (visible, right of notch)

    @ViewBuilder
    private var rightContent: some View {
        let snapshot = usageTracker.snapshot
        let agent = snapshot.displayAgent(preferred: usageTracker.compactAgent)
        // Always-on 7d chip (issue #64) — kept visible in every state so the
        // island persistently shows both quota windows.
        usageChip(label: "7d", usedPct: snapshot.sevenDayUsedPct(for: agent))
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
