import SwiftUI

struct NotchRootView: View {
    @ObservedObject var viewModel: NotchViewModel

    var body: some View {
        switch viewModel.panelState {
        case .collapsed:
            Circle()
                .fill(Color.gray.opacity(0.4))
                .frame(width: 8, height: 8)
        case .compact:
            Text("Claude Code")
                .foregroundColor(.white)
                .font(.system(size: 11))
        case .expanded:
            Text("Expanded — placeholder")
                .foregroundColor(.white)
                .font(.system(size: 11))
        }
    }
}
