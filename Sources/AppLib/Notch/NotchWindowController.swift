import AppKit
import SwiftUI

/// States the notch panel can be in.
public enum PanelState {
    case collapsed
    case compact
    case expanded
}

/// Manages the `NotchPanel` lifecycle: geometry, state transitions, and mouse tracking.
///
/// - The panel is attached to the built-in screen with a notch.
/// - Mouse proximity drives automatic transitions between states.
/// - A session must be active for the panel to leave the `collapsed` state automatically.
@MainActor
public final class NotchWindowController {

    // MARK: - Public

    public private(set) var currentState: PanelState = .collapsed

    // MARK: - Private

    private let viewModel: NotchViewModel
    private let usageTracker: UsageTracker
    /// Called when the gear is clicked in the expanded panel. Receives
    /// the gear's NSView for NSMenu anchoring. Optional so the controller
    /// still compiles if no caller wires a menu (gear silently does
    /// nothing in that case).
    public var showMenu: ((NSView) -> Void)?
    private var panel: NotchPanel?
    private var mouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var screenObserver: NSObjectProtocol?
    private var collapseWorkItem: DispatchWorkItem?

    // Frame geometry constants
    private let compactWidth: CGFloat = 320
    private let expandedWidth: CGFloat = 380
    private let expandedHeight: CGFloat = 280
    private let animationDuration: TimeInterval = 0.2

    // Mouse proximity thresholds (in screen coordinates)
    private let notchActivationDistance: CGFloat = 6
    private let notchDeactivationDistance: CGFloat = 40

    // MARK: - Init

    public init(viewModel: NotchViewModel, usageTracker: UsageTracker) {
        self.viewModel = viewModel
        self.usageTracker = usageTracker
    }

    // MARK: - Lifecycle

    /// Create the panel, attach it to the notch screen, and start monitoring.
    public func setup() {
        createPanel()
        startScreenObserver()
        startMouseMonitor()
    }

    /// Tear down all monitors and hide the panel.
    public func teardown() {
        stopMouseMonitor()
        stopScreenObserver()
        panel?.orderOut(nil)
        panel = nil
    }

    // MARK: - Public state control

    /// Force-expand the panel (called when a PermissionRequest arrives).
    public func forceExpand() {
        updatePanelState(.expanded)
    }

    // MARK: - Panel creation

    private func createPanel() {
        guard let screen = notchScreen() else { return }
        guard let notchRect = screen.notchFrame else { return }

        let initialFrame = collapsedFrame(notchRect: notchRect)
        let newPanel = NotchPanel(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )

        let rootView = NotchRootView(
            viewModel: viewModel,
            usageTracker: usageTracker,
            showMenu: { [weak self] view in
                self?.showMenu?(view)
            }
        )
        let hostingView = NSHostingView(rootView: rootView)
        // Prevent NSHostingView's default `.standardBounds` sizingOptions from
        // dragging the panel to SwiftUI's natural content size whenever the
        // layout changes (new session, pending permission, etc.). With this
        // empty set, the hostingView fills whatever frame we give it via
        // autoresizingMask and the panel's setFrame is the single source of
        // truth for geometry.
        hostingView.sizingOptions = []
        hostingView.frame = NSRect(origin: .zero, size: initialFrame.size)
        hostingView.autoresizingMask = [.width, .height]
        newPanel.contentView = hostingView

        newPanel.setFrame(initialFrame, display: false)
        newPanel.orderFrontRegardless()

        panel = newPanel
        currentState = .collapsed
        viewModel.panelState = .collapsed
    }

    // MARK: - State transitions

    public func updatePanelState(_ newState: PanelState) {
        guard let screen = notchScreen(), let notchRect = screen.notchFrame else { return }
        guard newState != currentState || panel == nil else { return }

        currentState = newState
        viewModel.panelState = newState

        let targetFrame = frame(for: newState, notchRect: notchRect)
        let shouldIgnoreMouse = (newState != .expanded)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = animationDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel?.animator().setFrame(targetFrame, display: true)
        }

