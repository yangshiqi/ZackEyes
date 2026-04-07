import SwiftUI

/// Full-content view shown when the simulated notch is morphed into the
/// expanded panel. Wraps `NotchExpandedView` in the same `NotchShape`
/// background so the visual transition stays unified — flat top, rounded
/// bottom corners, hanging from the menu bar area.
struct SimulatedNotchFullView: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject var usageTracker: UsageTracker
    var cornerRadius: CGFloat = 22

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            NotchExpandedView(viewModel: viewModel)
                .background(Color.clear)
        }
        .background(
            NotchShape(cornerRadius: cornerRadius)
                .fill(Color.black)
        )
        .clipShape(NotchShape(cornerRadius: cornerRadius))
    }
}
