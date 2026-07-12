import AppKit
import SwiftUI

@MainActor
public final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var viewModel: SettingsViewModel?
    private let updateChecker: UpdateChecker
    private let downloader: UpdateDownloader
    private let usageTracker: UsageTracker

    private var hotkeyWindow: HotkeyRecorderWindow?
    private var diagnosticsWindow: DiagnosticsWindow?
    private var uninstallWindow: UninstallWindow?

    public init(
        usageTracker: UsageTracker,
        updateChecker: UpdateChecker,
        downloader: UpdateDownloader
    ) {
        self.usageTracker = usageTracker
        self.updateChecker = updateChecker
        self.downloader = downloader
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    public func show() {
        let viewModel = self.viewModel ?? SettingsViewModel(usageTracker: usageTracker)
        self.viewModel = viewModel
        viewModel.refreshDisplayConfiguration()

        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            return
        }

        let rootView = SettingsRootView(
            viewModel: viewModel,
            updateChecker: updateChecker,
            downloader: downloader,
            changeHotkey: { [weak self] in self?.showHotkeyRecorder() },
            exportDiagnostics: { [weak self] in self?.showDiagnostics() },
            uninstallIntegrations: { [weak self] in self?.showUninstall() },
            quitApplication: { NSApp.terminate(nil) }
        )

        let size = NSSize(width: 720, height: 520)
        let window = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        window.title = "ZackEyes Settings"
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(white: 0.12, alpha: 1)
        window.titlebarAppearsTransparent = true
        window.contentView = NSHostingView(rootView: rootView)
        window.minSize = NSSize(width: 660, height: 460)
        window.isReleasedWhenClosed = false
        window.isFloatingPanel = true
        window.level = .floating
        window.hidesOnDeactivate = false
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.delegate = self
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        self.window = window
    }

    private func showHotkeyRecorder() {
        if hotkeyWindow == nil {
            hotkeyWindow = HotkeyRecorderWindow(onSaved: { [weak self] _ in
                self?.viewModel?.refreshHotkey()
            })
        }
        hotkeyWindow?.show()
    }

    private func showDiagnostics() {
        if diagnosticsWindow == nil {
            let tracker = usageTracker
            diagnosticsWindow = DiagnosticsWindow(
                makeReport: { DiagnosticsReport.current(usageSnapshot: tracker.snapshot) }
            )
        }
        diagnosticsWindow?.show()
    }

    private func showUninstall() {
        if uninstallWindow == nil {
            uninstallWindow = UninstallWindow()
        }
        uninstallWindow?.show()
    }

    nonisolated public func windowWillClose(_ notification: Notification) {
        Task { @MainActor [weak self] in
            self?.window = nil
        }
    }

    nonisolated public func windowDidBecomeKey(_ notification: Notification) {
        Task { @MainActor [weak self] in
            self?.setWindowLevel(isActive: true)
        }
    }

    nonisolated public func windowDidResignKey(_ notification: Notification) {
        Task { @MainActor [weak self] in
            self?.setWindowLevel(isActive: false)
        }
    }

    private func setWindowLevel(isActive: Bool) {
        window?.level = SettingsWindowLevelPolicy.level(isActive: isActive)
    }

    @objc private func screenParametersChanged(_ notification: Notification) {
        viewModel?.refreshDisplayConfiguration()
    }
}

enum SettingsWindowLevelPolicy {
    static func level(isActive: Bool) -> NSWindow.Level {
        isActive ? .floating : .normal
    }
}
