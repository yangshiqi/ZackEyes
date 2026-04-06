import AppKit
import SwiftUI

@MainActor
public class MenuBarFallback: NSObject {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private let viewModel: NotchViewModel

    public init(viewModel: NotchViewModel) {
        self.viewModel = viewModel
        super.init()
    }

    public func setup() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "Z"
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.target = self
        self.statusItem = statusItem

        let popover = NSPopover()
        popover.contentSize = NSSize(width: 360, height: 260)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: NotchExpandedView(viewModel: viewModel)
                .padding()
                .frame(width: 360)
                .background(Color.black)
        )
        self.popover = popover
    }

    public func teardown() {
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
