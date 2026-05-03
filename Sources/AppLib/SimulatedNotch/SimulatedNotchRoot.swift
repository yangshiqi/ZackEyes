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

    /// True while the gear-menu dropdown is currently visible. Set via
    /// `markMenuOpen()` which also schedules the safety-net close timer.
    @Published public var isMenuOpen: Bool = false

    /// True while the About overlay is shown over the session list.
    @Published public var isAboutShown: Bool = false

    /// True while the hotkey recorder overlay is shown.
    @Published public var isHotkeyRecorderShown: Bool = false

    /// Which agent's 5h/7d quota the *collapsed* simulated notch shows.
    /// (The full panel always shows both when both have data — this only
    /// controls the narrow pill the user stares at all day.) Persisted to
    /// `~/.zackeyes/config.json` via `ConfigStore`. Initialized from disk
    /// by `SimulatedNotchController` at app launch.
    @Published public var compactAgent: AgentKind = .claude

    /// Convenience: any interactive overlay that should keep the panel
    /// open. Used by `SimulatedNotchController` to suppress the
    /// auto-collapse on mouse-out and outside-click handlers.
    public var hasInteractiveOverlay: Bool {
        isMenuOpen || isAboutShown || isHotkeyRecorderShown
    }

    /// Tracks the pending "auto-close the gear menu flag" task so that
    /// rapid taps on the gear icon don't stack up multiple timers (an
    /// earlier timer firing could clear `isMenuOpen` while a later
    /// interaction is still active, prematurely collapsing the panel).
    private var menuCloseTask: Task<Void, Never>?

    /// Mark the gear menu as open and schedule a single 4-second safety
    /// timer that will clear `isMenuOpen` if the user dismisses the menu
    /// without picking an item. Any prior pending close task is cancelled,
    /// so back-to-back taps always keep only the latest timer alive.
    public func markMenuOpen() {
        isMenuOpen = true
        menuCloseTask?.cancel()
        menuCloseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, !Task.isCancelled else { return }
            self.isMenuOpen = false
        }
    }
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
    @ObservedObject var updateChecker: UpdateChecker
    @ObservedObject var downloader: UpdateDownloader
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
            modeStore: modeStore,
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
                modeStore: modeStore,
                updateChecker: updateChecker,
                downloader: downloader,
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
