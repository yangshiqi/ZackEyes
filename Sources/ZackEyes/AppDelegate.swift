import AppKit
import AppLib
import Shared

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var socketServer: SocketServer!
    private var sessionStore: SessionStore!
    private var viewModel: NotchViewModel!
    private var windowController: NotchWindowController?
    private var menuBarFallback: MenuBarFallback?
    private var hotKeyManager: HotKeyManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Prevent macOS from auto-terminating this LSUIElement app when no windows are visible
        ProcessInfo.processInfo.disableAutomaticTermination("ZackEyes socket server must stay running")
        ProcessInfo.processInfo.disableSuddenTermination()

        // 1. Session Store
        sessionStore = SessionStore()

        // 2. View Model
        viewModel = NotchViewModel(sessionStore: sessionStore)

        // 3. Socket Server
        socketServer = SocketServer()
        socketServer.setEventHandler { [weak self] event, responder in
            self?.handleEvent(event, responder: responder)
        }
        socketServer.setPermissionAbandonedHandler { [weak self] sid in
            NSLog("ZackEyes: permission abandoned for session %@", sid)
            self?.sessionStore.abandonPermission(sessionId: sid)
        }
        do {
            try socketServer.start()
        } catch {
            NSLog("ZackEyes: Failed to start socket server: \(error)")
        }

        // 4. UI — Notch or Menu Bar
        if NSScreen.main?.hasNotch == true {
            let wc = NotchWindowController(viewModel: viewModel)
            wc.setup()
            windowController = wc
        } else {
            let mb = MenuBarFallback(viewModel: viewModel)
            mb.setup()
            menuBarFallback = mb
        }

        // 4.5 Global hotkey (Cmd+Shift+Z)
        let hk = HotKeyManager()
        hk.register { [weak self] in
            self?.menuBarFallback?.toggle()
            // TODO: notch mode — add NotchWindowController.toggleExpand() equivalent
        }
        hotKeyManager = hk

        // 5. Hook Installer (silent, best-effort)
        Task {
            do {
                let appPath = Bundle.main.bundlePath
                let installer = HookInstaller()
                try installer.installHooks()
                try installer.deployLauncherScript(appPath: appPath)
            } catch {
                NSLog("ZackEyes: Hook installation failed: \(error)")
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKeyManager?.unregister()
        socketServer?.stop()
        windowController?.teardown()
        menuBarFallback?.teardown()
    }

    // MARK: - Event Routing

    private func handleEvent(
        _ event: BridgeEvent,
        responder: (@Sendable (PermissionResponse) -> Void)?
    ) {
        switch event.bridgeEvent {
        case "PermissionRequest":
            guard let responder = responder else {
                NSLog("ZackEyes: PermissionRequest received but no responder")
                return
            }
            guard let sid = event.sessionId else {
                NSLog("ZackEyes: PermissionRequest missing session_id")
                return
            }
            let toolInput = event.toolInput?.mapValues { $0.value } ?? [:]
            let pending = PendingPermission(
                toolName: event.toolName ?? "Unknown",
                toolInput: toolInput,
                cwd: event.cwd,
                responder: responder
            )
            NSLog("ZackEyes: PermissionRequest for tool=%@", event.toolName ?? "?")
            sessionStore.handlePermissionRequest(sessionId: sid, permission: pending)
            windowController?.forceExpand()
            menuBarFallback?.showPopover()

        default:
            NSLog("ZackEyes: event=%@ tool=%@", event.bridgeEvent, event.toolName ?? "-")
            sessionStore.handleEvent(event)
            if event.bridgeEvent == "SessionStart" {
                windowController?.updatePanelState(.compact)
            }
            if event.bridgeEvent == "SessionEnd" {
                windowController?.updatePanelState(.collapsed)
            }
        }
    }
}
