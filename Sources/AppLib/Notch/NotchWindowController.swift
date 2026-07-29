import AppKit
import SwiftUI

/// States the notch panel can be in. `compact` is the always-visible
/// default (a pill that sits in the notch row). `expanded` is the full
/// drop-down after an intentional hover dwell.
///
/// There is no "collapsed" state — Dynamic Island is meant to be visible
/// at all times.
public enum PanelState {
    case compact
    case expanded
}

/// Manages the `NotchPanel` lifecycle.
///
/// Architecture (mirrors boring.notch / DynamicIsland_Mac):
///
/// - The NSPanel is created ONCE at the maximum needed size
///   (expandedSize), positioned so its top edge sits at the top of the
///   screen, and is NEVER resized or repositioned after that. Every
///   earlier attempt that animated the panel's frame between compact
///   (38pt tall) and expanded (280pt tall) sizes hit AppKit quirks on
///   some machines where the panel would end up rendered below the menu
///   bar instead of at the notch row.
/// - State transitions only flip a `@Published panelState` on the view
///   model. SwiftUI renders the compact pill at the top of the host
///   (leaving the rest transparent) or the full expanded panel
///   depending on the state. No NSWindow animation, no `setFrame` on
///   state change.
/// - Mouse tracking is geometry-only: we check the cursor against the
///   "hot zone" rect (menu-bar row + side strips) for triggering expand,
///   and against the full panel rect for staying expanded.
@MainActor
public final class NotchWindowController {

    // MARK: - Public

    public private(set) var currentState: PanelState = .compact

    // MARK: - Private

    private let viewModel: NotchViewModel
    private let usageTracker: UsageTracker
    /// Supplies the same application command menu used by the menu-bar icon.
    public var menuBuilder: (() -> NSMenu)?

    /// Fired when the panel opens to `.expanded`. Mirror of the same hook on
    /// `SimulatedNotchController` — see the note there on why both are needed.
    public var onDidExpand: (() -> Void)?
    private var panel: NotchPanel?
    private var mouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    private var screenObserver: NSObjectProtocol?
    private var collapseWorkItem: DispatchWorkItem?
    private var hoverExpandWorkItem: DispatchWorkItem?
    private var hoverIntent = HoverIntentTracker()
    private var isCommandMenuOpen = false
    private var visibility: NotchVisibility

    private let hoverDwellDuration: TimeInterval = 0.25
    private let hoverMovementTolerance: CGFloat = 8

    // Window dimensions. The host panel is sized for the largest state
    // (expanded) and never resized; SwiftUI draws the narrow pill inside
    // this fixed host when we're in the compact state. Matches the simulated
    // notch's generous sizing (520 wide, height adaptive to the screen) so the
    // expanded panel doesn't feel cramped on smaller (13") displays — #64.
    private let windowWidth: CGFloat = 480
    // Set per-screen in `createPanel` (capped to leave a margin below the top);
    // the expanded content scrolls internally, so this is fixed once.
    private var windowHeight: CGFloat = 400

    // MARK: - Init

    public init(
        viewModel: NotchViewModel,
        usageTracker: UsageTracker,
        initialVisibility: NotchVisibility = .always
    ) {
        self.viewModel = viewModel
        self.usageTracker = usageTracker
        self.visibility = initialVisibility
    }

    // MARK: - Lifecycle

    public func setup() {
        createPanel()
        startScreenObserver()
        startMouseMonitor()
    }

    public func teardown() {
        cancelPendingHoverExpansion()
        stopMouseMonitor()
        stopOutsideClickMonitoring()
        stopScreenObserver()
        panel?.orderOut(nil)
        panel = nil
    }

    // MARK: - Public state control

    /// Force-expand the panel (called when a PermissionRequest arrives).
    public func forceExpand() {
        cancelPendingHoverExpansion()
        if let panel, !panel.isVisible {
            panel.orderFrontRegardless()
        }
        updatePanelState(.expanded)
    }

