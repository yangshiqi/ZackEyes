import AppKit
import SwiftUI
import Combine

/// Manages a floating simulated-notch panel for Macs without a physical notch.
/// Expands on hover, collapses on mouse-exit, and updates usage data periodically.
@MainActor
public final class SimulatedNotchController {
    private let viewModel: NotchViewModel
    private let usageTracker: UsageTracker
    public var onTap: (() -> Void)?
    private var panel: SimulatedNotchPanel?
    private var hostingView: NSHostingView<SimulatedNotchView>?
    private var mouseMonitor: Any?
    private var screenObserver: NSObjectProtocol?
    @Published private var isExpanded: Bool = false
    private var collapseWorkItem: DispatchWorkItem?

    private let compactWidth: CGFloat = 170
    private let expandedWidth: CGFloat = 300
    private let notchHeight: CGFloat = 26

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
        if let mouseMonitor = mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
        }
        if let observer = screenObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        panel?.orderOut(nil)
        panel = nil
        hostingView = nil
    }

    // MARK: - Panel creation

    private func createPanel() {
        guard let screen = NSScreen.main else { return }
        let frame = compactFrame(on: screen)
        let panel = SimulatedNotchPanel(contentRect: frame)

        let view = SimulatedNotchView(
            viewModel: viewModel,
            usageTracker: usageTracker,
            isExpanded: false,
            onTap: { [weak self] in self?.onTap?() }
        )
        let hosting = NSHostingView(rootView: view)
        hosting.frame = panel.contentView?.bounds ?? .zero
        hosting.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(hosting)

        panel.orderFrontRegardless()
        self.panel = panel
        self.hostingView = hosting

        // Kick off an initial refresh so we don't show zeros
        Task { await usageTracker.refresh() }
    }

    // MARK: - Geometry

    private func compactFrame(on screen: NSScreen) -> CGRect {
        let x = screen.frame.midX - compactWidth / 2
        let y = screen.frame.maxY - notchHeight
        return CGRect(x: x, y: y, width: compactWidth, height: notchHeight)
    }

    private func expandedFrame(on screen: NSScreen) -> CGRect {
        let x = screen.frame.midX - expandedWidth / 2
        let y = screen.frame.maxY - notchHeight
        return CGRect(x: x, y: y, width: expandedWidth, height: notchHeight)
    }

    // MARK: - State transitions

    private func setExpanded(_ expanded: Bool) {
        guard isExpanded != expanded else { return }
        isExpanded = expanded

        guard let panel = panel, let screen = NSScreen.main else { return }
        let target = expanded ? expandedFrame(on: screen) : compactFrame(on: screen)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(target, display: true)
        }

        // Swap the root view so isExpanded flag is rebuilt
        let newView = SimulatedNotchView(
            viewModel: viewModel,
            usageTracker: usageTracker,
            isExpanded: expanded,
            onTap: { [weak self] in self?.onTap?() }
        )
        hostingView?.rootView = newView
    }

    // MARK: - Mouse tracking

    private func observeMouseMovement() {
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            Task { @MainActor in
                self?.handleMouseMove(NSEvent.mouseLocation)
            }
        }
    }

    private func handleMouseMove(_ location: NSPoint) {
        guard let panel = panel else { return }
        let panelFrame = panel.frame
        let hoverArea = panelFrame.insetBy(dx: -16, dy: -8)

        if hoverArea.contains(location) {
            collapseWorkItem?.cancel()
            setExpanded(true)
        } else if isExpanded {
            // Delay collapse to avoid flicker
            collapseWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                Task { @MainActor in self?.setExpanded(false) }
            }
            collapseWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
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
                let target = self.isExpanded ? self.expandedFrame(on: screen) : self.compactFrame(on: screen)
                panel.setFrame(target, display: true)
            }
        }
    }
}
