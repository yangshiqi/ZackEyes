import AppKit
import SwiftUI

/// Manages a floating simulated-notch panel that morphs between two states:
/// - **compact**: narrow pill (220×32) with status icon + 5h/7d remaining
/// - **full**: large panel (520×fullHeight) with the full session list
///
/// Both the NSPanel frame and the SwiftUI content are animated together
/// using a single matched timing curve. There is no `preferredContentSize`
/// feedback loop — the controller is the single source of truth for panel
/// geometry, so the position is rock-solid (always top-center of the
/// primary screen) and the morph is one continuous Apple-style motion.
@MainActor
public final class SimulatedNotchController {
    private let viewModel: NotchViewModel
    private let usageTracker: UsageTracker
    private let updateChecker: UpdateChecker
    private let downloader: UpdateDownloader
    public var onTap: (() -> Void)?

    public var anchorView: NSView? { hostingView }

    private var panel: SimulatedNotchPanel?
    private var hostingView: NSHostingView<SimulatedNotchRoot>?
    private var modeStore = NotchModeStore()
    private var visibility: NotchVisibility
    private var mouseMonitor: Any?
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    private var screenObserver: NSObjectProtocol?

    private var mode: NotchMode {
        get { modeStore.mode }
        set { modeStore.mode = newValue }
    }
    private var collapseWorkItem: DispatchWorkItem?

    // Real MacBook Pro Dynamic Island is roughly 220pt wide × 32pt tall
    private let compactWidth: CGFloat = 220
    private let fullWidth: CGFloat = 520
    private let notchHeight: CGFloat = 32
    /// Computed once at panel-creation time from the screen height (capped
    /// to leave a small margin). Fixed for the lifetime of the panel — the
    /// full content uses an internal ScrollView to handle overflow, so we
    /// never need to resize the panel based on session count.
    private var fullHeight: CGFloat = 480

    // ─── Animation timing ────────────────────────────────────────────────
    // Apple's Dynamic Island uses a snappy ease-out curve. We use the same
    // control points for the NSPanel resize (NSAnimationContext) and the
    // SwiftUI content morph (withAnimation) so they progress in lock-step.
    private let animationDuration: TimeInterval = 0.45
    private let curveC1x: Double = 0.32
    private let curveC1y: Double = 0.72
    private let curveC2x: Double = 0.40
    private let curveC2y: Double = 1.00

    public init(
        viewModel: NotchViewModel,
        usageTracker: UsageTracker,
        updateChecker: UpdateChecker,
        downloader: UpdateDownloader,
        initialVisibility: NotchVisibility = .always
    ) {
        self.viewModel = viewModel
        self.usageTracker = usageTracker
        self.updateChecker = updateChecker
        self.downloader = downloader
        self.visibility = initialVisibility
        // Hydrate the compact-agent preference from disk before any view
        // observes modeStore — otherwise the first frame renders Claude
        // (the default) and snaps to the persisted value on the next tick.
        self.modeStore.compactAgent = ConfigStore().loadCompactAgent()
    }

    public func setup() {
        createPanel()
        observeScreenChanges()
        observeMouseMovement()
        usageTracker.start(intervalSeconds: 30)
    }

    public func teardown() {
        usageTracker.stop()
        if let mon = mouseMonitor { NSEvent.removeMonitor(mon) }
        stopOutsideClickMonitoring()
        if let observer = screenObserver { NotificationCenter.default.removeObserver(observer) }
        panel?.orderOut(nil)
        panel = nil
        hostingView = nil
    }

    // MARK: - Panel creation

    /// Always use the *primary* screen (the one with origin at 0,0 — i.e. the
    /// display marked as primary in System Settings, which holds the menu bar).
    /// `NSScreen.main` follows the key window / focus, so on multi-monitor
    /// setups it would jump between displays. We anchor to a stable screen.
    private func primaryScreen() -> NSScreen? {
        NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.screens.first
    }

    private func createPanel() {
        guard let screen = primaryScreen() else { return }

        // Pre-compute the full panel height once. The full content has its
        // own ScrollView, so this can be a fixed value capped to fit the
        // screen with a small margin.
        fullHeight = min(480, screen.visibleFrame.height - 60)

        let frame = compactFrame(on: screen)
        let panel = SimulatedNotchPanel(contentRect: frame)

        let root = SimulatedNotchRoot(
            viewModel: viewModel,
            usageTracker: usageTracker,
            modeStore: modeStore,
            updateChecker: updateChecker,
            downloader: downloader,
            compactWidth: compactWidth,
            fullWidth: fullWidth,
            notchHeight: notchHeight,
            fullHeight: fullHeight,
            onTap: { [weak self] in self?.toggleFull() }
        )
        let hostingView = FlexibleHostingView(rootView: root)
        // CRITICAL: NSHostingView's default `sizingOptions` is `.standardBounds`,
        // which makes the view auto-resize itself (and via Auto Layout, the
        // enclosing window) to match SwiftUI's natural content size whenever
        // the SwiftUI layout changes. Our SwiftUI root contains a 520×fullHeight
        // child for the full panel content, so the natural size is 520×fullHeight
        // even in compact mode — and the moment SwiftUI re-lays out (e.g. after
        // sessions are imported), the panel jumps to that size.
        //
        // Setting sizingOptions to [] disables all auto-sizing. The hosting
        // view's frame is then controlled entirely by us via autoresizingMask
        // + parent's frame, and the panel size is the single source of truth.
        hostingView.sizingOptions = []
        hostingView.frame = NSRect(origin: .zero, size: frame.size)
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView

        if visibility == .always {
            panel.orderFrontRegardless()
        }
        // Hidden: stay off-screen. forceExpand / hotkey / menu click / events
        // will order the panel front when needed.
        self.panel = panel
        self.hostingView = hostingView

        Task { await usageTracker.refresh() }
    }