    /// Respond to a runtime visibility change from the menu toggle.
    /// - `.hidden` + currently compact → order the panel off-screen immediately
    /// - `.always` → order the panel back on-screen
    /// - `.hidden` + currently expanded → leave on-screen; next collapse
    ///   naturally orders out via the tail of `updatePanelState(.compact)`
    /// Whether the panel should currently be on-screen, given the visibility
    /// mode and (for `.whenActive`) the live session count. Single source of
    /// truth for every show/hide decision in this controller — the collapse
    /// and hover paths consult it too, so `.whenActive` is honored everywhere,
    /// not just in `applyVisibility`.
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
        if !shouldShow && currentState != .expanded {
            cancelPendingHoverExpansion()
            panel.orderOut(nil)
        } else if shouldShow && !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    // MARK: - Panel creation

    private func createPanel() {
        guard let screen = notchScreen() else {
            NSLog("ZackEyes[notch]: no notchScreen; screens=%d main=%@",
                  NSScreen.screens.count,
                  NSScreen.main.map { "\($0.frame)" } ?? "nil")
            return
        }

        // Cap the expanded height to the screen (leaving a margin below the
        // top), mirroring SimulatedNotchController. The content scrolls
        // internally, so this is computed once and the host is never resized.
        windowHeight = min(400, screen.visibleFrame.height - 60)

        let initialFrame = hostFrame(on: screen)
        // Physical notch width from the screen's auxiliary top areas; fall back
        // to ~185pt (boring.notch's fallback) if the metrics are unavailable.
        let notchWidth = screen.notchSize?.width ?? 185
        NSLog("ZackEyes[notch]: createPanel screen.frame=%@ safeTop=%.1f notchW=%.1f hostFrame=%@",
              "\(screen.frame)",
              screen.safeAreaInsets.top,
              notchWidth,
              "\(initialFrame)")

        let newPanel = NotchPanel(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )

        let rootView = NotchRootView(
            viewModel: viewModel,
            usageTracker: usageTracker,
            notchHeight: notchBarHeight(on: screen),
            notchWidth: notchWidth,
            showMenu: { [weak self] view in
                self?.showCommandMenu(from: view)
            }
        )
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.sizingOptions = []
        hostingView.frame = NSRect(origin: .zero, size: initialFrame.size)
        hostingView.autoresizingMask = [.width, .height]
        newPanel.contentView = hostingView

        newPanel.setFrame(initialFrame, display: false)
        // Note: `panel` isn't assigned until after this; `shouldBeVisible`
        // only reads `visibility` + session count, so it's safe here. For
        // `.whenActive` with sessions already present at creation we show
        // immediately; an empty store stays hidden until the session-boundary
        // sink (AppDelegate) recalls it.
        if shouldBeVisible {
            newPanel.orderFrontRegardless()
        }
        // Hidden: stay off-screen. forceExpand / hotkey / menu click / events
        // will order the panel front when needed.

        panel = newPanel
        currentState = .compact
        viewModel.panelState = .compact
        // In compact state the SwiftUI content only covers the top pill
        // strip; the rest of the 280pt host is transparent. Letting the
        // panel ignore mouse events keeps clicks on desktop / other apps
        // flowing through. Expanded state flips this off.
        newPanel.ignoresMouseEvents = true
    }

    // MARK: - State transitions

    public func updatePanelState(_ newState: PanelState) {
        cancelPendingHoverExpansion()
        guard newState != currentState || panel == nil else { return }

        currentState = newState
        viewModel.panelState = newState

        // In expanded mode the user needs to click Allow/Deny buttons,
        // the gear, session cards, etc., so the panel must receive
        // mouse events. In compact mode content only lives in the top
        // pill strip — rest of the 280pt host is transparent, and we
        // don't want to swallow clicks into apps below.
        panel?.ignoresMouseEvents = (newState != .expanded)

        if newState == .expanded {
            onDidExpand?()
            startOutsideClickMonitoring()
        } else {
            stopOutsideClickMonitoring()
        }

        // Once collapsed, remove the panel from screen if it shouldn't be
        // visible (.hidden, or .whenActive with no sessions).
        if newState == .compact && !shouldBeVisible {
            panel?.orderOut(nil)
        }

        NSLog("ZackEyes[notch]: updatePanelState →%@", "\(newState)")
    }

