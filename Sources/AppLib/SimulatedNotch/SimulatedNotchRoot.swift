import SwiftUI

/// The three modes the simulated notch can morph between.
public enum NotchMode: Sendable {
    case compact      // narrow pill, just status + 5h/7d remaining
    case hoverWide    // wider pill (transitional, currently unused)
    case full         // large panel with sessions + usage header
}

/// Holds the current mode in an ObservableObject so the SwiftUI view tree
/// can observe it without the controller swapping `rootView` (which would
/// destroy SwiftUI's animation context and cause a jump).
@MainActor
public final class NotchModeStore: ObservableObject {
    @Published public var mode: NotchMode = .compact
}

/// Persistent SwiftUI root for the simulated notch panel.
///
/// Layout strategy:
/// - The NSPanel is sized externally by `SimulatedNotchController`, which
///   animates `panel.setFrame(...)` via `NSAnimationContext` in lock-step
///   with a matching SwiftUI `withAnimation` block. There is no
///   `preferredContentSize` feedback loop — the controller is the single
///   source of truth for panel geometry, and SwiftUI just fills whatever
///   bounds it's handed.
/// - The compact pill is the layout backbone (the parent measures it at
///   220×32). The full panel is layered ON TOP via `.overlay()` so it
///   does NOT contribute to the parent's layout — without this, the
///   ZStack would size itself to its largest child (520×fullHeight) and
///   push the compact pill off the visible viewport.
/// - Each view carries its own `NotchShape` background; we do NOT use a
///   shared morphing shape. The cross-fade is opacity + a small
///   scale-from-top on the full panel, driven by the controller's
///   `withAnimation` block in lock-step with the panel resize.
struct SimulatedNotchRoot: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject var usageTracker: UsageTracker
    @ObservedObject var modeStore: NotchModeStore
    let compactWidth: CGFloat
    let fullWidth: CGFloat
    let notchHeight: CGFloat
    let fullHeight: CGFloat
    let onTap: () -> Void

    private var isFull: Bool { modeStore.mode == .full }
    private var cornerRadius: CGFloat { isFull ? 22 : 14 }

    var body: some View {
        // The compact pill is the layout backbone — its 220×32 size is what
        // the ZStack measures. The full panel is layered ON TOP via
        // `.overlay()`, which deliberately does NOT contribute to the
        // parent's layout. So the parent stays sized to the compact pill,
        // and the full panel is free to extend beyond it without dragging
        // the ZStack's coordinate space out to 520×480 (which would push
        // the compact pill off-center).
        SimulatedNotchView(
            viewModel: viewModel,
            usageTracker: usageTracker,
            isExpanded: false,
            onTap: onTap
        )
        .frame(width: compactWidth, height: notchHeight)
        .opacity(isFull ? 0 : 1)
        .allowsHitTesting(!isFull)
        .overlay(alignment: .top) {
            SimulatedNotchFullView(
                viewModel: viewModel,
                usageTracker: usageTracker,
                cornerRadius: 22
            )
            .frame(width: fullWidth, height: fullHeight)
            .opacity(isFull ? 1 : 0)
            .scaleEffect(isFull ? 1 : 0.85, anchor: .top)
            .allowsHitTesting(isFull)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