    // MARK: - Geometry

    private func compactFrame(on screen: NSScreen) -> CGRect {
        let x = screen.frame.midX - compactWidth / 2
        let y = screen.frame.maxY - notchHeight
        return CGRect(x: x, y: y, width: compactWidth, height: notchHeight)
    }

    private func fullFrame(on screen: NSScreen) -> CGRect {
        let x = screen.frame.midX - fullWidth / 2
        let y = screen.frame.maxY - fullHeight
        return CGRect(x: x, y: y, width: fullWidth, height: fullHeight)
    }

    private func currentFrame(on screen: NSScreen) -> CGRect {
        switch mode {
        case .compact, .hoverWide: return compactFrame(on: screen)
        case .full: return fullFrame(on: screen)
        }
    }

    // MARK: - State transitions

    /// Drive the mode change. The NSPanel frame and the SwiftUI content
    /// animate together using a single matched timing curve so the morph
    /// is one continuous motion — no two-clock drift, no jitter.
    private func setMode(_ newMode: NotchMode) {
        guard mode != newMode else { return }
        guard let panel = panel, let screen = primaryScreen() else {
            modeStore.mode = newMode
            return
        }

        let target = (newMode == .full) ? fullFrame(on: screen) : compactFrame(on: screen)
        let curve = CAMediaTimingFunction(
            controlPoints: Float(curveC1x), Float(curveC1y),
            Float(curveC2x), Float(curveC2y)
        )

        // Animate the NSPanel frame on the AppKit clock.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = animationDuration
            ctx.timingFunction = curve
            ctx.allowsImplicitAnimation = true
            panel.animator().setFrame(target, display: true)
        }

        // Animate the SwiftUI content (opacity, scaleEffect, cornerRadius)
        // with the same curve and duration. They start at the same instant
        // and finish at the same instant, so the morph reads as one motion.
        withAnimation(.timingCurve(curveC1x, curveC1y, curveC2x, curveC2y, duration: animationDuration)) {
            modeStore.mode = newMode
        }

