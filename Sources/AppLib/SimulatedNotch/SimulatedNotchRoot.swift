import SwiftUI
import Shared

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

    /// True while the user is repositioning the notch (entered via the gear
    /// menu's "Move Notch" item). While set, the pill is draggable, hover
    /// auto-expand is suppressed, and a visual move-cue border is shown.
    @Published public var isMovingNotch: Bool = false

    /// Which agent's 5h/7d quota the *collapsed* simulated notch shows.
    /// (The full panel always shows both when both have data — this only
    /// controls the narrow pill the user stares at all day.) Persisted to
    /// `~/.zackeyes/config.json` via `ConfigStore`. Initialized from disk
    /// by `SimulatedNotchController` at app launch.
    @Published public var compactAgent: AgentKind = .claude

}

enum SimulatedNotchContentActivity: Equatable {
    case compact
    case full

    init(mode: NotchMode) {
        self = mode == .full ? .full : .compact
    }

    var fullIsActive: Bool { self == .full }
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
/// - A transparent 220×32 layout backbone keeps the full panel top-centered.
/// - Compact and full content keep stable SwiftUI identity so transient list
///   and scroll state survive a collapse. The hidden full tree receives an
///   inactive flag that pauses its timer and repeat-forever animations.
/// - Each view carries its own `NotchShape` background. Mode changes cross-fade
///   the stable trees in lock-step with the controller's panel resize.
struct SimulatedNotchRoot: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject var usageTracker: UsageTracker
    @ObservedObject var modeStore: NotchModeStore
    @ObservedObject var updateChecker: UpdateChecker
    @ObservedObject var downloader: UpdateDownloader
    let compactWidth: CGFloat
    let fullWidth: CGFloat
    let notchHeight: CGFloat
    let fullHeight: CGFloat
    let onTap: () -> Void

    var body: some View {
        let activity = SimulatedNotchContentActivity(mode: modeStore.mode)

        // Keep a non-rendering compact-size backbone so the full panel can
        // extend from the same top-center anchor without affecting layout.
        Color.clear
        .frame(width: compactWidth, height: notchHeight)
        .overlay(alignment: .top) {
            SimulatedNotchView(
                viewModel: viewModel,
                usageTracker: usageTracker,
                modeStore: modeStore,
                isExpanded: false,
                onTap: onTap
            )
            .frame(width: compactWidth, height: notchHeight)
            .opacity(activity == .compact ? 1 : 0)
            .allowsHitTesting(activity == .compact)
        }
        .overlay(alignment: .top) {
            SimulatedNotchFullView(
                viewModel: viewModel,
                usageTracker: usageTracker,
                modeStore: modeStore,
                updateChecker: updateChecker,
                downloader: downloader,
                cornerRadius: 22,
                isActive: activity.fullIsActive
            )
            .frame(width: fullWidth, height: fullHeight)
            .opacity(activity == .full ? 1 : 0)
            .scaleEffect(activity == .full ? 1 : 0.85, anchor: .top)
            .allowsHitTesting(activity == .full)
            .accessibilityHidden(activity != .full)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
