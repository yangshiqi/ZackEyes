import AppKit
import AppLib
import Combine
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

    /// Last blocked-waiting alert time per session, for the #169 per-session
    /// cooldown (see `maybeNotifyWaiting`).
    private var lastWaitingAlertAt: [String: Date] = [:]
    /// #186 — per-session cooldown shared by BOTH compact-finished paths
    /// (real PostCompact + StatusLine inference), so if upstream ever starts
    /// firing PostCompact interactively the two can't double-chime.
    private var lastCompactAlertAt: [String: Date] = [:]
    private var hotKeyManager: HotKeyManager?
    private var updateChecker: UpdateChecker?
    private var updateDownloader: UpdateDownloader?
    private var pricingStore: PricingStore?
    private var statusBarMenu: StatusBarMenu?
    private var settingsWindowController: SettingsWindowController?
    private var livenessSweepTimer: Timer?
    private var codexTailer: CodexJsonlTailer?
    private var cancellables = Set<AnyCancellable>()
    /// #48 — tracks whether the store had any sessions at the last
    /// `.whenActive` visibility evaluation, so we only order the panel
    /// in/out on the empty↔non-empty boundary (not on every event-field
    /// mutation, which would flicker the window).
    private var lastHadSessionsForVisibility = false

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
        socketServer.setEventHandler { [weak self] event, responder, permissionId in
            self?.handleEvent(event, responder: responder, permissionId: permissionId)
        }
        socketServer.setPermissionAbandonedHandler { [weak self] sid, requestId in
            NSLog("ZackEyes: permission abandoned for session %@", sid)
            self?.sessionStore.abandonPermission(sessionId: sid, requestId: requestId)
            // The popup was force-expanded when the request arrived; the
            // user just answered in the agent terminal instead, so collapse
            // it back to compact. The mouse-out / outside-click paths only
            // fire on actual cursor movement — without an explicit collapse
            // the panel sits open with stale "no pending" content until the
            // user happens to move their mouse. forceUiCompact gates on
            // hasPending, so other sessions still waiting stay expanded.
            self?.forceUiCompact()
        }
        do {
            try socketServer.start()
            // #89 — replay fire-and-forget events the bridge spooled while the
            // app was closed. Same routing as live socket events; isReplayed
            // suppresses stale notifications inside handleEvent.
            let replayedCount = PendingEventReplayer().replayAll { [weak self] event in
                self?.handleEvent(event, responder: nil)
            }
            if replayedCount > 0 {
                NSLog("ZackEyes: replayed %d pending hook events", replayedCount)
            }
        } catch SocketError.alreadyRunning {
            // Another copy already owns the socket. Carrying on would leave a
            // second menu bar icon and a second notch panel that can never
            // receive an event — silently useless (#205). Hand the user back to
            // the instance that works.
            NSLog("ZackEyes: another instance already owns the socket; exiting")
            presentAlreadyRunningAlert()
            NSApp.terminate(nil)
            return
        } catch {
            NSLog("ZackEyes: Failed to start socket server: \(error)")
        }

        // 3.5 Pricing table (must exist + be wired before the usage tracker starts,
        // so the first daily refresh prices against the loaded bundled/cache table).
        let ps = PricingStore()
        pricingStore = ps
        ps.start()

        // 3.6 Usage tracker (5h/7d quota + #84 daily consumption). Pricing wired in
        // so daily cost is available from the first refresh.
        usageTracker = UsageTracker()
        usageTracker.pricingStore = ps
        usageTracker.compactAgent = ConfigStore().loadCompactAgent()
        // #78: let SessionStore price Codex per-session cost (raw model id →
        // ModelPrice) without coupling it to PricingStore/Bundle.
        sessionStore.codexPriceLookup = { [weak ps] model in ps?.price(for: model) }
        usageTracker.showTodayConsumption = ConfigStore().loadShowTodayConsumption()
        usageTracker.timeProgressMode = ConfigStore().loadTimeProgressMode()
        usageTracker.progressMode = ConfigStore().loadProgressMode()
        usageTracker.leftProgressDirection = ConfigStore().loadLeftProgressDirection()
        usageTracker.timeOverlayOpacity = ConfigStore().loadTimeOverlayOpacity()
        // Real-notch path doesn't go through SimulatedNotchController, so the
        // tracker would never start its 30s refresh loop and the menu-bar
        // star would stay white forever. Start it here unconditionally —
        // the simulated path's `start()` is idempotent (cancels + restarts
        // the same task), so this is safe whether or not we hit that branch.
        usageTracker.start(intervalSeconds: 30)

        // 4. UI — Notch or Menu Bar (+ simulated notch on notchless Macs)
        // UpdateChecker is ALWAYS created so real-notch users also get
        // version notifications (previously only the simulated-notch path
        // wired it up, silently leaving notched Macs on stale binaries).
        let uc = UpdateChecker()
        updateChecker = uc
        let dl = UpdateDownloader()
        updateDownloader = dl

        // Menu bar icon is ALWAYS shown so Settings, About and Quit remain
        // reachable even when the notch visibility preference is Hidden.
        let mb = MenuBarFallback(viewModel: viewModel, usageTracker: usageTracker)
        mb.setup()
        menuBarFallback = mb

        let settingsWindow = SettingsWindowController(
            usageTracker: usageTracker,
            updateChecker: uc,
            downloader: dl
        )
        settingsWindowController = settingsWindow

        // The context menu now contains only app-level commands. All
        // preferences are hosted by the shared Settings window.
        let statusMenu = StatusBarMenu(updateChecker: uc, downloader: dl)
        mb.menuBuilder = { [weak statusMenu] in statusMenu?.build() ?? NSMenu() }
        self.statusBarMenu = statusMenu

        NotificationCenter.default.addObserver(
            forName: .settingsWindowRequested,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.settingsWindowController?.show()
                self.forceUiCompact()
            }
        }

        NotificationCenter.default.addObserver(
            forName: .settingsAppearanceChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.viewModel.objectWillChange.send() }
        }

        // Load persisted visibility up front — passing it into the controller
        // init avoids a first-frame flash where the panel would orderFront then
        // immediately orderOut again on a .hidden startup.
        let initialVisibility = ConfigStore().loadNotchVisibility()

        // Decide by "is any connected display notched", NOT NSScreen.main:
        // main follows keyboard focus, so launching with a window focused on
        // an external monitor would wrongly take the simulated path on a real
        // notched MacBook (issue #64).
        if NSScreen.hasAnyNotch {
            let wc = NotchWindowController(
                viewModel: viewModel,
                usageTracker: usageTracker,
                initialVisibility: initialVisibility
            )
            wc.menuBuilder = { [weak statusMenu] in statusMenu?.build() ?? NSMenu() }
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
            sn.menuBuilder = { [weak statusMenu] in statusMenu?.build() ?? NSMenu() }
            sn.setup()
            simulatedNotch = sn

            mb.onIconClick = { [weak sn] in sn?.toggleFull() }
        }

        // Local design-review entry point: launching the executable with
        // `--settings` opens the same singleton window as either gear button.
        if CommandLine.arguments.contains("--settings") {
            DispatchQueue.main.async {
                settingsWindow.show()
            }
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

        // Listen for compact-agent selection changes from the status-bar menu
        NotificationCenter.default.addObserver(
            forName: .compactAgentChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let agent = notification.userInfo?["agent"] as? AgentKind else { return }
            Task { @MainActor in self?.usageTracker.compactAgent = agent }
        }

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
                self.lastHadSessionsForVisibility = !self.sessionStore.sessions.isEmpty
            }
        }

        // #48 — for .whenActive, show/hide the panel as sessions come and
        // go. Only act on the empty↔non-empty boundary. `.receive(on:)`
        // defers delivery until after the store mutation lands, so a 0→1
        // transition reads the post-change count.
        sessionStore.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                // Boundary check first so the no-change common case (every
                // event-field mutation fires objectWillChange) skips the
                // config disk read entirely.
                let hasSessions = !self.sessionStore.sessions.isEmpty
                guard hasSessions != self.lastHadSessionsForVisibility else { return }
                guard ConfigStore().loadNotchVisibility() == .whenActive else { return }
                self.lastHadSessionsForVisibility = hasSessions
                self.windowController?.applyVisibility(.whenActive)
                self.simulatedNotch?.applyVisibility(.whenActive)
            }
            .store(in: &cancellables)

        // 5. Hook Installer (silent, best-effort) — same path as the Hook
        //    Status window's Repair button.
        Task {
            HookRepair.run(appPath: Bundle.main.bundlePath)
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
            //
            // Skip ps/lsof entirely when there's nothing to filter —
            // saves ~100-200ms of subprocess startup on first launch
            // for users with no recent jsonl activity.
            let live: [SessionScanner.DetectedSession]
            if detected.isEmpty {
                live = []
            } else {
                let cwdCounts = TerminalLocator.runningClaudeCwds()
                // Codex map is independent — if `ps` for codex fails (nil)
                // we fall back to "import every detected codex session"
                // rather than dropping silently. The 60s sweep handles
                // eviction once ps recovers.
                let codexCwdCounts = TerminalLocator.runningCodexCwds()
                live = cwdCounts.map {
                    LivenessFilter.filterLiveDetected(
                        detected,
                        cwdCounts: $0,
                        codexCwdCounts: codexCwdCounts
                    )
                } ?? detected
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.sessionStore.importDetectedSessions(live)
                NSLog(
                    "ZackEyes: imported %d live sessions (filtered from %d candidates)",
                    live.count, detected.count
                )
                // Kick off PID discovery + OSC2 title injection for the imported set
                self.activateDetectedSessions()
            }
        }

        // 7. Periodic liveness sweep — every 60s, drop sessions whose cwd
        //    no longer matches any running `claude` process. Catches hard
        //    terminal closes, crashes, and any session whose claude exited
        //    without firing SessionEnd. Cross-references against `ps` so
        //    a transient sh wrapper around the bridge can't false-positive.
        //    Also re-scans Claude transcripts each tick (#83) so sessions started after launch surface even with no hooks installed.
        livenessSweepTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.runLivenessSweep()
                self?.runPassiveClaudeRescan()
            }
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
                    // Already activated on a prior pass — periodic rescan (#83) must not
                    // re-lsof / re-write titles for known sessions; failed discoveries
                    // (pid still nil) retry naturally.
                    guard s.claudePid == nil else { return nil }
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
        // Snapshot pruning candidates per agent on the main actor, then
        // resolve each agent's live-cwd map off-main and call the same
        // `LivenessFilter.computeDeadIds` for both. Codex now has its own
        // ps-based liveness signal — when the codex TUI exits the cards
        // disappear at the next sweep tick instead of lingering for the
        // legacy 15-min idle window.
        let claudeCandidates: [LivenessFilter.PruneCandidate] = sessionStore.sessions.values.compactMap { s in
            guard s.agent == .claude else { return nil }
            guard let cwd = s.cwd, s.pendingPermission == nil else { return nil }
            return LivenessFilter.PruneCandidate(
                id: s.id, cwd: cwd, lastActiveAt: s.lastActiveAt, pid: s.claudePidFromHook ? s.claudePid : nil)
        }
        let codexCandidates: [LivenessFilter.PruneCandidate] = sessionStore.sessions.values.compactMap { s in
            guard s.agent == .codex else { return nil }
            guard let cwd = s.cwd, s.pendingPermission == nil else { return nil }
            return LivenessFilter.PruneCandidate(
                id: s.id, cwd: cwd, lastActiveAt: s.lastActiveAt, pid: s.claudePidFromHook ? s.claudePid : nil)
        }

        // Codex sessions with `cwd == nil` (session_meta not yet written, or
        // parse failure) bypass the ps-based sweep entirely — without this
        // fallback they'd never be evicted once the codex TUI exits. Keep
        // the legacy 15-min idle prune for that narrow case so we don't
        // accumulate zombie cards.
        let codexIdleCutoff = Date().addingTimeInterval(-15 * 60)
        let staleNoCwdCodexIds = Set(
            sessionStore.sessions.values
                .filter { $0.agent == .codex
                       && $0.cwd == nil
                       && $0.pendingPermission == nil
                       && $0.lastActiveAt < codexIdleCutoff }
                .map { $0.id }
        )
        if !staleNoCwdCodexIds.isEmpty {
            sessionStore.removeSessions(ids: staleNoCwdCodexIds)
            NSLog("ZackEyes: pruned %d nil-cwd codex sessions (idle > 15min)",
                  staleNoCwdCodexIds.count)
        }

        guard !claudeCandidates.isEmpty || !codexCandidates.isEmpty else { return }

        Task.detached(priority: .utility) { [weak self] in
            // ps/lsof off main; @MainActor SessionStore is touched only
            // inside the MainActor.run hop below via self?.sessionStore.
            let graceCutoff = Date().addingTimeInterval(-90)
            var deadIds = Set<String>()

            // #217 — each agent's live PID set is the exact signal for the
            // sessions we learned a PID for; the cwd map stays for the rest.
            if !claudeCandidates.isEmpty {
                let cwdCounts = TerminalLocator.runningClaudeCwds()
                deadIds.formUnion(LivenessFilter.computeDeadIds(
                    candidates: claudeCandidates,
                    cwdCounts: cwdCounts,
                    livePids: TerminalLocator.runningClaudePidSet(),
                    graceCutoff: graceCutoff
                ))
            }
            if !codexCandidates.isEmpty {
                let cwdCounts = TerminalLocator.runningCodexCwds()
                deadIds.formUnion(LivenessFilter.computeDeadIds(
                    candidates: codexCandidates,
                    cwdCounts: cwdCounts,
                    livePids: TerminalLocator.runningCodexPidSet(),
                    graceCutoff: graceCutoff
                ))
            }

            guard !deadIds.isEmpty else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                // The verdict was computed from a snapshot taken before the
                // `ps` calls ran, but removal happens by id. Anything that
                // became active in between — a hook landing mid-sweep, or the
                // same session id being resumed — must not be deleted on the
                // strength of a stale reading. Re-check against the same
                // cutoff the decision used.
                let stillIdle = deadIds.filter { id in
                    guard let s = self.sessionStore.sessions[id] else { return false }
                    return s.lastActiveAt <= graceCutoff
                }
                guard !stillIdle.isEmpty else { return }
                self.sessionStore.removeSessions(ids: stillIdle)
                NSLog("ZackEyes: liveness sweep pruned %d dead sessions", stillIdle.count)
            }
        }
    }

    /// #83 — passive fallback discovery. The startup scan runs once, so
    /// without hooks a session started after launch would never appear.
    /// Each sweep tick re-scans Claude transcripts and imports new/updated
    /// detected sessions. Claude-only: codex has its own kqueue tailer with
    /// 30s rediscovery (invariant #7 — codex never enters the claude cwd
    /// liveness filter).
    private func runPassiveClaudeRescan() {
        Task.detached(priority: .utility) { [weak self] in
            // claude-only rescan: skip the codex tree walk entirely
            let scanner = SessionScanner(codexSessionsDir: nil)
            let detected = scanner.scan(
                claudeRecencyMinutes: 480,   // same 8h window as startup
                codexRecencyMinutes: 0       // codex path skipped entirely
            ).filter { $0.agent == .claude }
            guard !detected.isEmpty else { return }

            // Unlike startup (ps failure ⇒ import-all fallback), the
            // periodic path requires a live cwd map: resurrecting sessions
            // the sweep just pruned, on a transient ps hiccup, would make
            // cards flap. Skip the tick instead — the next one retries.
            guard let cwdCounts = TerminalLocator.runningClaudeCwds() else { return }
            let live = LivenessFilter.filterLiveDetected(
                detected, cwdCounts: cwdCounts, codexCwdCounts: nil)
            guard !live.isEmpty else { return }

            await MainActor.run { [weak self] in
                guard let self else { return }
                let imported = self.sessionStore.importDetectedSessions(live)
                if imported > 0 {
                    NSLog("ZackEyes: passive rescan imported %d claude sessions", imported)
                    // PID discovery + OSC2 titles only when something new landed.
                    self.activateDetectedSessions()
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        livenessSweepTimer?.invalidate()
        updateChecker?.stop()
        pricingStore?.stop()
        hotKeyManager?.unregister()
        socketServer?.stop()
        windowController?.teardown()
        menuBarFallback?.teardown()
        simulatedNotch?.teardown()
    }

    // MARK: - Event Routing

    private func handleEvent(
        _ event: BridgeEvent,
        responder: (@Sendable (BridgeResponse) -> Void)?,
        permissionId: UUID? = nil
    ) {
        // #205 item 3 — stamp every arrival before any branch can return, so
        // the trace can never have a silent hole. Branches below refine the
        // verdict via `note`; anything still `.received` at render time is an
        // unclassified path, which the report says out loud.
        EventTrace.shared.record(event)

        // A self-test probe proves the pipeline works and must not leave a
        // session card behind for a run that never happened (#205).
        if HookSelfTest.isProbe(sessionId: event.sessionId) {
            EventTrace.shared.note(.probe)
            NotificationCenter.default.post(
                name: .hookSelfTestProbeReceived, object: event.sessionId)
            return
        }

        // Capture real subscriber rate limits if Claude Code provided them
        if let rl = event.rateLimits {
            usageTracker.updateFromHook(rateLimits: rl)
        }

        switch event.bridgeEvent {
        case "PermissionRequest":
            // AskUserQuestion: bridge fire-and-forgets these, so there is no
            // responder to satisfy. The PreToolUse popup is the user-facing
            // surface; CC's terminal UI runs in parallel as the fallback.
            // Dropping the event here (instead of auto-allowing) prevents the
            // empty-answer/PostToolUse short-circuit that was clearing the
            // popup before the user could click an option.
            if event.toolName == "AskUserQuestion" {
                EventTrace.shared.note(.dropped("AskUserQuestion has no responder path"))
                return
            }
            guard let responder = responder else {
                EventTrace.shared.note(.dropped("no responder"))
                NSLog("ZackEyes: PermissionRequest received but no responder")
                return
            }
            guard let sid = event.sessionId else {
                EventTrace.shared.note(.dropped("no session_id"))
                NSLog("ZackEyes: PermissionRequest missing session_id")
                return
            }
            let toolName = event.toolName ?? "Unknown"
            // "Allow Always": a prior click approved this tool for the rest of the
            // session, so auto-allow without building a pending / expanding the
            // panel. Same client-side auto-respond pattern as the AskUQ early
            // return above.
            if sessionStore.isToolAutoAllowed(sessionId: sid, toolName: toolName) {
                EventTrace.shared.note(.autoAllowed)
                responder(.permission(.allow(message: "Auto-allowed via ZackEyes (Allow Always)")))
                NSLog("ZackEyes: auto-allowed tool=%@ (Allow Always) sid=%@", toolName, sid)
                return
            }
            let toolInput = event.toolInput?.mapValues { $0.value } ?? [:]
            let pending = PendingPermission(
                id: permissionId ?? UUID(),
                toolName: toolName,
                toolInput: toolInput,
                cwd: event.cwd,
                responder: responder
            )
            NSLog("ZackEyes: PermissionRequest agent=%@ tool=%@",
                  event.agent.rawValue, event.toolName ?? "?")
            EventTrace.shared.note(.prompted)
            sessionStore.handlePermissionRequest(
                sessionId: sid, permission: pending, agent: event.agent
            )
            forceUiExpand()
            maybeNotifyWaiting(event: event, sessionId: sid, kind: .permission)

        case "PreToolUse" where event.toolName == "AskUserQuestion":
            // Path 2: the bridge already fired-and-forgot, so there's no
            // socket responder. CC is showing its native terminal UI right
            // now; the popup is a parallel surface that drives that UI via
            // keystroke injection (see SessionStore.submitAskUQAnswer +
            // KeystrokeInjector). The PostToolUse(AskUQ) branch below
            // closes the popup if the user answered in the terminal first.
            guard let sid = event.sessionId else {
                EventTrace.shared.note(.dropped("no session_id"))
                NSLog("ZackEyes: PreToolUse AskUQ missing session_id")
                return
            }
            let toolInput = event.toolInput?.mapValues { $0.value } ?? [:]
            let pending = PendingPermission(
                toolName: event.toolName ?? "AskUserQuestion",
                toolInput: toolInput,
                cwd: event.cwd,
                responder: { _ in }   // no-op — see comment above
            )
            NSLog("ZackEyes: PreToolUse AskUQ for tool=AskUserQuestion")
            // sessionStore.handleEvent (in the default branch) is what
            // normally captures bridgePpid into claudePid. AskUQ skips the
            // default branch, so apply the same field-stamping inline so
            // KeystrokeInjector knows which terminal to activate.
            EventTrace.shared.note(.prompted)
            sessionStore.handleEvent(event)
            sessionStore.handlePermissionRequest(
                sessionId: sid, permission: pending, agent: event.agent
            )
            forceUiExpand()
            maybeNotifyWaiting(event: event, sessionId: sid, kind: .question)

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
            let priorUserPrompt = event.sessionId.flatMap {
                sessionStore.sessions[$0]?.lastUserPrompt
            }
            let priorPendingIsAskUQ: Bool = event.sessionId.flatMap {
                sessionStore.sessions[$0]?.pendingPermission?.isAskUserQuestion
            } ?? false
            // #181 — PostCompact clears the stored trigger inside handleEvent,
            // so capture it first for the finish-notification gate below.
            let priorCompactTrigger: String? = event.sessionId.flatMap {
                sessionStore.sessions[$0]?.compactTrigger
            }
            // #186 — baseline for the compact-finish inference, captured for
            // the same reason (turn-boundary events clear it in handleEvent).
            let priorCompactBaseline: Double? = event.sessionId.flatMap {
                sessionStore.sessions[$0]?.compactStartContextPct
            }

            sessionStore.handleEvent(event)

            // Whichever event just cleared an AskUQ popup (PostToolUse-after-
            // terminal-answer, UserPromptSubmit-after-reject-by-new-prompt,
            // or Stop-as-backstop), nudge the panel back to compact. The
            // mouse-driven collapse loop only fires on actual cursor
            // movement, so without an explicit nudge the panel sits open
            // with stale "no pending" content until the user moves their
            // mouse. forceUiCompact gates on hasPending, so other waiting
            // sessions still keep it expanded.
            if priorPendingIsAskUQ,
               let sid = event.sessionId,
               sessionStore.sessions[sid]?.pendingPermission == nil {
                forceUiCompact()
            }

            // Compact is the resting state and is always visible —
            // no SessionStart/SessionEnd panel-state transitions needed.
            // (The expanded panel still auto-opens via forceUiExpand on
            // PermissionRequest / error.)

            // Split from one guard into two so the trace can tell the two
            // silent discards apart. `SessionStore.handleEvent` itself
            // returns immediately on a missing session id, so stamping
            // `.applied` before this point would claim work that never
            // happened — exactly the kind of lie this trace exists to stop.
            guard let sid = event.sessionId else {
                EventTrace.shared.note(.dropped("no session_id"))
                return
            }
            guard let session = sessionStore.sessions[sid] else {
                EventTrace.shared.note(.dropped("session not tracked"))
                return
            }
            // State moved. The notification blocks below overwrite this when
            // one of them actually fires.
            EventTrace.shared.note(.applied)

            // Notify if an error was JUST detected on this session
            // Replayed events never notify — the error/finish happened while
            // the app was closed; the panel state is refreshed silently.
            if !event.isReplayed,
               let errLabel = session.errorMessage,
               session.errorAt != priorErrorAt {
                EventTrace.shared.note(.notified("error"))
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

            // Notify on Stop when the session showed signs of work — any
            // ONE of the three independent signals is enough:
            //
            // 1. Lifetime tool calls > 0 — covers sessions that were
            //    running before ZackEyes launched and never fired
            //    UserPromptSubmit (so `priorUserPrompt` is nil).
            // 2. User prompt observed this run — the original signal,
            //    catches chat-only turns once the user has submitted at
            //    least one prompt that we saw.
            // 3. Stop event carries `last_assistant_message` — the agent
            //    actually produced a reply this turn. Strongest "did
            //    something" signal; works even without tools or observed
            //    prompts (covers codex Stop, and pre-launch sessions
            //    finishing their first turn after app start).
            //
            // The previous `didWorkThisTurn = toolCount-after > toolCount-before`
            // check was always false: Stop doesn't change toolCallCount,
            // so both sides of the comparison were the same captured value.
            if !event.isReplayed,
               event.bridgeEvent == "Stop",
               session.errorMessage == nil,    // don't double-notify on errors
               priorState == .working || priorState == .waiting {
                let didAnyTooling = session.toolCallCount > 0
                let hasInteraction = priorUserPrompt != nil
                let hasAssistantReply = (event.lastAssistantMessage?.isEmpty == false)
                if didAnyTooling || hasInteraction || hasAssistantReply {
                    EventTrace.shared.note(.notified("finished"))
                    NotificationManager.shared.notifySessionFinished(
                        sessionId: sid,
                        agent: session.agent,
                        projectName: session.displayName,
                        lastPrompt: session.lastUserPrompt
                    )
                } else {
                    // A deliberate silence that is indistinguishable from an
                    // ordinary applied event unless the trace says so.
                    EventTrace.shared.note(.suppressed("stop: no sign of work"))
                }
            }

            // #181 — manual /compact finishes with PostCompact, not Stop, so
            // the block above never fires for it. Auto-compact stays silent
            // (its turn's Stop notifies later; see CompactFinishGate).
            if !event.isReplayed,
               event.bridgeEvent == "PostCompact",
               CompactFinishGate.shouldNotify(
                   eventTrigger: event.trigger,
                   storedTrigger: priorCompactTrigger),
               compactAlertGatePasses(sessionId: sid) {
                EventTrace.shared.note(.notified("compact"))
                NSLog("ZackEyes: compact finished (PostCompact) sid=%@", String(sid.prefix(8)))
                NotificationManager.shared.notifyCompactFinished(
                    sessionId: sid,
                    agent: session.agent,
                    projectName: session.displayName
                )
            }

            // #186 — interactive CC fires PreCompact but never PostCompact
            // (upstream anthropics/claude-code#78760), so the block above is
            // dead in real TUI usage. Infer completion instead: compaction
            // runs statusLine-silent, and the first StatusLine after it lands
            // <1s post-finish carrying the collapsed context. Restricted to
            // StatusLine so turn-boundary events (which legitimately clear
            // the marker in handleEvent) can never race a chime.
            if !event.isReplayed,
               event.bridgeEvent == "StatusLine",
               CompactFinishGate.inferredFinish(
                   trigger: priorCompactTrigger,
                   baselinePct: priorCompactBaseline,
                   currentPct: session.contextUsedPct),
               compactAlertGatePasses(sessionId: sid) {
                NSLog("ZackEyes: compact finished (inferred %.0f%%→%.0f%%) sid=%@",
                      priorCompactBaseline ?? -1, session.contextUsedPct ?? -1,
                      String(sid.prefix(8)))
                EventTrace.shared.note(.notified("compact, inferred"))
                sessionStore.clearCompactMarker(sessionId: sid)
                NotificationManager.shared.notifyCompactFinished(
                    sessionId: sid,
                    agent: session.agent,
                    projectName: session.displayName
                )
            }
        }
    }

    /// #186 — shared per-session cooldown for the two compact-finished paths.
    /// Passing CONSUMES the slot (stamps the timestamp), so callers must gate
    /// on it last. 60s covers any PostCompact-vs-StatusLine arrival skew while
    /// staying far below realistic back-to-back manual compactions.
    private func compactAlertGatePasses(sessionId: String) -> Bool {
        let activeSessionIds = Set(sessionStore.sessions.keys)
        lastCompactAlertAt = lastCompactAlertAt.filter { activeSessionIds.contains($0.key) }
        let now = Date()
        guard WaitingAlertGate.shouldAlert(
            lastAlertedAt: lastCompactAlertAt[sessionId], now: now, cooldown: 60
        ) else { return false }
        lastCompactAlertAt[sessionId] = now
        return true
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
    /// Say why we are quitting. Without this the second launch looks like
    /// nothing happened at all — the app has no Dock icon to bounce.
    private func presentAlreadyRunningAlert() {
        let alert = NSAlert()
        alert.messageText = "ZackEyes is already running"
        alert.informativeText = "Look for the icon in the menu bar. "
            + "Only one copy can watch your agents at a time."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

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

    /// Chime + system-notify when an agent blocks MID-TASK waiting on the user
    /// (permission / AskUserQuestion). Codex-reviewed #169 gating: never on
    /// replayed events, only when the config toggle is on, and at most once per
    /// per-session cooldown so AskUQ bursts don't spam. Auto-allowed permissions
    /// never reach here — they early-return before the pending is built (see the
    /// `isToolAutoAllowed` / AskUQ-drop branches), so this only fires for prompts
    /// that actually render a waiting surface. `event.agent` keeps it agent-neutral
    /// (no Claude-only liveness assumptions for Codex).
    private func maybeNotifyWaiting(event: BridgeEvent, sessionId: String, kind: WaitingKind) {
        // The trace verdict stays `.prompted` on the replayed path: the entry
        // already carries a `[replayed]` marker, which says the same thing
        // without a second line of explanation.
        guard !event.isReplayed else { return }
        guard ConfigStore().loadNotifyWaitingForInput() else {
            EventTrace.shared.note(.suppressed("waiting alert: setting off"))
            return
        }
        // Bound the cooldown map to live sessions: session IDs are unique and this
        // app runs for days, so without pruning it grows unbounded. The current
        // sessionId always survives (handlePermissionRequest just created it).
        let activeSessionIds = Set(sessionStore.sessions.keys)
        lastWaitingAlertAt = lastWaitingAlertAt.filter { activeSessionIds.contains($0.key) }
        let now = Date()
        guard WaitingAlertGate.shouldAlert(
            lastAlertedAt: lastWaitingAlertAt[sessionId], now: now, cooldown: 12
        ) else {
            EventTrace.shared.note(.suppressed("waiting alert: cooldown"))
            return
        }
        lastWaitingAlertAt[sessionId] = now
        EventTrace.shared.note(.notified("waiting"))
        NotificationManager.shared.notifyWaitingForUser(
            sessionId: sessionId,
            agent: event.agent,
            projectName: sessionStore.sessions[sessionId]?.displayName ?? "session",
            kind: kind
        )
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

        guard event.shouldNotifyUser else { return }

        NotificationManager.shared.notifySessionFinished(
            sessionId: event.sessionId,
            agent: .codex,
            projectName: session.displayName,
            lastPrompt: session.lastUserPrompt
        )
    }

    /// Tailer detected Codex's `turn_context.model`. Codex hooks don't carry
    /// a Claude-style `model.display_name`, so this is our only source.
    func codexTailer(_ tailer: CodexJsonlTailer, didDetectModelChanged event: CodexModelEvent) {
        sessionStore.setCodexModelDisplayName(
            sessionId: event.sessionId,
            cwd: event.cwd,
            transcriptPath: event.transcriptPath,
            displayName: event.modelDisplayName
        )
    }

    /// Tailer detected Codex's `session_meta.source.subagent`. Session-level,
    /// fires once at watcher attach time.
    func codexTailer(_ tailer: CodexJsonlTailer, didDetectSubagent event: CodexSubagentEvent) {
        sessionStore.setCodexSubagentLabel(
            sessionId: event.sessionId,
            cwd: event.cwd,
            transcriptPath: event.transcriptPath,
            label: event.subagentLabel
        )
    }

    /// Tailer detected Codex's per-turn approval/sandbox policy. Map to the
    /// cross-agent risk enum here (off the parser's nonisolated path) and
    /// apply to the session. nil = no badge.
    func codexTailer(_ tailer: CodexJsonlTailer, didDetectPolicyChanged event: CodexPolicyEvent) {
        let risk = PermissionRiskLevel.fromCodex(
            approvalPolicy: event.approvalPolicy,
            sandboxType: event.sandboxType
        )
        sessionStore.setCodexPermissionRisk(
            sessionId: event.sessionId,
            cwd: event.cwd,
            transcriptPath: event.transcriptPath,
            risk: risk
        )
    }

    /// Tailer detected Codex's `event_msg.error` (usage-limit hit / API
    /// failure). Codex hooks never deliver errors, so this jsonl path is the
    /// only way the popup learns about them. Surface to the session's error
    /// banner, fire one notification per fresh error (retry bursts are
    /// deduped in `recordCodexError`), and force the panel open so the user
    /// can't miss it — mirrors the Claude error path's `forceUiExpand`.
    func codexTailer(_ tailer: CodexJsonlTailer, didDetectError event: CodexErrorEvent) {
        let result = sessionStore.recordCodexError(
            sessionId: event.sessionId,
            cwd: event.cwd,
            message: event.message,
            errorInfo: event.errorInfo,
            transcriptPath: event.transcriptPath,
            observedAt: Date()
        )

        guard result.isNew else { return }

        NotificationManager.shared.notifyError(
            sessionId: event.sessionId,
            agent: .codex,
            projectName: result.session.displayName,
            errorLabel: result.session.errorMessage ?? "Codex error",
            detail: event.message
        )
        forceUiExpand()
    }

    /// Tailer detected Codex's `event_msg.token_count` context metrics.
    /// Codex hooks do not carry Claude-style `context_window`, so this path
    /// fills the same SessionInfo fields from rollout JSONL.
    func codexTailer(_ tailer: CodexJsonlTailer, didDetectTokenCount event: CodexTokenCountEvent) {
        sessionStore.recordCodexContext(
            sessionId: event.sessionId,
            cwd: event.cwd,
            contextUsedPct: event.contextUsedPct,
            contextWindowSize: event.contextWindowSize,
            transcriptPath: event.transcriptPath,
            observedAt: Date(),
            cumulativeInput: event.cumulativeInput,
            cumulativeCached: event.cumulativeCached,
            cumulativeOutput: event.cumulativeOutput
        )
        if sessionStore.sessions[event.sessionId]?.claudePid == nil {
            activateCodexSession(event.sessionId)
        }
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
