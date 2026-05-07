import AppKit
import SwiftUI
import Combine
import Shared

@MainActor
public class MenuBarFallback: NSObject {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private let viewModel: NotchViewModel
    private let usageTracker: UsageTracker
    private var sessionCancellable: AnyCancellable?
    private var usageCancellable: AnyCancellable?
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?

    /// Called when the user clicks the status bar icon. If set, replaces
    /// the default popover toggle (e.g. to open the simulated notch instead).
    public var onIconClick: (() -> Void)?

    /// Supplies the right-click context menu. If nil, a minimal Quit-only
    /// menu is shown. Set by the App to provide the full About / Hotkey /
    /// Theme / Quit menu shared across both notch paths.
    public var menuBuilder: (() -> NSMenu)?

    public init(viewModel: NotchViewModel, usageTracker: UsageTracker) {
        self.viewModel = viewModel
        self.usageTracker = usageTracker
        super.init()
    }

    public func setup() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Route left-click to the configured handler (or popover fallback),
        // right-click to a small context menu that exposes Quit. Without
        // this, LSUIElement + notched Macs have no way to quit the app.
        statusItem.button?.action = #selector(handleButtonClick)
        statusItem.button?.target = self
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        self.statusItem = statusItem

        refreshIcon()

        // Both inputs (active session + rate-limit snapshot) can change
        // independently, so subscribe to each. objectWillChange fires
        // *before* the change applies — hop through the runloop so
        // refreshIcon sees the new value, not the pre-change one.
        sessionCancellable = viewModel.sessionStore.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshIcon() }
        usageCancellable = usageTracker.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshIcon() }

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: NotchExpandedView(viewModel: viewModel)
                .frame(width: 460)
                .background(Color.black)
        )
        self.popover = popover
    }

    private func refreshIcon() {
        // Bake the color into the symbol via paletteColors. Setting
        // contentTintColor + isTemplate is unreliable — in Light mode the
        // system overrides template tint to black regardless of what we
        // pass. Palette-rendered images keep the color we asked for.
        //
        // Color encodes the 5h subscriber-window quota of whichever agent
        // is "currently working" (see MenuBarIconColor for the priority).
        // Liveness state isn't reflected here — the notch panel + its
        // animations carry that signal; the menu bar only has color to
        // spend, so we spend it on the more durable rate-limit warning.
        let tint = MenuBarIconColor.tint(
            primaryAgent: viewModel.sessionStore.primarySession?.agent,
            snapshot: usageTracker.snapshot
        )
        let config = NSImage.SymbolConfiguration(paletteColors: [tint])
        guard let image = NSImage(systemSymbolName: "star.fill", accessibilityDescription: "ZackEyes")?
            .withSymbolConfiguration(config) else {
            return
        }
        image.isTemplate = false
        statusItem?.button?.image = image
        statusItem?.button?.title = ""
        statusItem?.button?.contentTintColor = nil
    }

    public func teardown() {
        sessionCancellable = nil
        usageCancellable = nil
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

    @objc private func handleButtonClick(_ sender: NSStatusBarButton) {
        // Right-click OR Control+LeftClick → context menu. The Control-click
        // path covers users without a configured secondary click (older
        // Macs, external single-button mice) and matches the standard
        // macOS status-item convention. Plain left-click falls through.
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp
        let isControlClick = event?.modifierFlags.contains(.control) ?? false
        if isRightClick || isControlClick {
            showContextMenu(from: sender)
        } else {
            togglePopover()
        }
    }

    private func showContextMenu(from button: NSStatusBarButton) {
        let menu = menuBuilder?() ?? fallbackMenu()
        // AppKit non-flipped coords: y=0 is the bottom edge of the button,
        // so anchoring there (with a 2pt gap) drops the menu straight down
        // below the status icon. Using bounds.height would place the anchor
        // ABOVE the button (off-screen at the menu-bar level) and rely on
        // AppKit's off-screen correction to clamp it back.
        let anchor = NSPoint(x: button.bounds.minX, y: button.bounds.minY - 2)
        menu.popUp(positioning: nil, at: anchor, in: button)
    }

    /// Minimal menu used when no builder is configured. Ensures Quit is
    /// always reachable even without app-level wiring.
    private func fallbackMenu() -> NSMenu {
        let menu = NSMenu()
        let quit = NSMenuItem(
            title: "Quit ZackEyes",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quit.target = NSApp
        menu.addItem(quit)
        return menu
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
