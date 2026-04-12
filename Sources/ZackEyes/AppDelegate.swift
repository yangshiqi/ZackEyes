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
    private var simulatedNotch: SimulatedNotchController?
    private var usageTracker: UsageTracker!
    private var hotKeyManager: HotKeyManager?
    private var updateChecker: UpdateChecker?
    private var livenessSweepTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Prevent macOS from auto-terminating this LSUIElement app when no windows are visible
        ProcessInfo.processInfo.disableAutomaticTermination("ZackEyes socket server must stay running")
        ProcessInfo.processInfo.disableSuddenTermination()

        // 0. Notifications — request permission, set tap handler
        NotificationManager.shared.requestAuthorization()
        NotificationManager.shared.onSessionTap = { [weak self] sessionId in
            guard let session = self?.sessionStore.sessions[sessionId],
                  let pid = session.claudePid else { return }
            _ = TerminalLocator.activateTerminal(containingPid: pid, cwd: session.cwd)
        }
        NotificationManager.shared.onUpdateTap = { url in
            NSWorkspace.shared.open(url)
        }

        // Prompt Accessibility permission ONCE at startup (for Ghostty/Warp/Kitty tab focus).
        // After this, clicks just silently check without re-prompting.
        TerminalLocator.promptAccessibilityIfNeeded()

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

        // 3.5 Usage tracker (reads JSONL transcripts, aggregates 5h/7d tokens)
        usageTracker = UsageTracker()

        // 4. UI — Notch or Menu Bar (+ simulated notch on notchless Macs)
        if NSScreen.main?.hasNotch == true {
            let wc = NotchWindowController(viewModel: viewModel)
            wc.setup()
            windowController = wc
        } else {
            // Menu bar button (click target for popover)
            let mb = MenuBarFallback(viewModel: viewModel)
            mb.setup()
            menuBarFallback = mb

            // Simulated Dynamic Island at top center (visual indicator)
            let uc = UpdateChecker()
            let sn = SimulatedNotchController(
                viewModel: viewModel,
                usageTracker: usageTracker,
                updateChecker: uc
            )
            sn.setup()
            simulatedNotch = sn
            updateChecker = uc
            // Tap handling lives inside the controller — it morphs the notch
            // panel itself into the full view (no separate NSPopover).
        }

        // 4.5 Global hotkey — toggles the simulated notch on notchless Macs,
        // falls back to the menu bar popover if neither exists.
        // Reads user-configured key from ~/.zackeyes/config.json (default: Cmd+Shift+Z).
        let hotkeyConfig = ConfigStore().load()
        let hk = HotKeyManager()
        hk.register(
            keyCode: hotkeyConfig.keyCode,
            modifiers: hotkeyConfig.modifiers.carbonFlags
        ) { [weak self] in
            guard let self = self else { return }
            if let sn = self.simulatedNotch {
                sn.toggleFull()
            } else {
                self.menuBarFallback?.toggle()
            }
        }
        hotKeyManager = hk

        // Listen for hotkey config changes from the recorder UI
        NotificationCenter.default.addObserver(
            forName: .hotkeyConfigChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let config = notification.userInfo?["config"] as? HotKeyConfig
            Task { @MainActor in
                guard let self, let config else { return }
                self.hotKeyManager?.reregister(
                    keyCode: config.keyCode,
                    modifiers: config.modifiers.carbonFlags
                )
            }
        }

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

        // 6.5 Update checker — polls GitHub Releases every 6h
        updateChecker?.onNewVersion = { version, url in
            NotificationManager.shared.notifyUpdateAvailable(version: version, releaseURL: url)
        }
        updateChecker?.start()

        // 6. Discover already-running sessions from ~/.claude/projects/.
        //    Filter by reverse cwd lookup: only import jsonl files whose
        //    project directory currently has a running `claude` process.
        //    For cwds with multiple live claudes, take the N most-recently
        //    modified jsonls (matches the live count). Runs off main actor
        //    since `ps` + `lsof` spawn subprocesses.
        let scanner = SessionScanner()
        let detected = scanner.scan(recencyMinutes: 480)  // 8h — covers a full work day
        Task.detached(priority: .userInitiated) { [weak self] in
            // ps/lsof off main; @MainActor SessionStore is touched only
            // inside the MainActor.run hop below via self?.sessionStore.
            //
            // Snapshot failure (nil) at startup falls back to importing
            // every detected session, mirroring the sweep's "do nothing"
            // semantics: better to show some tombstones temporarily than
            // to silently miss live sessions whose owning claude isn't
            // currently firing hooks. The 60s sweep cleans up if ps
            // recovers; if it stays broken, the user at least sees their
            // running sessions.
            let cwdCounts = TerminalLocator.runningClaudeCwds()
            let live = cwdCounts.map { LivenessFilter.filterLiveDetected(detected, cwdCounts: $0) }
                ?? detected
            await MainActor.run {
                self?.sessionStore.importDetectedSessions(live)
                NSLog(
                    "ZackEyes: imported %d live sessions (filtered from %d candidates)",
                    live.count, detected.count
                )
                // Kick off PID discovery + OSC2 title injection for the imported set
                self?.activateDetectedSessions()
            }
        }

        // 7. Periodic liveness sweep — every 60s, drop sessions whose cwd
        //    no longer matches any running `claude` process. Catches hard
        //    terminal closes, crashes, and any session whose claude exited
        //    without firing SessionEnd. Cross-references against `ps` so
        //    a transient sh wrapper around the bridge can't false-positive.
        livenessSweepTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.runLivenessSweep() }
        }
    }

    /// Discover the claude PID for each detected session and write OSC2 tab
    /// titles so click-to-jump works. Runs after `importDetectedSessions`.
    /// Off-main: lsof/ps subprocesses are slow.
    private func activateDetectedSessions() {
        let snapshots: [(id: String, cwd: String, transcript: String?, prompt: String?)] =
            sessionStore.sessions.values
                .filter { $0.source == .detected }
                .compactMap { s in
                    guard let cwd = s.cwd else { return nil }
                    return (s.id, cwd, s.transcriptPath, s.lastUserPrompt)
                }
        let store = sessionStore!
        Task.detached(priority: .utility) {
            var pidCache: [(String, Int)] = []
            for s in snapshots {
                guard let pid = TerminalLocator.findClaudePid(
                    transcriptPath: s.transcript, cwd: s.cwd
                ) else { continue }
                guard let tty = TTYUtil.ttyPath(pid: Int32(pid)) else { continue }

                // Write OSC2 title with sid marker
                let basename = (s.cwd as NSString).lastPathComponent
                let sidShort = String(s.id.prefix(8))
                // Sanitize: replace \n\r\t with space, strip C0 control chars + DEL
                let rawPrompt = s.prompt ?? ""
                var sanitized = ""
                for scalar in rawPrompt.unicodeScalars {
                    if scalar == "\n" || scalar == "\r" || scalar == "\t" {
                        sanitized.append(" ")
                    } else if scalar.value < 0x20 || scalar.value == 0x7F {
                        continue
                    } else {
                        sanitized.append(Character(scalar))
                    }
                }
                let prompt = String(sanitized.prefix(30))
                let title = prompt.isEmpty
                    ? "\(basename) · ze:\(sidShort)"
                    : "\(basename) · \(prompt) · ze:\(sidShort)"
                let osc = "\u{001B}]2;\(title)\u{0007}"
                if let data = osc.data(using: .utf8),
                   let fh = FileHandle(forWritingAtPath: tty) {
                    try? fh.write(contentsOf: data)
                    try? fh.close()
                }
                pidCache.append((s.id, pid))
            }
            // Cache PIDs on MainActor so click handler skips re-discovery.
            // Only fill in `claudePid` when it's still nil — never overwrite
            // a value the bridge already supplied via `bridgePpid` for a
            // session that was upgraded to .live in the meantime.
            await MainActor.run {
                for (sid, pid) in pidCache {
                    if var session = store.sessions[sid], session.claudePid == nil {
                        session.claudePid = pid
                        store.sessions[sid] = session
                    }
                }
                NSLog("ZackEyes: activated %d detected sessions with OSC2 titles", pidCache.count)
            }
        }
    }

    /// Periodic sweep: cross-reference each session's cwd against running
    /// `claude` processes and prune any that have no live owner. Snapshots
    /// from the main actor, then runs `ps`/`lsof` off main, then evicts
    /// back on main. Skips sessions with `pendingPermission` (handled by
    /// the bridge socket abandon path) and applies a 90-second activity
    /// grace period so a transient subprocess hiccup can't wipe live
    /// sessions whose hooks are still flowing.
    private func runLivenessSweep() {
        let candidates: [LivenessFilter.PruneCandidate] = sessionStore.sessions.values.compactMap { s in
            guard let cwd = s.cwd, s.pendingPermission == nil else { return nil }
            return LivenessFilter.PruneCandidate(id: s.id, cwd: cwd, lastActiveAt: s.lastActiveAt)
        }
        guard !candidates.isEmpty else { return }
        Task.detached(priority: .utility) { [weak self] in
            // ps/lsof off main; @MainActor SessionStore is touched only
            // inside the MainActor.run hop below via self?.sessionStore.
            let cwdCounts = TerminalLocator.runningClaudeCwds()
            let graceCutoff = Date().addingTimeInterval(-90)
            let deadIds = LivenessFilter.computeDeadIds(
                candidates: candidates,
                cwdCounts: cwdCounts,
                graceCutoff: graceCutoff
            )
            guard !deadIds.isEmpty else { return }
            await MainActor.run {
                self?.sessionStore.removeSessions(ids: deadIds)
                NSLog("ZackEyes: liveness sweep pruned %d dead sessions", deadIds.count)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        livenessSweepTimer?.invalidate()
        updateChecker?.stop()
        hotKeyManager?.unregister()
        socketServer?.stop()
        windowController?.teardown()
        menuBarFallback?.teardown()
        simulatedNotch?.teardown()
    }

    // MARK: - Event Routing

    private func handleEvent(
        _ event: BridgeEvent,
        responder: (@Sendable (PermissionResponse) -> Void)?
    ) {
        // Capture real subscriber rate limits if Claude Code provided them
        if let rl = event.rateLimits {
            usageTracker.updateFromHook(rateLimits: rl)
        }

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
            simulatedNotch?.dismissAboutOverlay()
            forceUiExpand()

        default:
            NSLog("ZackEyes: event=%@ tool=%@", event.bridgeEvent, event.toolName ?? "-")

            // Capture prior state BEFORE handling the event (for Stop detection)
            let priorState: SessionState? = event.sessionId.flatMap { sessionStore.sessions[$0]?.state }
            let priorErrorAt: Date? = event.sessionId.flatMap { sessionStore.sessions[$0]?.errorAt }
            let hadToolActivity = event.sessionId.flatMap {
                sessionStore.sessions[$0].map { $0.toolCallCount > 0 }
            } ?? false

            sessionStore.handleEvent(event)

            if event.bridgeEvent == "SessionStart" {
                windowController?.updatePanelState(.compact)
            }
            if event.bridgeEvent == "SessionEnd" {
                windowController?.updatePanelState(.collapsed)
            }

            guard let sid = event.sessionId,
                  let session = sessionStore.sessions[sid] else { return }

            // Notify if an error was JUST detected on this session
            if let errLabel = session.errorMessage,
               session.errorAt != priorErrorAt {
                NotificationManager.shared.notifyError(
                    sessionId: sid,
                    projectName: session.displayName,
                    errorLabel: errLabel,
                    detail: session.lastAssistantMessage
                )
                // Force the active UI to expand so the user sees the error
                forceUiExpand()
            }

            // Notify on Stop only if the session was actually doing something
            if event.bridgeEvent == "Stop",
               hadToolActivity,
               session.errorMessage == nil,  // don't double-notify on errors
               priorState == .working || priorState == .waiting {
                NotificationManager.shared.notifySessionFinished(
                    sessionId: sid,
                    projectName: session.displayName,
                    lastPrompt: session.lastUserPrompt
                )
            }
        }
    }

    /// Force the active UI surface to expand so the user can see/respond to
    /// a permission request or an error. Prefers the simulated notch (the
    /// Dynamic Island morph) when it exists; falls back to the real-notch
    /// window controller; falls back to the legacy menu bar popover only
    /// when neither richer surface is in play.
    private func forceUiExpand() {
        if let sn = simulatedNotch {
            sn.forceExpand()
            return
        }
        if let wc = windowController {
            wc.forceExpand()
            return
        }
        menuBarFallback?.showPopover()
    }
}