        if newMode == .full {
            startOutsideClickMonitoring()
        } else {
            stopOutsideClickMonitoring()
            // Revert key status when collapsing (unless hotkey recorder is open)
            if !modeStore.isHotkeyRecorderShown {
                panel.allowsKeyStatus = false
            }
            // Hidden: once collapsed, immediately remove the panel from screen.
            if visibility == .hidden {
                panel.orderOut(nil)
            }
        }
    }

    /// Click handler from the compact view — morphs into the full panel.
    public func toggleFull() {
        // If we were hidden and off-screen, the panel needs to come back
        // before any mode animation, otherwise the user's menu-bar click
        // toggles a panel they can't see.
        if let panel, !panel.isVisible {
            panel.orderFrontRegardless()
            setMode(.full)
            return
        }
        setMode(mode == .full ? .compact : .full)
    }

    /// Force the panel into full mode regardless of current state. Used
    /// by event-driven triggers (permission requests, errors) where the
    /// caller wants the panel open, not toggled.
    /// Also enables key status so keyboard shortcuts (⌘Y/⌘N) work.
    public func forceExpand() {
        if let panel, !panel.isVisible {
            panel.orderFrontRegardless()
        }
        setMode(.full)
        panel?.allowsKeyStatus = true
        panel?.makeKey()
    }

    /// Force the panel back to compact mode regardless of current state.
    /// Used by the first-launch welcome coordinator after its 3-second
    /// display window — the mouse-out debounce alone doesn't trigger if
    /// the user's cursor is nowhere near the panel.
    ///
    /// Asymmetric with `forceExpand` — no explicit `panel?.resignKey()` is
    /// needed because the panel is a `nonactivatingPanel` and `setMode(.compact)`
    /// already flips `allowsKeyStatus = false`, so the window can no longer
    /// receive key events regardless of who has focus.
    public func forceCompact() {
        setMode(.compact)
    }

    /// Tear down the About overlay if it's currently shown. Used by the
    /// PermissionRequest path so a question can claim the panel even
    /// when the user is reading the About card.
    public func dismissAboutOverlay() {
        modeStore.isAboutShown = false
    }

    // MARK: - Mouse hover (compact ↔ full)

    private func observeMouseMovement() {
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            Task { @MainActor in
                self?.handleMouseMove(NSEvent.mouseLocation)
            }
        }
    }

    private func handleMouseMove(_ location: NSPoint) {
        guard let panel = panel else { return }

        // Hover area depends on current mode — for compact pill it's a small
        // box near the notch; for full panel it's the entire panel rect.
        let panelFrame = panel.frame
        let hoverArea: CGRect
        switch mode {
        case .compact, .hoverWide:
            // In hidden mode the off-screen pill must not auto-expand on
            // hover — only hotkey / menu / explicit event may recall it.
            // Placed inside the compact branch (not at function entry) so
            // that `.full` still runs the mouse-out collapse logic below,
            // matching NotchWindowController's parity and guaranteeing the
            // "next collapse orders out" promise in applyVisibility's doc.
            if visibility == .hidden { return }
            hoverArea = panelFrame.insetBy(dx: -20, dy: -12)
        case .full:
            hoverArea = panelFrame.insetBy(dx: -16, dy: -16)
        }

        if hoverArea.contains(location) {
            collapseWorkItem?.cancel()
            // Hover anywhere over the notch → expand to full
            if mode != .full {
                setMode(.full)
            }
        } else {
            // Mouse left the area. STICKY EXCEPTION: don't collapse while
            // any interactive overlay is on the panel — pending permission,
            // open gear menu, or About card.
            if stickyOpen {
                collapseWorkItem?.cancel()
                return
            }
            // Otherwise schedule a collapse back to compact.
            collapseWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                Task { @MainActor in
                    guard let self = self else { return }
                    if self.mode != .compact {
                        self.setMode(.compact)
                    }
                }
            }
            collapseWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
        }
    }

    /// True when any session is currently waiting on a user answer. While
    /// this holds, the panel must stay open — neither hover-out nor an
    /// outside click should collapse it.
    private var hasPendingPermission: Bool {
        viewModel.sessionStore.sessions.values.contains { $0.pendingPermission != nil }
    }

    /// True when ANY interactive UI is on the panel and the panel must
    /// not auto-collapse: a pending permission, the gear menu being open,
    /// or the About overlay being shown.
    private var stickyOpen: Bool {
        hasPendingPermission || modeStore.hasInteractiveOverlay
    }

    // MARK: - Outside-click dismissal (full mode)

    private func startOutsideClickMonitoring() {
        stopOutsideClickMonitoring()

        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                // Sticky: don't dismiss while a permission/menu/about overlay is interacting.
                if self.stickyOpen { return }
                self.setMode(.compact)
            }
        }

        localClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            guard let self = self else { return event }
            // Allow clicks inside the notch panel itself
            if let panelWin = self.panel, event.window === panelWin {
                return event
            }
            Task { @MainActor in
                if self.stickyOpen { return }
                self.setMode(.compact)
            }
            return event
        }
    }

    private func stopOutsideClickMonitoring() {
        if let mon = globalClickMonitor {
            NSEvent.removeMonitor(mon)
            globalClickMonitor = nil
        }
        if let mon = localClickMonitor {
            NSEvent.removeMonitor(mon)
            localClickMonitor = nil
        }
    }

    // MARK: - Screen changes

    private func observeScreenChanges() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self = self,
                      let panel = self.panel,
                      let screen = self.primaryScreen() else { return }
                // Recompute fullHeight in case the screen size changed.
                self.fullHeight = min(480, screen.visibleFrame.height - 60)
                panel.setFrame(self.currentFrame(on: screen), display: true)
            }
        }
    }

    /// Respond to a runtime visibility change from the menu toggle.
    /// - `.hidden` + currently compact → order the panel off-screen immediately
    /// - `.always` → order the panel back on-screen, leave mode untouched
    /// - `.hidden` + currently full → leave on-screen; next collapse will
    ///   naturally `orderOut` via the tail of `setMode(.compact)`
    public func applyVisibility(_ v: NotchVisibility) {
        visibility = v
        guard let panel = panel else { return }
        if v == .hidden && mode != .full {
            panel.orderOut(nil)
        } else if v == .always && !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }
}

/// `NSHostingView` subclass that reports no intrinsic content size, so
/// AppKit's Auto Layout never tries to grow the panel to fit the SwiftUI
/// content's natural size. The view fills whatever frame we give it via
/// `autoresizingMask`, and SwiftUI lays out within those bounds.
private final class FlexibleHostingView<Content: View>: NSHostingView<Content> {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    required init(rootView: Content) {
        super.init(rootView: rootView)
    }

    @objc required dynamic init?(coder: NSCoder) {
        fatalError("FlexibleHostingView does not support init(coder:)")
    }
}
