import AppKit
import SwiftUI
import Combine

/// Manages a floating simulated-notch panel that can morph between three states:
/// - **compact**: narrow pill with status icon + 5h/7d remaining
/// - **hoverWide**: same height, wider pill (more details on hover)
/// - **full**: large panel containing the full session list, expanding downward
///
/// Transitions are animated as a single morphing shape so it always feels like
/// the same notch — never a separate popover.
@MainActor
public final class SimulatedNotchController {
    private let viewModel: NotchViewModel
    private let usageTracker: UsageTracker
    public var onTap: (() -> Void)?

    public var anchorView: NSView? { hostingView }

    private var panel: SimulatedNotchPanel?
    private var hostingView: NSHostingView<AnyView>?
    private var mouseMonitor: Any?
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    private var screenObserver: NSObjectProtocol?
    private var sessionStoreCancellable: AnyCancellable?

    private enum Mode { case compact, hoverWide, full }
    private var mode: Mode = .compact
    private var collapseWorkItem: DispatchWorkItem?

    private let compactWidth: CGFloat = 170
    private let hoverWideWidth: CGFloat = 300
    private let fullWidth: CGFloat = 480
    private let notchHeight: CGFloat = 26
    private let fullMinHeight: CGFloat = 200
    /// Computed dynamically from session count + content
    private var fullCurrentHeight: CGFloat = 200

    public init(viewModel: NotchViewModel, usageTracker: UsageTracker) {
        self.viewModel = viewModel
        self.usageTracker = usageTracker
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

    private func createPanel() {
        guard let screen = NSScreen.main else { return }
        let frame = compactFrame(on: screen)
        let panel = SimulatedNotchPanel(contentRect: frame)

        let hosting = NSHostingView(rootView: AnyView(makeView(for: .compact)))
        hosting.frame = panel.contentView?.bounds ?? .zero
        hosting.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(hosting)

        panel.orderFrontRegardless()
        self.panel = panel
        self.hostingView = hosting

        Task { await usageTracker.refresh() }
    }

    // MARK: - Geometry

    private func compactFrame(on screen: NSScreen) -> CGRect {
        let x = screen.frame.midX - compactWidth / 2
        let y = screen.frame.maxY - notchHeight
        return CGRect(x: x, y: y, width: compactWidth, height: notchHeight)
    }

    private func hoverWideFrame(on screen: NSScreen) -> CGRect {
        let x = screen.frame.midX - hoverWideWidth / 2
        let y = screen.frame.maxY - notchHeight
        return CGRect(x: x, y: y, width: hoverWideWidth, height: notchHeight)
    }

    private func fullFrame(on screen: NSScreen) -> CGRect {
        let height = fullCurrentHeight
        let x = screen.frame.midX - fullWidth / 2
        let y = screen.frame.maxY - height
        return CGRect(x: x, y: y, width: fullWidth, height: height)
    }

    /// Heuristic: header (5h+7d bars) + per-session estimate. Capped at screen height.
    private func computeFullHeight() -> CGFloat {
        let headerHeight: CGFloat = 100  // 5h + 7d bars + paddings + divider
        let perSessionBase: CGFloat = 90  // avatar row + prompt + reply + tool action
        let sessions = viewModel.sessionStore.sessions.values
        var sum: CGFloat = headerHeight + 24  // bottom padding

        if sessions.isEmpty {
            sum += 80  // empty state
        } else {
            for session in sessions {
                var rowHeight = perSessionBase
                if session.lastUserPrompt != nil { rowHeight += 18 }
                if session.lastAssistantMessage != nil { rowHeight += 18 }
                if session.currentToolName != nil { rowHeight += 18 }
                if session.errorMessage != nil { rowHeight += 60 }
                if !session.tasks.isEmpty {
                    let visible = min(6, session.tasks.count)
                    rowHeight += 26 + CGFloat(visible) * 18
                }
                if let pending = session.pendingPermission {
                    rowHeight += pending.isAskUserQuestion ? 200 : 130
                }
                sum += rowHeight + 14  // inter-session spacing
            }
        }

        let maxHeight = (NSScreen.main?.visibleFrame.height ?? 800) - 40
        return max(fullMinHeight, min(sum, maxHeight))
    }

    private func currentFrame(on screen: NSScreen) -> CGRect {
        switch mode {
        case .compact: return compactFrame(on: screen)
        case .hoverWide: return hoverWideFrame(on: screen)
        case .full: return fullFrame(on: screen)
        }
    }

    // MARK: - View building

    @ViewBuilder
    private func makeView(for mode: Mode) -> some View {
        switch mode {
        case .compact:
            SimulatedNotchView(
                viewModel: viewModel,
                usageTracker: usageTracker,
                isExpanded: false,
                onTap: { [weak self] in self?.toggleFull() }
            )
        case .hoverWide:
            SimulatedNotchView(
                viewModel: viewModel,
                usageTracker: usageTracker,
                isExpanded: true,
                onTap: { [weak self] in self?.toggleFull() }
            )
        case .full:
            SimulatedNotchFullView(
                viewModel: viewModel,
                usageTracker: usageTracker,
                cornerRadius: 22
            )
        }
    }

    // MARK: - State transitions

    private func setMode(_ newMode: Mode) {
        guard mode != newMode else { return }
        mode = newMode

        // If entering full mode, recompute height from current session content
        if newMode == .full {
            fullCurrentHeight = computeFullHeight()
        }

        guard let panel = panel, let screen = NSScreen.main else { return }
        let target = currentFrame(on: screen)

        // Swap content first so the new view is laid out as the frame grows
        hostingView?.rootView = AnyView(makeView(for: newMode))

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = newMode == .full ? 0.30 : 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(target, display: true)
        }

        // When entering full mode, install outside-click dismissal
        // and watch session changes to keep height fitting.
        if newMode == .full {
            startOutsideClickMonitoring()
            startObservingSessionChanges()
        } else {
            stopOutsideClickMonitoring()
            stopObservingSessionChanges()
        }
    }

