import AppKit
import SwiftUI
import Combine
import Shared

@MainActor
public class MenuBarFallback: NSObject {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private let viewModel: NotchViewModel
    private var iconCancellable: AnyCancellable?
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?

    /// Called when the user clicks the status bar icon. If set, replaces
    /// the default popover toggle (e.g. to open the simulated notch instead).
    public var onIconClick: (() -> Void)?

    public init(viewModel: NotchViewModel) {
        self.viewModel = viewModel
        super.init()
    }

    public func setup() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.target = self
        self.statusItem = statusItem

        updateIcon(for: viewModel.sessionStore.aggregateState)

        // Observe state changes to update icon
        iconCancellable = viewModel.sessionStore.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.updateIcon(for: self.viewModel.sessionStore.aggregateState)
            }

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: NotchExpandedView(viewModel: viewModel)
                .frame(width: 460)
                .background(Color.black)
        )
        self.popover = popover
    }

    private func updateIcon(for state: SessionState) {
        guard let image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "ZackEyes") else {
            return
        }
        image.isTemplate = true
        statusItem?.button?.image = image
        statusItem?.button?.title = ""

        // State-based tint
        switch state {
        case .waiting:
            // Orange — attention grabbing
            statusItem?.button?.contentTintColor = NSColor(red: 0.96, green: 0.65, blue: 0.14, alpha: 1.0)
        case .working:
            // Teal — active
            statusItem?.button?.contentTintColor = NSColor(red: 0.31, green: 0.80, blue: 0.77, alpha: 1.0)
        case .idle, .stopped:
            // No tint — adapts to menu bar
            statusItem?.button?.contentTintColor = nil
        }
    }

    public func teardown() {
        iconCancellable = nil
        stopClickMonitoring()
        if let statusItem = statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil
        popover = nil
    }

    /// Auto-open popover (called on PermissionRequest)
    public func showPopover() {
        guard let popover = popover, let button = statusItem?.button, !popover.isShown else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        startClickMonitoring()
    }

    /// Show popover anchored to an arbitrary view (e.g. simulated notch).
    /// If already shown, close it.
    public func toggleAnchored(to view: NSView) {
        guard let popover = popover else { return }
        if popover.isShown {
            closePopover()
        } else {
            popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
            startClickMonitoring()
        }
    }

    /// Toggle popover (called by global hotkey)
    public func toggle() {
        togglePopover()
    }

    @objc private func togglePopover() {
        if let handler = onIconClick {
            handler()
            return
        }
        guard let popover = popover, let button = statusItem?.button else { return }
        if popover.isShown {
            closePopover()
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            startClickMonitoring()
        }
    }

    private func closePopover() {
        popover?.performClose(nil)
        stopClickMonitoring()
    }

    // MARK: - Outside-click dismissal

    /// Install global + local click monitors to dismiss the popover when the user
    /// clicks anywhere outside it. .transient behavior alone doesn't cover clicks
    /// into other apps or empty desktop areas for LSUIElement apps.
    private func startClickMonitoring() {
        stopClickMonitoring()  // just in case

        // Global monitor: fires for clicks in OTHER applications.
        // Any click → close.
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in
                self?.closePopover()
            }
        }

        // Local monitor: fires for clicks in THIS application's windows.
        // We need to check if the click is inside the popover window; if not, close it.
        // (Clicks inside the popover are passed through untouched.)
        localClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            guard let self = self else { return event }
            // If the click is in the popover's own window, let it through
            if let popoverWindow = self.popover?.contentViewController?.view.window,
               event.window === popoverWindow {
                return event
            }
            // If the click is on the status item button, let it toggle normally
            if let statusWindow = self.statusItem?.button?.window,
               event.window === statusWindow {
                return event
            }
            // Otherwise, close and swallow the event
            Task { @MainActor in
                self.closePopover()
            }
            return event
        }
    }

    private func stopClickMonitoring() {
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
            globalClickMonitor = nil
        }
        if let monitor = localClickMonitor {
            NSEvent.removeMonitor(monitor)
            localClickMonitor = nil
        }
    }
}
