import SwiftUI
import AppKit

struct NotchRootView: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject var usageTracker: UsageTracker
    /// Called when the gear is clicked. Receives the gear's backing NSView
    /// so AppDelegate can anchor an NSMenu against it. Built via closure
    /// so the expanded view stays module-local and doesn't have to know
    /// about StatusBarMenu wiring.
    let showMenu: (NSView) -> Void

    @State private var gearHost = HostViewBox()

    var body: some View {
        switch viewModel.panelState {
        case .collapsed:
            CollapsedDot(color: viewModel.statusColor)
        case .compact:
            NotchCompactView(viewModel: viewModel)
        case .expanded:
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
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
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

struct CollapsedDot: View {
    let color: Color
    var body: some View {
        Circle()
            .fill(color.opacity(0.4))
            .frame(width: 8, height: 8)
    }
}

struct NotchCompactView: View {
    @ObservedObject var viewModel: NotchViewModel

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(viewModel.statusColor)
                .frame(width: 8, height: 8)
                .shadow(color: viewModel.statusColor, radius: 3)

            Text("Claude Code")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white)

            Text("\u{00B7}") // middle dot
                .foregroundColor(.gray)

            Text(viewModel.statusText)
                .font(.system(size: 11))
                .foregroundColor(viewModel.statusColor)

            if let tool = viewModel.primarySession?.currentToolName {
                Text(tool)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.08))
                    .cornerRadius(4)
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}
