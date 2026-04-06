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

    public init(viewModel: NotchViewModel) {
        self.viewModel = viewModel
        super.init()
    }

    public func setup() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.target = self
        self.statusItem = statusItem

        updateIcon(for: viewModel.sessionStore.state)

        // Observe state changes to update icon
        iconCancellable = viewModel.sessionStore.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.updateIcon(for: self.viewModel.sessionStore.state)
            }

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: NotchExpandedView(viewModel: viewModel)
                .frame(width: 360)
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
    }

    @objc private func togglePopover() {
        guard let popover = popover, let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}