        // Apply ignoresMouseEvents synchronously — not animated
        panel?.ignoresMouseEvents = shouldIgnoreMouse
    }

    // MARK: - Frame calculations

    private func collapsedFrame(notchRect: CGRect) -> CGRect {
        notchRect
    }

    private func compactFrame(notchRect: CGRect) -> CGRect {
        CGRect(
            x: notchRect.midX - compactWidth / 2,
            y: notchRect.minY,
            width: compactWidth,
            height: notchRect.height
        )
    }

    private func expandedFrame(notchRect: CGRect) -> CGRect {
        CGRect(
            x: notchRect.midX - expandedWidth / 2,
            y: notchRect.minY - expandedHeight,
            width: expandedWidth,
            height: expandedHeight
        )
    }

    private func frame(for state: PanelState, notchRect: CGRect) -> CGRect {
        switch state {
        case .collapsed: return collapsedFrame(notchRect: notchRect)
        case .compact:   return compactFrame(notchRect: notchRect)
        case .expanded:  return expandedFrame(notchRect: notchRect)
        }
    }

    // MARK: - Mouse monitoring

    private func startMouseMonitor() {
        // Global monitor catches events delivered to OTHER apps (our app
        // in background). Local monitor catches events delivered to US
        // — needed whenever the app becomes active (e.g., AboutWindow or
        // HotkeyRecorderWindow calls NSApp.activate), otherwise the
        // global monitor goes silent and the notch stops tracking.
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
        guard let screen = notchScreen(), let notchRect = screen.notchFrame else { return }

        switch currentState {
        case .collapsed:
            let sessionActive = viewModel.aggregateState != .idle
            if sessionActive && isMouseNear(mouse, rect: notchRect, threshold: notchActivationDistance) {
                cancelCollapseWorkItem()
                updatePanelState(.compact)
            }

        case .compact:
            let panelFrame = compactFrame(notchRect: notchRect)
            if isMouseOver(mouse, rect: panelFrame) {
                cancelCollapseWorkItem()
                updatePanelState(.expanded)
            } else if !isMouseNear(mouse, rect: notchRect, threshold: notchDeactivationDistance) {
                updatePanelState(.collapsed)
            }

        case .expanded:
            // Hover area = notch strip ∪ expanded panel, padded outward so
            // small cursor jitter between the two adjacent rects doesn't
            // drop out. Without this the user loses the panel the instant
            // compact→expanded fires because the cursor is still on the
            // notch strip (y ≥ notchRect.minY), strictly outside
            // expandedFrame (expandedFrame.maxY == notchRect.minY).
            let hoverArea = compactFrame(notchRect: notchRect)
                .union(expandedFrame(notchRect: notchRect))
                .insetBy(dx: -20, dy: -12)
            if hoverArea.contains(mouse) {
                cancelCollapseWorkItem()
            } else if stickyOpen {
                // Pending permission / AskUserQuestion must stay visible
                // until resolved, even if the cursor wanders off.
                cancelCollapseWorkItem()
            } else {
                scheduleCollapse()
            }
        }
    }

    /// True when any session has a pending permission request waiting on
    /// the user. The panel must not auto-collapse while this holds.
    private var stickyOpen: Bool {
        viewModel.sessionStore.sessions.values.contains { $0.pendingPermission != nil }
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
        panel?.orderOut(nil)
        panel = nil
        createPanel()
    }

    // MARK: - Helpers

    private func notchScreen() -> NSScreen? {
        NSScreen.screens.first { $0.hasNotch }
            ?? NSScreen.main
    }

    private func isMouseNear(_ point: CGPoint, rect: CGRect, threshold: CGFloat) -> Bool {
        let expanded = rect.insetBy(dx: -threshold, dy: -threshold)
        return expanded.contains(point)
    }

    private func isMouseOver(_ point: CGPoint, rect: CGRect) -> Bool {
        rect.contains(point)
    }
}