    // MARK: - Frame calculations

    /// The single host frame: sized for the expanded state, top edge at
    /// the top of the screen, horizontally centered on the notch.
    private func hostFrame(on screen: NSScreen) -> CGRect {
        CGRect(
            x: screen.frame.midX - windowWidth / 2,
            y: screen.frame.maxY - windowHeight,
            width: windowWidth,
            height: windowHeight
        )
    }

    /// Rect that represents the compact pill (menu-bar row across the
    /// full width of the host). Used for hover-to-expand detection.
    private func compactPillRect(on screen: NSScreen, notchHeight: CGFloat) -> CGRect {
        let host = hostFrame(on: screen)
        return CGRect(
            x: host.minX,
            y: host.maxY - notchHeight,
            width: host.width,
            height: notchHeight
        )
    }

    // MARK: - Mouse monitoring

    private func startMouseMonitor() {
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleMouseMoved(NSEvent.mouseLocation)
            }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleMouseMoved(NSEvent.mouseLocation)
            }
            return event
        }
    }

    private func stopMouseMonitor() {
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMonitor = nil
        }
        if let monitor = localMouseMonitor {
            NSEvent.removeMonitor(monitor)
            localMouseMonitor = nil
        }
    }

    private func handleMouseMoved(_ mouse: NSPoint) {
        guard let screen = notchScreen() else { return }
        let notchHeight = notchBarHeight(on: screen)

        switch currentState {
        case .compact:
            // When the panel is meant to be off-screen (.hidden, or
            // .whenActive with no sessions) it should not auto-expand on
            // hover — only hotkey / menu / explicit event brings it back.
            if !shouldBeVisible { return }
            // Begin hover intent inside the menu-bar row. Fast pass-through
            // movement resets or cancels the dwell instead of expanding.
            let pill = compactPillRect(on: screen, notchHeight: notchHeight)
            if pill.contains(mouse) {
                cancelCollapseWorkItem()
                scheduleHoverExpansion(from: mouse, in: pill)
            } else {
                cancelPendingHoverExpansion()
            }

        case .expanded:
            // Stay expanded while the cursor is anywhere within the full
            // 280pt host (plus a small inset so minor jitter between
            // adjacent rows doesn't drop us out). Sticky when a pending
            // permission is waiting.
            let host = hostFrame(on: screen).insetBy(dx: -20, dy: -12)
            if host.contains(mouse) {
                cancelCollapseWorkItem()
            } else if stickyOpen {
                cancelCollapseWorkItem()
            } else {
                scheduleCollapse()
            }
        }
    }

    private var stickyOpen: Bool {
        isCommandMenuOpen
            || viewModel.sessionStore.sessions.values.contains { $0.pendingPermission != nil }
    }

    private func showCommandMenu(from view: NSView) {
        guard let menu = menuBuilder?() else { return }

        cancelCollapseWorkItem()
        isCommandMenuOpen = true
        stopOutsideClickMonitoring()
        defer {
            isCommandMenuOpen = false
            if currentState == .expanded {
                startOutsideClickMonitoring()
            }
        }

        let anchor = NSPoint(x: view.bounds.minX, y: view.bounds.minY - 2)
        menu.popUp(positioning: nil, at: anchor, in: view)
    }

    private func scheduleHoverExpansion(from mouse: CGPoint, in activationArea: CGRect) {
        guard let token = hoverIntent.observe(
            mouse,
            movementTolerance: hoverMovementTolerance
        ) else { return }

        hoverExpandWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Consume the token FIRST. The `Task` hop means a stale work
                // item can run after a newer hover intent was scheduled; if we
                // checked geometry first and then called `cancel()` on failure,
                // that stale task would wipe the newer candidate's token and
                // suppress a legitimate expansion. A failed consume => the token
                // was superseded or cancelled, so bail without touching state.
                guard self.hoverIntent.consume(token) else { return }
                self.hoverExpandWorkItem = nil
                guard self.currentState == .compact,
                      self.shouldBeVisible,
                      activationArea.contains(NSEvent.mouseLocation)
                else { return }
                self.updatePanelState(.expanded)
            }
        }
        hoverExpandWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + hoverDwellDuration,
            execute: workItem
        )
    }

    private func cancelPendingHoverExpansion() {
        hoverExpandWorkItem?.cancel()
        hoverExpandWorkItem = nil
        hoverIntent.cancel()
    }

    private func scheduleCollapse() {
        cancelCollapseWorkItem()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.updatePanelState(.compact)
            }
        }
        collapseWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: workItem)
    }

    private func cancelCollapseWorkItem() {
        collapseWorkItem?.cancel()
        collapseWorkItem = nil
    }

    // MARK: - Outside-click dismissal

    /// Click-anywhere-outside dismissal for the expanded panel. Only active
    /// while `currentState == .expanded`. Native menu presentation brackets
    /// this monitor so menu-item clicks cannot race panel dismissal.
    public func startOutsideClickMonitoring() {
        guard currentState == .expanded else { return }
        stopOutsideClickMonitoring()

        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updatePanelState(.compact)
            }
        }

        localClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            guard let self = self else { return event }
            // Clicks inside our own panel are session-card taps, Allow/Deny
            // buttons, the gear, etc. — let them through untouched.
            if let panelWin = self.panel, event.window === panelWin {
                return event
            }
            Task { @MainActor [weak self] in
                self?.updatePanelState(.compact)
            }
            return event
        }
    }

    public func stopOutsideClickMonitoring() {
        if let mon = globalClickMonitor {
            NSEvent.removeMonitor(mon)
            globalClickMonitor = nil
        }
        if let mon = localClickMonitor {
            NSEvent.removeMonitor(mon)
            localClickMonitor = nil
        }
    }

    // MARK: - Screen observer

    private func startScreenObserver() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleScreenChange()
            }
        }
    }

    private func stopScreenObserver() {
        if let observer = screenObserver {
            NotificationCenter.default.removeObserver(observer)
            screenObserver = nil
        }
    }

    private func handleScreenChange() {
        cancelPendingHoverExpansion()
        panel?.orderOut(nil)
        panel = nil
        createPanel()
    }

    // MARK: - Helpers

    /// The notch display to anchor to. Notch-only by design: this controller
    /// is created solely on machines reporting a hardware notch, so when no
    /// notch screen is present (e.g. the lid is closed / clamshell mode with an
    /// external monitor) we return nil rather than falling back to
    /// `NSScreen.main`. Falling back would anchor a 0-height, invisible panel
    /// onto the external display; returning nil makes `createPanel` skip and
    /// `handleScreenChange` leave nothing on screen until the notch display
    /// returns (issue #64 — never anchor to a notchless screen).
    private func notchScreen() -> NSScreen? {
        NSScreen.withNotch
    }

    /// Height of the compact pill: the notch safe-area inset, clamped so it
    /// never exceeds the menu-bar height (`frame.maxY − visibleFrame.maxY`).
    /// This matches the physical notch height flush (#64).
    ///
    /// When the menu bar is auto-hidden / in full screen, `visibleFrame` spans
    /// the whole frame so the menu-bar measurement is 0. Fall back to the
    /// safe-area inset in that case — clamping to 0 would give the pill zero
    /// height and make it invisible (the notch is physical and still present).
    private func notchBarHeight(on screen: NSScreen) -> CGFloat {
        let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        return menuBar > 0 ? min(screen.safeAreaInsets.top, menuBar) : screen.safeAreaInsets.top
    }
}
