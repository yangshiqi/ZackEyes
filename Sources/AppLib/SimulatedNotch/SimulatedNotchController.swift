import AppKit
import SwiftUI
import Shared

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

    // ─── Move mode (gear menu → "Move Notch") ───────────────────────────
    /// Horizontal offset of the notch from screen-center, in points.
    /// 0 = the original fixed top-center position. Persisted to
    /// `~/.zackeyes/config.json` and applied to both compact and full frames.
    private var offsetX: CGFloat = 0
    /// While dragging in move mode, snap the pill to exact center when its
    /// left edge lands within this many points of the centered position — so
    /// the user can recenter precisely by hand (hitting offsetX == 0 exactly
    /// is otherwise near-impossible with a continuous drag).
    private let moveSnapThreshold: CGFloat = 10
    private var moveModeObserver: NSObjectProtocol?
    private var resetPositionObserver: NSObjectProtocol?
    private var compactAgentObserver: NSObjectProtocol?
    private var moveDownMonitor: Any?
    private var moveDragMonitor: Any?
    private var moveUpMonitor: Any?
    private var moveGlobalMonitor: Any?
    /// When a pill drag is in flight, the horizontal distance between the
    /// grab point and the panel's left edge. nil when not dragging.
    private var dragGrabOffsetX: CGFloat?

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
        // Restore the persisted horizontal position before the panel is created
        // so the first frame appears where the user left it.
        self.offsetX = ConfigStore().loadNotchOffsetX()
    }

    public func setup() {
        createPanel()
        observeScreenChanges()
        observeMouseMovement()
        observeMoveModeRequests()
        compactAgentObserver = NotificationCenter.default.addObserver(
            forName: .compactAgentChanged, object: nil, queue: .main
        ) { [weak self] notification in
            guard let agent = notification.userInfo?["agent"] as? AgentKind else { return }
            Task { @MainActor in self?.modeStore.compactAgent = agent }
        }
        usageTracker.start(intervalSeconds: 30)
    }

    public func teardown() {
        usageTracker.stop()
        if let mon = mouseMonitor { NSEvent.removeMonitor(mon) }
        stopOutsideClickMonitoring()
        stopMoveMonitors()
        if let observer = moveModeObserver { NotificationCenter.default.removeObserver(observer) }
        if let observer = resetPositionObserver { NotificationCenter.default.removeObserver(observer) }
        if let observer = compactAgentObserver { NotificationCenter.default.removeObserver(observer) }
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

        // `.whenActive` with sessions already present at setup shows
        // immediately; an empty store stays hidden until the session-boundary
        // sink (AppDelegate) recalls it.
        if shouldBeVisible {
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
        let baseX = screen.frame.midX - compactWidth / 2 + offsetX
        let x = clampedX(baseX, width: compactWidth, on: screen)
        let y = screen.frame.maxY - notchHeight
        return CGRect(x: x, y: y, width: compactWidth, height: notchHeight)
    }

    private func fullFrame(on screen: NSScreen) -> CGRect {
        let baseX = screen.frame.midX - fullWidth / 2 + offsetX
        let x = clampedX(baseX, width: fullWidth, on: screen)
        let y = screen.frame.maxY - fullHeight
        return CGRect(x: x, y: y, width: fullWidth, height: fullHeight)
    }

    /// Clamp a proposed left-edge x so a panel of the given width stays fully
    /// within the screen's horizontal bounds.
    private func clampedX(_ x: CGFloat, width: CGFloat, on screen: NSScreen) -> CGFloat {
        let minX = screen.frame.minX
        let maxX = screen.frame.maxX - width
        guard maxX > minX else { return minX }
        return min(max(x, minX), maxX)
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
            // Once collapsed, remove the panel from screen if it shouldn't be
            // visible (.hidden, or .whenActive with no sessions).
            if !shouldBeVisible {
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

        // While repositioning, the pill must not auto-expand on hover — the
        // user is dragging it, not interacting with its content.
        if modeStore.isMovingNotch { return }

        // Hover area depends on current mode — for compact pill it's a small
        // box near the notch; for full panel it's the entire panel rect.
        let panelFrame = panel.frame
        let hoverArea: CGRect
        switch mode {
        case .compact, .hoverWide:
            // When the pill is meant to be off-screen (.hidden, or
            // .whenActive with no sessions) it must not auto-expand on hover —
            // only hotkey / menu / explicit event may recall it. Placed inside
            // the compact branch (not at function entry) so that `.full` still
            // runs the mouse-out collapse logic below, matching
            // NotchWindowController's parity and guaranteeing the "next
            // collapse orders out" promise in applyVisibility's doc.
            if !shouldBeVisible { return }
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
                // Only block outside-click dismissal while a true interactive
                // overlay (gear NSMenu, About card, Hotkey recorder) is on the
                // panel — those need explicit clicks to operate. A pending
                // permission / AskUQ no longer keeps the panel stuck open: an
                // explicit outside click is a clear "dismiss this" intent, and
                // for AskUQ the user is heading to the terminal anyway.
                if self.modeStore.hasInteractiveOverlay { return }
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
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if self.modeStore.hasInteractiveOverlay { return }
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

    // MARK: - Move mode (gear menu → "Move Notch")

    private func observeMoveModeRequests() {
        moveModeObserver = NotificationCenter.default.addObserver(
            forName: .notchMoveModeRequested,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.enterMoveMode() }
        }
        resetPositionObserver = NotificationCenter.default.addObserver(
            forName: .notchResetPositionRequested,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.resetPosition() }
        }
    }

    /// Reset the notch to its original centered position. Wired to the gear
    /// menu's "Reset to Center" item; also the destination the live drag snaps
    /// to. Persists offsetX = 0 and animates the panel back to center.
    private func resetPosition() {
        offsetX = 0
        ConfigStore().saveNotchOffsetX(0)
        guard let panel = panel, let screen = primaryScreen() else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = animationDuration
            ctx.allowsImplicitAnimation = true
            panel.animator().setFrame(currentFrame(on: screen), display: true)
        }
    }

    /// Enter reposition mode: collapse to the compact pill, suppress hover
    /// auto-expand, and start watching for drags on the pill. A click anywhere
    /// outside the pill locks the position and exits.
    private func enterMoveMode() {
        guard let panel = panel else { return }
        // The gear menu lives in the full panel, so we're typically full here.
        // Collapse to the compact pill — that's the always-visible element the
        // user wants to position out from under the menu-bar icons.
        setMode(.compact)
        // `setMode(.compact)` orders the panel out when it shouldn't be
        // visible; move mode needs the pill on-screen to drag, so force it back.
        if !panel.isVisible { panel.orderFrontRegardless() }
        modeStore.isMovingNotch = true
        startMoveMonitors()
    }

    private func startMoveMonitors() {
        stopMoveMonitors()

        // Press on the pill begins a drag; press elsewhere inside our own
        // windows locks and exits.
        moveDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self else { return event }
            let loc = NSEvent.mouseLocation
            if let panel = self.panel, panel.frame.contains(loc) {
                self.dragGrabOffsetX = loc.x - panel.frame.minX
                return nil  // consume so tap-to-expand doesn't fire
            }
            Task { @MainActor [weak self] in self?.exitMoveMode() }
            return event
        }

        // Drag events keep flowing to us after the mouse-down on our window,
        // even when the cursor leaves the pill — AppKit routes the drag session
        // to the window that received the down.
        moveDragMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDragged) { [weak self] event in
            guard let self, self.dragGrabOffsetX != nil else { return event }
            // Local event monitors fire on the main thread and this closure is
            // already @MainActor-isolated (sibling monitors mutate state
            // synchronously), so call directly — no Task hop. Spawning a Task
            // per drag event deferred each update to the next run-loop turn,
            // making the pill visibly lag the cursor at 60–120 Hz.
            self.handleMoveDrag(NSEvent.mouseLocation)
            return nil
        }

        moveUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            self?.dragGrabOffsetX = nil
            return event
        }

        // A click in any other app / the desktop locks and exits.
        moveGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            Task { @MainActor [weak self] in self?.exitMoveMode() }
        }
    }

    private func handleMoveDrag(_ location: NSPoint) {
        guard let panel = panel,
              let screen = primaryScreen(),
              let grab = dragGrabOffsetX else { return }
        var x = clampedX(location.x - grab, width: compactWidth, on: screen)
        // Snap to exact center when close, so a hand-drag can recenter precisely.
        let centeredX = screen.frame.midX - compactWidth / 2
        if abs(x - centeredX) <= moveSnapThreshold { x = centeredX }
        let y = screen.frame.maxY - notchHeight
        panel.setFrame(CGRect(x: x, y: y, width: compactWidth, height: notchHeight), display: true)
    }

    /// Lock the current position: persist the offset from screen-center and
    /// leave move mode. Idempotent — safe if called when not in move mode.
    private func exitMoveMode() {
        guard modeStore.isMovingNotch else { return }
        if let panel = panel, let screen = primaryScreen() {
            let centeredX = screen.frame.midX - compactWidth / 2
            offsetX = panel.frame.minX - centeredX
            ConfigStore().saveNotchOffsetX(offsetX)
        }
        dragGrabOffsetX = nil
        stopMoveMonitors()
        modeStore.isMovingNotch = false
        // Restore auto-hide behaviour: a panel that shouldn't be visible
        // (.hidden, or .whenActive with no sessions) shouldn't linger
        // on-screen once the user has finished positioning it.
        if !shouldBeVisible, mode != .full { panel?.orderOut(nil) }
    }

    private func stopMoveMonitors() {
        for mon in [moveDownMonitor, moveDragMonitor, moveUpMonitor, moveGlobalMonitor] {
            if let mon { NSEvent.removeMonitor(mon) }
        }
        moveDownMonitor = nil
        moveDragMonitor = nil
        moveUpMonitor = nil
        moveGlobalMonitor = nil
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
    /// Whether the panel should currently be on-screen, given the visibility
    /// mode and (for `.whenActive`) the live session count. Single source of
    /// truth for every show/hide decision in this controller — the collapse,
    /// hover, and move-mode paths consult it too, so `.whenActive` is honored
    /// everywhere, not just in `applyVisibility`.
    private var shouldBeVisible: Bool {
        switch visibility {
        case .always:     return true
        case .hidden:     return false
        case .whenActive: return !viewModel.sessionStore.sessions.isEmpty
        }
    }

    public func applyVisibility(_ v: NotchVisibility) {
        visibility = v
        guard let panel = panel else { return }
        let shouldShow = shouldBeVisible
        if !shouldShow && mode != .full {
            panel.orderOut(nil)
        } else if shouldShow && !panel.isVisible {
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
