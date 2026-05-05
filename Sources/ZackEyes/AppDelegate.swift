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
    private var updateDownloader: UpdateDownloader?
    private var statusBarMenu: StatusBarMenu?
    private var livenessSweepTimer: Timer?
    private var codexTailer: CodexJsonlTailer?

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
        NotificationManager.shared.onUpdateTap = { [weak self] _ in
            guard let self,
                  let dmgURL = self.updateChecker?.dmgURL,
                  let dl = self.updateDownloader else { return }
            Task { @MainActor in await dl.download(from: dmgURL) }
        }

        // Accessibility is NOT prompted at startup. The focusByAccessibility
        // path (Ghostty/Warp/Kitty tab-jump) checks AXIsProcessTrusted()
        // lazily and degrades gracefully if untrusted. Users who need it
        // can grant it via System Settings when they first click a session
        // card and notice the tab doesn't focus.

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
        // UpdateChecker is ALWAYS created so real-notch users also get
        // version notifications (previously only the simulated-notch path
        // wired it up, silently leaving notched Macs on stale binaries).
        let uc = UpdateChecker()
        updateChecker = uc
        let dl = UpdateDownloader()
        updateDownloader = dl

        // Menu bar icon is ALWAYS shown: on notched Macs it's the only
        // non-CLI surface for Quit / About / Change Hotkey / Theme
        // (real-notch path has no gear menu).
        let mb = MenuBarFallback(viewModel: viewModel)
        mb.setup()
        menuBarFallback = mb

        // Shared right-click context menu (About / Update / Hotkey / Theme /
        // Quit). Both paths get the same menu; on simulated-notch it is
        // redundant with the gear button but harmless.
        let statusMenu = StatusBarMenu(updateChecker: uc, downloader: dl)
        mb.menuBuilder = { [weak statusMenu] in statusMenu?.build() ?? NSMenu() }
        self.statusBarMenu = statusMenu

        // Load persisted visibility up front — passing it into the controller
        // init avoids a first-frame flash where the panel would orderFront then
        // immediately orderOut again on a .hidden startup.
        let initialVisibility = ConfigStore().loadNotchVisibility()

        if NSScreen.main?.hasNotch == true {
            let wc = NotchWindowController(
                viewModel: viewModel,
                usageTracker: usageTracker,
                initialVisibility: initialVisibility
            )
            // Gear in the expanded panel pops the same StatusBarMenu as
            // the status-bar right-click — single source of truth for
            // About / Hotkey / Theme / Quit across both surfaces.
            wc.showMenu = { [weak statusMenu] view in
                guard let menu = statusMenu?.build() else { return }
                // Anchor at the bottom edge of the gear (AppKit non-flipped:
                // y=minY is bottom). Matches SimulatedNotchFullView.popGearMenu.
                let anchor = NSPoint(x: view.bounds.minX, y: view.bounds.minY - 2)
                menu.popUp(positioning: nil, at: anchor, in: view)
            }
            wc.setup()
            windowController = wc
            mb.onIconClick = { [weak wc] in wc?.forceExpand() }
        } else {
            // Simulated Dynamic Island at top center
            let sn = SimulatedNotchController(
                viewModel: viewModel,
                usageTracker: usageTracker,
                updateChecker: uc,
                downloader: dl,
                initialVisibility: initialVisibility
            )
            sn.setup()
            simulatedNotch = sn

            mb.onIconClick = { [weak sn] in sn?.toggleFull() }
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
            } else if let wc = self.windowController {
                wc.forceExpand()
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

        // Listen for visibility changes from the menu toggle.
        NotificationCenter.default.addObserver(
            forName: .notchVisibilityChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let visibility = notification.userInfo?["visibility"] as? NotchVisibility ?? .always
            Task { @MainActor in
                guard let self else { return }
                self.windowController?.applyVisibility(visibility)
                self.simulatedNotch?.applyVisibility(visibility)
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
            // Codex installer is independent — failure here must not affect
            // the Claude install. Skips silently if `~/.codex/` is absent.
            do {
                let codexInstaller = CodexHookInstaller()
                try codexInstaller.installHooks()
            } catch {
                NSLog("ZackEyes: Codex hook installation failed: \(error)")
            }
        }

        // 6.5 Update checker — polls GitHub Releases every 6h
        updateChecker?.onNewVersion = { version, url in
            NotificationManager.shared.notifyUpdateAvailable(version: version, releaseURL: url)
        }
        updateChecker?.start()

        // 6. Discover already-running sessions from ~/.claude/projects/
        //    and ~/.codex/sessions/. Filter by reverse cwd lookup: only
        //    import jsonl files whose project directory currently has a
        //    running `claude` process (codex sessions pass through the
        //    filter unchanged — see LivenessFilter). For cwds with
        //    multiple live claudes, take the N most-recently modified
        //    jsonls (matches the live count). Runs off main actor —
        //    both `scanner.scan()` and `ps`/`lsof` do disk + subprocess
        //    work that must not block the main thread on first launch.
        Task.detached(priority: .userInitiated) { [weak self] in
            let scanner = SessionScanner()
            // Claude session lifecycles can span hours; codex creates a
            // fresh rollout per invocation, so a tight window keeps stale
            // closed-TUI rollouts out of the notch.
            let detected = scanner.scan(
                claudeRecencyMinutes: 480,   // 8h
                codexRecencyMinutes: 30      // 30 min
            )
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

        // 7.5 Codex jsonl tailer. Real-time fallback for codex sessions
        //     whose owning TUI predates ~/.codex/hooks.json (those processes
        //     never picked up our hooks and never fire Stop). The tailer
        //     watches the rollouts and fires a notification on each
        //     `event_msg.task_complete` line.
        let tailer = CodexJsonlTailer()
        tailer.delegate = self
        tailer.start()
        codexTailer = tailer

        // 8. First-launch welcome — per-version one-shot. Runs last so the
        //    notch controllers are already created and reachable via
        //    forceUiExpand().
        maybeShowWelcome()
    }

    /// Discover the agent PID for each detected session and write OSC2 tab
    /// titles so click-to-jump works. Runs after `importDetectedSessions`.
    /// Off-main: lsof/ps subprocesses are slow.
    private func activateDetectedSessions() {
        let snapshots: [(id: String, agent: AgentKind, cwd: String, transcript: String?, prompt: String?)] =
            sessionStore.sessions.values
                .filter { $0.source == .detected }
                .compactMap { s in
                    guard let cwd = s.cwd else { return nil }
                    return (s.id, s.agent, cwd, s.transcriptPath, s.lastUserPrompt)
                }
        let store = sessionStore!
        Task.detached(priority: .utility) {
            var pidCache: [(String, Int)] = []
            for s in snapshots {
                guard let pid = TerminalLocator.findAgentPid(
                    agent: s.agent,
                    transcriptPath: s.transcript,
                    cwd: s.cwd
                ) else { continue }
                _ = TerminalLocator.writeSessionTitle(
                    containingPid: pid,
                    cwd: s.cwd,
                    sessionId: s.id,
                    prompt: s.prompt
                )
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
        // --- Codex idle prune (time-based, no `ps` needed) -------------
        // Codex has no `runningCodexCwds()` analog yet, so we can't ask
        // "is the owning TUI still alive" the way we do for Claude. Time
        // is the next-best signal: codex writes `token_count` events on
        // every turn, so a session whose `lastActiveAt` is older than
        // the threshold is either closed or the user walked away. A live
        // codex thread that asks another question post-eviction will
        // re-appear automatically — `CodexJsonlTailer` is still watching
        // the rollout, and the next `task_complete` re-creates the
        // session via `SessionStore.recordCodexTaskComplete`.
        let codexIdleCutoff = Date().addingTimeInterval(-15 * 60)  // 15 min
        let staleCodexIds = Set(
            sessionStore.sessions.values
                .filter { $0.agent == .codex
                       && $0.pendingPermission == nil
                       && $0.lastActiveAt < codexIdleCutoff }
                .map { $0.id }
        )
        if !staleCodexIds.isEmpty {
            sessionStore.removeSessions(ids: staleCodexIds)
            NSLog("ZackEyes: pruned %d idle codex sessions", staleCodexIds.count)
        }

        // --- Claude liveness check (cwd → running `claude` matching) ---
        // The cwd→count snapshot below matches `claude` argv strictly
        // (see TerminalLocator); feeding a codex session through it would
        // always come up "no live owner" and evict the session, which is
        // why we filter to .claude here.
        let candidates: [LivenessFilter.PruneCandidate] = sessionStore.sessions.values.compactMap { s in
            guard s.agent == .claude else { return nil }
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
        responder: (@Sendable (BridgeResponse) -> Void)?
    ) {
        // Capture real subscriber rate limits if Claude Code provided them
        if let rl = event.rateLimits {
            usageTracker.updateFromHook(rateLimits: rl)
        }

        switch event.bridgeEvent {
        case "PermissionRequest":
            // PreToolUse path now owns AskUserQuestion. If a stale PermissionRequest
            // for AskUQ comes through (user with strict allow list), auto-allow so
            // it doesn't render behind the new clickable PreToolUse flow.
            if event.toolName == "AskUserQuestion" {
                responder?(.permission(.allow(message: "Handled by PreToolUse")))
                return
            }
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
            NSLog("ZackEyes: PermissionRequest agent=%@ tool=%@",
                  event.agent.rawValue, event.toolName ?? "?")
            sessionStore.handlePermissionRequest(
                sessionId: sid, permission: pending, agent: event.agent
            )
            simulatedNotch?.dismissAboutOverlay()
            forceUiExpand()

        case "PreToolUse" where event.toolName == "AskUserQuestion":
            guard let responder = responder else {
                NSLog("ZackEyes: PreToolUse AskUQ received but no responder")
                return
            }
            guard let sid = event.sessionId else {
                NSLog("ZackEyes: PreToolUse AskUQ missing session_id")
                return
            }
            let toolInput = event.toolInput?.mapValues { $0.value } ?? [:]
            let pending = PendingPermission(
                toolName: event.toolName ?? "AskUserQuestion",
                toolInput: toolInput,
                cwd: event.cwd,
                responder: responder
            )
            NSLog("ZackEyes: PreToolUse AskUQ for tool=AskUserQuestion")
            sessionStore.handlePermissionRequest(
                sessionId: sid, permission: pending, agent: event.agent
            )
            simulatedNotch?.dismissAboutOverlay()
            forceUiExpand()

        default:
            // Always log the agent so codex/claude bugs can be told apart
            // from a single Console.app filter ("ZackEyes:").
            NSLog("ZackEyes: agent=%@ event=%@ tool=%@ sid=%@",
                  event.agent.rawValue,
                  event.bridgeEvent,
                  event.toolName ?? "-",
                  event.sessionId.map { String($0.prefix(8)) } ?? "-")

            // Capture prior state BEFORE handling the event (for Stop detection)
            let priorState: SessionState? = event.sessionId.flatMap { sessionStore.sessions[$0]?.state }
            let priorErrorAt: Date? = event.sessionId.flatMap { sessionStore.sessions[$0]?.errorAt }
            let priorToolCount = event.sessionId.flatMap {
                sessionStore.sessions[$0]?.toolCallCount
            } ?? 0
            let priorUserPrompt = event.sessionId.flatMap {
                sessionStore.sessions[$0]?.lastUserPrompt
            }

            sessionStore.handleEvent(event)

            // Compact is the resting state and is always visible —
            // no SessionStart/SessionEnd panel-state transitions needed.
            // (The expanded panel still auto-opens via forceUiExpand on
            // PermissionRequest / error.)

            guard let sid = event.sessionId,
                  let session = sessionStore.sessions[sid] else { return }

            // Notify if an error was JUST detected on this session
            if let errLabel = session.errorMessage,
               session.errorAt != priorErrorAt {
                NotificationManager.shared.notifyError(
                    sessionId: sid,
                    agent: session.agent,
                    projectName: session.displayName,
                    errorLabel: errLabel,
                    detail: session.lastAssistantMessage
                )
                // Force the active UI to expand so the user sees the error
                forceUiExpand()
            }

            // Notify on Stop. The session must have done something this
            // turn — either ran a tool (toolCallCount went up) or had a
            // user prompt waiting on a reply. The earlier gate only
            // checked `toolCallCount > 0` over the session lifetime, which
            // suppressed notifications on chat-only turns where the agent
            // answers without invoking any tools (common with Codex).
            if event.bridgeEvent == "Stop",
               session.errorMessage == nil,    // don't double-notify on errors
               priorState == .working || priorState == .waiting {
                let didWorkThisTurn = session.toolCallCount > priorToolCount
                let hasInteraction = priorUserPrompt != nil
                if didWorkThisTurn || hasInteraction {
                    NotificationManager.shared.notifySessionFinished(
                        sessionId: sid,
                        agent: session.agent,
                        projectName: session.displayName,
                        lastPrompt: session.lastUserPrompt
                    )
                }
            }
        }
    }

    /// First-launch onboarding: expand the notch panel, render the welcome
    /// overlay, play the theme chime, auto-collapse after 3 seconds. Fires
    /// once per bundle version; no-op on subsequent launches.
    private func maybeShowWelcome() {
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        guard WelcomeTrigger.shouldShowWelcome(
            defaults: .standard,
            currentVersion: currentVersion
        ) else { return }

        viewModel.welcomeVisible = true
        forceUiExpand()
        NotificationManager.shared.playChime()

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self else { return }
            self.viewModel.welcomeVisible = false
            // Explicit collapse: the mouse-out debounce only fires when the
            // cursor actually moves out of the panel, so without this the
            // panel would sit expanded forever if the user isn't moving
            // their mouse at app launch.
            self.forceUiCompact()
            WelcomeTrigger.markShown(defaults: .standard, currentVersion: currentVersion)
        }
    }

    /// Mirror of `forceUiExpand()` — forces whichever active notch surface
    /// back to its compact state. Used by the welcome onboarding coordinator
    /// to guarantee auto-collapse after 3 seconds regardless of mouse position.
    ///
    /// No-ops if any session has a `pendingPermission`: the mouse-move
    /// collapse path already gates on this via `stickyOpen`, but explicit
    /// callers (welcome) must replicate the gate or they'd collapse the
    /// panel out from under a permission request that happened to arrive
    /// during the welcome window.
    private func forceUiCompact() {
        let hasPending = sessionStore.sessions.values.contains { $0.pendingPermission != nil }
        if hasPending { return }

        if let sn = simulatedNotch {
            sn.forceCompact()
            return
        }
        if let wc = windowController {
            wc.updatePanelState(.compact)
            return
        }
        // No notch surface — the menu-bar popover opens/closes on its own
        // click, so there's nothing to collapse here.
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

// MARK: - CodexJsonlTailerDelegate

extension AppDelegate: CodexJsonlTailerDelegate {
    /// Tailer detected an `event_msg.task_started` for a codex session.
    /// Mark detected/non-hooked sessions as working so the notch avatar uses
    /// the active animation while Codex is generating.
    func codexTailer(_ tailer: CodexJsonlTailer, didDetectTaskStarted event: CodexTaskStartedEvent) {
        if let existing = sessionStore.sessions[event.sessionId], existing.source == .live {
            return
        }

        sessionStore.recordCodexTaskStarted(
            sessionId: event.sessionId,
            cwd: event.cwd,
            transcriptPath: event.transcriptPath,
            startedAt: event.startedAt ?? Date(),
            turnId: event.turnId
        )
        activateCodexSession(event.sessionId)
    }

    /// Tailer detected an `event_msg.task_complete` for a codex session.
    /// Delegate the session-state mutation to SessionStore (mirrors the
    /// Stop branch of `handleEvent`), then fire the UI notification.
    func codexTailer(_ tailer: CodexJsonlTailer, didDetectTaskComplete event: CodexTaskCompleteEvent) {
        // If the session already has a `.live` state in our store, hooks
        // are flowing for it and the existing Stop path will deliver the
        // notification. Skip the tailer-side notification.
        if let existing = sessionStore.sessions[event.sessionId], existing.source == .live {
            return
        }

        let session = sessionStore.recordCodexTaskComplete(
            sessionId: event.sessionId,
            cwd: event.cwd,
            lastAgentMessage: event.lastAgentMessage,
            transcriptPath: event.transcriptPath,
            completedAt: event.completedAt ?? Date()
        )

        NotificationManager.shared.notifySessionFinished(
            sessionId: event.sessionId,
            agent: .codex,
            projectName: session.displayName,
            lastPrompt: session.lastUserPrompt
        )
    }

    private func activateCodexSession(_ sessionId: String) {
        guard let session = sessionStore.sessions[sessionId],
              let cwd = session.cwd else { return }
        let transcriptPath = session.transcriptPath
        let prompt = session.lastUserPrompt
        let store = sessionStore!

        Task.detached(priority: .utility) {
            guard let pid = TerminalLocator.findAgentPid(
                agent: .codex,
                transcriptPath: transcriptPath,
                cwd: cwd
            ) else { return }
            _ = TerminalLocator.writeSessionTitle(
                containingPid: pid,
                cwd: cwd,
                sessionId: sessionId,
                prompt: prompt
            )
            await MainActor.run {
                if var session = store.sessions[sessionId], session.claudePid == nil {
                    session.claudePid = pid
                    store.sessions[sessionId] = session
                }
            }
        }
    }
}
