import SwiftUI
import AppKit

struct NotchRootView: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject var usageTracker: UsageTracker
    /// Real notch height (`screen.safeAreaInsets.top`) piped down so the
    /// compact pill knows exactly how tall to be. Matches the menu-bar
    /// strip height.
    let notchHeight: CGFloat
    /// Called when the gear is clicked. Receives the gear's backing NSView
    /// so AppDelegate can anchor an NSMenu against it.
    let showMenu: (NSView) -> Void

    @State private var gearHost = HostViewBox()

    var body: some View {
        // Top-aligned ZStack inside the fixed-size 280pt host. In compact
        // state only the pill (notchHeight tall) is drawn — the rest is
        // transparent. In expanded state the full panel fills the host.
        ZStack(alignment: .top) {
            switch viewModel.panelState {
            case .compact:
                NotchCompactView(viewModel: viewModel, usageTracker: usageTracker)
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
                .clipShape(RoundedRectangle(cornerRadius: 16))
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

/// Always-visible compact pill. The panel is 420pt wide but the center
/// ~190pt is clipped by the physical notch. Layout pushes meaningful
/// content to the left and right strips via `Spacer`; anything placed
/// in the middle is effectively invisible.
struct NotchCompactView: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject var usageTracker: UsageTracker

    var body: some View {
        HStack(spacing: 6) {
            statusIcon
            leftContent
            Spacer(minLength: 0)
            rightContent
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Status icon (left edge)

    @ViewBuilder
    private var statusIcon: some View {
        switch viewModel.aggregateState {
        case .waiting:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 11))
                .foregroundColor(Color(red: 0.96, green: 0.65, blue: 0.14))
        case .working:
            Circle()
                .fill(viewModel.statusColor)
                .frame(width: 8, height: 8)
                .shadow(color: viewModel.statusColor, radius: 3)
        case .idle, .stopped:
            Image(systemName: "sparkles")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.45))
        }
    }

    // MARK: - Left content (visible, left of notch)

    @ViewBuilder
    private var leftContent: some View {
        switch viewModel.aggregateState {
        case .idle, .stopped:
            usageChip(label: "5h", usedPct: usageTracker.snapshot.fiveHourUsedPct)
        case .working, .waiting:
            Text("Claude")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white)
        }
    }

    // MARK: - Right content (visible, right of notch)

    @ViewBuilder
    private var rightContent: some View {
        switch viewModel.aggregateState {
        case .idle, .stopped:
            usageChip(label: "7d", usedPct: usageTracker.snapshot.sevenDayUsedPct)
        case .working, .waiting:
            Text(viewModel.statusText)
                .font(.system(size: 11))
                .foregroundColor(viewModel.statusColor)
                .lineLimit(1)
        }
    }

    // MARK: - Usage chip

    @ViewBuilder
    private func usageChip(label: String, usedPct: Double?) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white.opacity(0.55))
            Text(remainingString(usedPct))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(remainingColor(usedPct))
        }
    }

    private func remainingString(_ usedPct: Double?) -> String {
        guard let used = usedPct else { return "—" }
        return String(format: "%.0f%%", max(0, 100 - used))
    }

    private func remainingColor(_ usedPct: Double?) -> Color {
        guard let used = usedPct else { return .white.opacity(0.4) }
        return .usageLevelColor(usedPct: used)
    }
}
