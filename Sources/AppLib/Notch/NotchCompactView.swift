import SwiftUI

struct NotchRootView: View {
    @ObservedObject var viewModel: NotchViewModel

    var body: some View {
        switch viewModel.panelState {
        case .collapsed:
            CollapsedDot(color: viewModel.statusColor)
        case .compact:
            NotchCompactView(viewModel: viewModel)
        case .expanded:
            NotchExpandedView(viewModel: viewModel)
        }
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

            if let tool = viewModel.toolBadge {
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