    /// While the full panel is open, refresh its height when sessions change.
    private func startObservingSessionChanges() {
        sessionStoreCancellable?.cancel()
        sessionStoreCancellable = viewModel.sessionStore.objectWillChange
            .receive(on: RunLoop.main)
            .debounce(for: .milliseconds(120), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.refitHeightIfFull()
            }
    }

    private func stopObservingSessionChanges() {
        sessionStoreCancellable?.cancel()
        sessionStoreCancellable = nil
    }

    private func refitHeightIfFull() {
        guard mode == .full, let panel = panel, let screen = NSScreen.main else { return }
        let newHeight = computeFullHeight()
        guard abs(newHeight - fullCurrentHeight) > 4 else { return }
        fullCurrentHeight = newHeight
        let target = fullFrame(on: screen)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(target, display: true)
        }
    }

    /// Click handler from the compact view — morphs into the full panel.
    public func toggleFull() {
        if mode == .full {
            setMode(.compact)
        } else {
            setMode(.full)
        }
    }

    // MARK: - Mouse hover (compact ↔ hoverWide)

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
            // Mouse left the area → schedule collapse back to compact
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

    // MARK: - Outside-click dismissal (full mode)

    private func startOutsideClickMonitoring() {
        stopOutsideClickMonitoring()

        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in self?.setMode(.compact) }
        }

        localClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            guard let self = self else { return event }
            // Allow clicks inside the notch panel itself
            if let panelWin = self.panel, event.window === panelWin {
                return event
            }
            Task { @MainActor in self.setMode(.compact) }
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
                guard let self = self, let screen = NSScreen.main, let panel = self.panel else { return }
                panel.setFrame(self.currentFrame(on: screen), display: true)
            }
        }
    }
}
