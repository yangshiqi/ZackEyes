import SwiftUI
import AppKit
import Shared

/// Full-content view shown when the simulated notch is morphed into the
/// expanded panel. Layout:
///   - Top: 5h + 7d usage progress bars
///   - Below: scrollable session list
struct SimulatedNotchFullView: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject var usageTracker: UsageTracker
    @ObservedObject var modeStore: NotchModeStore
    @ObservedObject var updateChecker: UpdateChecker
    @ObservedObject var downloader: UpdateDownloader
    var cornerRadius: CGFloat = 22

    /// Weak handle to the actual NSView backing the gear button. Set by
    /// `HostViewProbe` when SwiftUI mounts the gear. We use it to find
    /// the panel's NSWindow + the gear's bounds for menu anchoring,
    /// which is multi-monitor safe (no screen coordinate conversion).
    @State private var gearHost = HostViewBox()

    var body: some View {
        if viewModel.welcomeVisible {
            // First-launch welcome: overlay replaces usage header + session
            // list. Simulated-notch surface wraps with NotchShape so the
            // welcome shares the silhouette of the dynamic-island pill.
            WelcomeOverlay()
                .background(NotchShape(cornerRadius: cornerRadius).fill(Color.black))
                .clipShape(NotchShape(cornerRadius: cornerRadius))
        } else {
            normalBody
        }
    }

    private var normalBody: some View {
        VStack(spacing: 0) {
            usageHeader
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)

            Divider()
                .background(Color.white.opacity(0.08))

            ScrollView(.vertical, showsIndicators: false) {
                NotchExpandedView(viewModel: viewModel)
                    .background(Color.clear)
            }
        }
        .background(NotchShape(cornerRadius: cornerRadius).fill(Color.black))
        .clipShape(NotchShape(cornerRadius: cornerRadius))
        .overlay(aboutOverlay)
        .overlay(hotkeyRecorderOverlay)
    }

    /// About card overlay — semi-transparent backdrop + centered card
    /// with app icon, name, version, and OK button. Shown when
    /// `modeStore.isAboutShown == true`.
    @ViewBuilder
    private var aboutOverlay: some View {
        if modeStore.isAboutShown {
            ZStack {
                // Backdrop — tap to dismiss.
                Color.black.opacity(0.6)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        modeStore.isAboutShown = false
                    }

                // Card — opaque, centered, fixed 280×200.
                VStack(spacing: 14) {
                    aboutIcon
                        .frame(width: 64, height: 64)

                    Text("ZackEyes")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)

                    Text("Version \(appVersion)")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.6))

                    Button(action: { modeStore.isAboutShown = false }) {
                        Text("OK")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Color(red: 0.31, green: 0.80, blue: 0.77))
                            .padding(.horizontal, 24)
                            .padding(.vertical, 6)
                            .background(Color(red: 0.31, green: 0.80, blue: 0.77).opacity(0.15))
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.defaultAction)
                }
                .padding(20)
                .frame(width: 280, height: 200)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(white: 0.12))
                )
                .contentShape(Rectangle())
                .onTapGesture { /* no-op: prevent backdrop dismiss when tapping card */ }
            }
            .transition(.opacity)
        }
    }

    /// Hotkey recorder overlay — captures a new global shortcut.
    @ViewBuilder
    private var hotkeyRecorderOverlay: some View {
        if modeStore.isHotkeyRecorderShown {
            HotkeyRecorderView(
                currentConfig: ConfigStore().load(),
                onSave: { newConfig in
                    ConfigStore().save(newConfig)
                    NotificationCenter.default.post(
                        name: .hotkeyConfigChanged,
                        object: nil,
                        userInfo: ["config": newConfig]
                    )
                    modeStore.isHotkeyRecorderShown = false
                },
                onCancel: {
                    modeStore.isHotkeyRecorderShown = false
                }
            )
            .transition(.opacity)
        }
    }

    /// Icon for the About card. Tries to load the bundle's AppIcon image;
    /// falls back to a SF Symbol if it isn't found.
    @ViewBuilder
    private var aboutIcon: some View {
        if let nsImage = NSImage(named: "AppIcon") {
            Image(nsImage: nsImage)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 12))
        } else {
            Image(systemName: "sparkles")
                .font(.system(size: 36))
                .foregroundColor(.white.opacity(0.7))
        }
    }

    /// Version string from Info.plist's CFBundleShortVersionString.
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    // MARK: - Usage header

    private var usageHeader: some View {
        let snap = usageTracker.snapshot
        let codexOnly = snap.hasCodexData && !snap.hasClaudeData
        let bothActive = snap.hasClaudeData && snap.hasCodexData

        return VStack(spacing: 4) {
            if bothActive {
                splitUsageRow(
                    label: "5h",
                    leftPct: snap.fiveHourUsedPct,
                    leftResetsAt: snap.fiveHourResetsAt,
                    rightPct: snap.codexFiveHourUsedPct,
                    rightResetsAt: snap.codexFiveHourResetsAt,
                    leftETA: snap.fiveHourETA,
                    rightETA: snap.codexFiveHourETA,
                    rightLimitReached: snap.codexLimitReached,
                    rightLimitResetsAt: snap.codexLimitResetsAt,
                    trailing: { gearMenu }
                )
                // 7d does NOT inherit the account-level block flag — an
                // out-of-credits / 5h-window block shouldn't paint the 7d row
                // "limit" too (its weekly budget isn't exhausted). While blocked
                // it shows the real weekly usage as "N% used" (not the misleading
                // "100%" remaining), so the 5h row stays the single headline
                // indicator. 7d only shows "limit" if its OWN used% hits 100.
                splitUsageRow(
                    label: "7d",
                    leftPct: snap.sevenDayUsedPct,
                    leftResetsAt: snap.sevenDayResetsAt,
                    rightPct: snap.codexSevenDayUsedPct,
                    rightResetsAt: snap.codexSevenDayResetsAt,
                    rightUsedLabel: snap.codexLimitReached
                )
            } else {
                // Single-agent path. Claude shows when only Claude (or
                // neither) reports data — preserves existing behavior for
                // Claude-only users and the empty / first-launch state.
                let useCodex = codexOnly
                let codexLimit = useCodex && snap.codexLimitReached
                usageBar(
                    label: "5h",
                    agent: useCodex ? .codex : .claude,
                    usedPct: useCodex ? snap.codexFiveHourUsedPct : snap.fiveHourUsedPct,
                    resetsAt: useCodex ? snap.codexFiveHourResetsAt : snap.fiveHourResetsAt,
                    eta: useCodex ? snap.codexFiveHourETA : snap.fiveHourETA,
                    limitReached: codexLimit,
                    limitResetsAt: useCodex ? snap.codexLimitResetsAt : nil,
                    trailing: { gearMenu }
                )
                // 7d shows its own usage — only the 5h row carries the
                // account-level block flag (see the split path above). While
                // codex is blocked, 7d shows "N% used" so its low weekly window
                // doesn't read as a misleading "100% remaining".
                usageBar(
                    label: "7d",
                    agent: useCodex ? .codex : .claude,
                    usedPct: useCodex ? snap.codexSevenDayUsedPct : snap.sevenDayUsedPct,
                    resetsAt: useCodex ? snap.codexSevenDayResetsAt : snap.sevenDayResetsAt,
                    usedLabel: codexLimit
                )
            }
            if usageTracker.showTodayConsumption, snap.hasConsumption {
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(height: 1)
                    .padding(.top, 2)
                TodayConsumptionRow(days: snap.dailyUsage)
            }
            // #45 — usage freshness footnote (stale numbers shouldn't read as live).
            // #166 review (Gemini): in the split header both agents show, so the one
            // shared footnote must reflect the STALEST data on screen (the oldest of
            // the two per-agent timestamps), not just Claude's. Single-agent uses its
            // own timestamp.
            let freshness: Date? = bothActive
                ? [snap.lastUpdated, snap.codexLastUpdated].compactMap { $0 }.min()
                : (codexOnly ? snap.codexLastUpdated : snap.lastUpdated)
            if snap.hasRealData, let lastUpdated = freshness {
                UsageFreshnessLabel(lastUpdated: lastUpdated)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    /// Side-by-side bar: left half = Claude, right half = Codex. Both 5h
    /// and 7d rows share the same outer column layout
    /// (label / left-half / right-half / gear-or-placeholder) so the two
    /// progress tracks line up horizontally regardless of which row
    /// carries the gear menu.
    @ViewBuilder
    private func splitUsageRow<Trailing: View>(
        label: String,
        leftPct: Double?, leftResetsAt: Date?,
        rightPct: Double?, rightResetsAt: Date?,
        leftETA: CapETA? = nil, rightETA: CapETA? = nil,
        rightLimitReached: Bool = false, rightLimitResetsAt: Date? = nil,
        rightUsedLabel: Bool = false,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.7))
                .frame(width: 22, alignment: .leading)

            HStack(spacing: 8) {
                splitHalf(agent: .claude, usedPct: leftPct, resetsAt: leftResetsAt, eta: leftETA)
                splitHalf(agent: .codex,  usedPct: rightPct, resetsAt: rightResetsAt, eta: rightETA,
                          limitReached: rightLimitReached, limitResetsAt: rightLimitResetsAt,
                          usedLabel: rightUsedLabel)
            }

            // Trailing column: always reserves the same width so both
            // 5h and 7d rows have identical bar tracks underneath.
            ZStack { trailing() }
                .frame(width: gearColumnWidth, height: gearColumnWidth, alignment: .center)
        }
    }

    /// Width reserved for the gear-menu column on every split row.
    private var gearColumnWidth: CGFloat { 22 }

    /// One agent's half of a split row: header (letter + remaining % +
    /// reset countdown) sitting tightly above its progress bar.
    @ViewBuilder
    private func splitHalf(agent: AgentKind, usedPct: Double?, resetsAt: Date?,
                           eta: CapETA? = nil,
                           limitReached: Bool = false, limitResetsAt: Date? = nil,
                           usedLabel: Bool = false) -> some View {
        let cell = UsageCellState.make(usedPct: usedPct, limitReached: limitReached)
        let used = usedPct ?? 0
        let color = cell.isExhausted ? Color.usageLimitRed : barColor(for: used)
        let hasData = usedPct != nil || limitReached
        let accent = AgentBadge.accentColor(for: agent)
        // Exhausted: prefer the BLOCK's reset (the binding window codex is
        // actually limited on) over this cell's own window reset — a 5h headline
        // blocked by the 7d window should count down to the 7d reset, not 5h
        // (CodeRabbit PR review). Falls back to the cell reset when no block
        // reset is known.
        let resetDisplay = (cell.isExhausted ? (limitResetsAt ?? resetsAt) : resetsAt)?.usageResetDisplay

        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(agent == .claude ? "C" : "X")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(accent)
                if cell.isExhausted {
                    Text("limit")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Color.usageLimitRed)
                } else if hasData {
                    // `usedLabel` shows "N% used" (unambiguous) instead of the
                    // remaining %. Used on the codex 7d cell while the account
                    // is blocked, so the still-low weekly window doesn't read as
                    // a misleading "100%" next to the 5h "limit".
                    Text(usedLabel
                        ? String(format: "%d%% used", Int(used.rounded()))
                        : String(format: "%d%%", cell.remainingPct))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(color)
                } else {
                    Text("—")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.35))
                }
                // #86/#108 — the ETA badge sits next to the percentage so the
                // trailing slot stays free for the reset countdown. Both matter at
                // once: ETA = when you run dry, reset = when budget comes back, and
                // ETA < reset is exactly the case to show side by side. Mirrors the
                // full-width usageBar layout. CapETABadge self-guards a nil eta
                // (renders nothing), so no outer `if` is needed — matches usageBar.
                // Suppress when exhausted: "runs dry" is meaningless once blocked.
                if !cell.isExhausted { CapETABadge(eta: eta, compact: true) }
                Spacer(minLength: 0)
                if let reset = resetDisplay {
                    Text(reset)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.white.opacity(0.4))
                }
            }
            // Progress track. Pin the height with `.frame(height: 5)` AT
            // the GeometryReader level so the parent HStack can't grow
            // vertically — without it, GeometryReader is flexible and the
            // row balloons to whatever height the layout has available.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(Color.white.opacity(0.10))
                    if hasData {
                        RoundedRectangle(cornerRadius: 2.5)
                            .fill(color)
                            .frame(width: geo.size.width * CGFloat(cell.fillFraction))
                    }
                }
            }
            .frame(height: 5)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Settings gear — plain SwiftUI Button that pops a native NSMenu
    /// positioned just below the gear's screen frame. We bypass SwiftUI
    /// `Menu` entirely because in a `nonactivatingPanel` with a black
    /// background, the custom Image label renders with a window-chrome
    /// tint that's effectively invisible (verified — a Color.red bg
    /// makes the gear instantly show up). NSMenu via `popUp(positioning:
    /// at:in:)` sidesteps the rendering problem AND lets us anchor the
    /// menu to the gear's screen rect instead of the cursor location
    /// (which on the menubar gets visually covered by status items).
    private var gearMenu: some View {
        Button {
            modeStore.markMenuOpen()
            popGearMenu()
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.85))
                .frame(width: 22, height: 22)
                .overlay(alignment: .topTrailing) {
                    // Red dot persists across all downloader states (idle / downloading / failed)
                    // until the user upgrades — failed downloads must remain visible so the user
                    // doesn't lose the affordance to retry.
                    if updateChecker.availableVersion != nil {
                        Circle()
                            .fill(.red)
                            .frame(width: 6, height: 6)
                            .offset(x: 2, y: -2)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(HostViewProbe(box: gearHost))
    }

    /// Build and show an NSMenu anchored just below the gear button.
    /// Uses the gear's NSView + parent NSWindow directly so coordinates
    /// stay window-local — no screen conversion, multi-monitor safe.
    private func popGearMenu() {
        let menu = NSMenu()

        if let version = updateChecker.availableVersion {
            let (title, enabled) = StatusBarMenu.updateMenuLabel(
                version: version,
                state: downloader.state
            )
            let update = NSMenuItem(
                title: title,
                action: enabled ? #selector(GearMenuTarget.updateClicked(_:)) : nil,
                keyEquivalent: ""
            )
            update.target = enabled ? GearMenuTarget.shared : nil
            update.isEnabled = enabled
            menu.addItem(update)
            menu.addItem(.separator())
        }

        let about = NSMenuItem(
            title: "About",
            action: #selector(GearMenuTarget.aboutClicked(_:)),
            keyEquivalent: ""
        )
        about.target = GearMenuTarget.shared
        menu.addItem(about)

        let hotkey = NSMenuItem(
            title: "Change Hotkey…",
            action: #selector(GearMenuTarget.hotkeyClicked(_:)),
            keyEquivalent: ""
        )
        hotkey.target = GearMenuTarget.shared
        menu.addItem(hotkey)

        let visibilityMenu = NSMenu()
        let currentVisibility = ConfigStore().loadNotchVisibility()
        let visibilityOptions: [(String, NotchVisibility)] = [
            ("Always", .always),
            ("Only When Sessions Active", .whenActive),
            ("Hidden", .hidden),
        ]
        for (title, value) in visibilityOptions {
            let item = NSMenuItem(
                title: title,
                action: #selector(GearMenuTarget.visibilityOptionClicked(_:)),
                keyEquivalent: ""
            )
            item.target = GearMenuTarget.shared
            item.representedObject = value.rawValue
            item.state = (value == currentVisibility) ? .on : .off
            visibilityMenu.addItem(item)
        }
        let visibilityItem = NSMenuItem(title: "Dynamic Island", action: nil, keyEquivalent: "")
        visibilityItem.submenu = visibilityMenu
        menu.addItem(visibilityItem)

        // "Move Notch" groups the two position actions in one dimension:
        // enter drag-reposition mode, or jump straight back to center.
        let moveMenu = NSMenu()
        // Manage enablement ourselves so "Reset to Center" can stay disabled
        // when already centered (autoenable would re-enable it by default).
        moveMenu.autoenablesItems = false
        let reposition = NSMenuItem(
            title: "Reposition…",
            action: #selector(GearMenuTarget.moveNotchClicked(_:)),
            keyEquivalent: ""
        )
        reposition.target = GearMenuTarget.shared
        moveMenu.addItem(reposition)

        let resetPosition = NSMenuItem(
            title: "Reset to Center",
            action: #selector(GearMenuTarget.resetPositionClicked(_:)),
            keyEquivalent: ""
        )
        resetPosition.target = GearMenuTarget.shared
        // Only actionable when the notch has actually been moved.
        resetPosition.isEnabled = ConfigStore().loadNotchOffsetX() != 0
        moveMenu.addItem(resetPosition)

        let moveItem = NSMenuItem(title: "Move Notch", action: nil, keyEquivalent: "")
        moveItem.submenu = moveMenu
        menu.addItem(moveItem)

        let themeMenu = NSMenu()
        let config = ConfigStore()
        let currentTheme = config.loadTheme()
        let currentSound = config.loadNotificationSound() ?? currentTheme.defaultSoundFile
        for theme in BuddyTheme.allCases {
            let item = NSMenuItem(
                title: theme.displayName,
                action: #selector(GearMenuTarget.themeClicked(_:)),
                keyEquivalent: ""
            )
            item.target = GearMenuTarget.shared
            item.representedObject = theme.rawValue
            item.state = (theme == currentTheme) ? .on : .off
            themeMenu.addItem(item)
        }
        // Sound options for the current theme
        let sounds = currentTheme.availableSounds
        if !sounds.isEmpty {
            themeMenu.addItem(.separator())
            for sound in sounds {
                let item = NSMenuItem(
                    title: sound.name,
                    action: #selector(GearMenuTarget.soundClicked(_:)),
                    keyEquivalent: ""
                )
                item.target = GearMenuTarget.shared
                item.representedObject = sound.file
                item.state = (sound.file == currentSound) ? .on : .off
                themeMenu.addItem(item)
            }
        }
        let themeItem = NSMenuItem(title: "Theme", action: nil, keyEquivalent: "")
        themeItem.submenu = themeMenu
        menu.addItem(themeItem)

        // Compact display: which agent's 5h/7d shows in the collapsed pill.
        // The full panel always shows both agents when both have data; this
        // only steers the narrow always-visible pill.
        let compactMenu = NSMenu()
        let currentCompactAgent = config.loadCompactAgent()
        for agent in [AgentKind.claude, .codex] {
            let item = NSMenuItem(
                title: agent == .claude ? "Claude" : "Codex",
                action: #selector(GearMenuTarget.compactAgentClicked(_:)),
                keyEquivalent: ""
            )
            item.target = GearMenuTarget.shared
            item.representedObject = agent.rawValue
            item.state = (agent == currentCompactAgent) ? .on : .off
            compactMenu.addItem(item)
        }
        let compactItem = NSMenuItem(title: "Compact display", action: nil, keyEquivalent: "")
        compactItem.submenu = compactMenu
        menu.addItem(compactItem)

        let todayConsumption = NSMenuItem(
            title: "Show today's consumption",
            action: #selector(GearMenuTarget.toggleTodayConsumptionClicked(_:)),
            keyEquivalent: ""
        )
        todayConsumption.target = GearMenuTarget.shared
        todayConsumption.state = usageTracker.showTodayConsumption ? .on : .off
        menu.addItem(todayConsumption)

        let waitingNotify = NSMenuItem(
            title: "Sound when waiting for input",
            action: #selector(GearMenuTarget.toggleNotifyWaitingClicked(_:)),
            keyEquivalent: ""
        )
        waitingNotify.target = GearMenuTarget.shared
        waitingNotify.state = ConfigStore().loadNotifyWaitingForInput() ? .on : .off
        menu.addItem(waitingNotify)

        // Low-frequency maintenance actions sink to the bottom (macOS
        // convention: diagnostics/destructive near Quit, fenced by
        // separators) so daily toggles stay at eye level.
        menu.addItem(.separator())

        let hookStatus = NSMenuItem(
            title: "Hook Status…",
            action: #selector(GearMenuTarget.hookStatusClicked(_:)),
            keyEquivalent: ""
        )
        hookStatus.target = GearMenuTarget.shared
        menu.addItem(hookStatus)

        let uninstall = NSMenuItem(
            title: "Uninstall Integrations…",
            action: #selector(GearMenuTarget.uninstallClicked(_:)),
            keyEquivalent: ""
        )
        uninstall.target = GearMenuTarget.shared
        menu.addItem(uninstall)

        let checkUpdates = NSMenuItem(
            title: "Check for Updates",
            action: #selector(GearMenuTarget.checkUpdatesClicked(_:)),
            keyEquivalent: ""
        )
        checkUpdates.target = GearMenuTarget.shared
        menu.addItem(checkUpdates)

        let diagnostics = NSMenuItem(
            title: "Export Diagnostics…",
            action: #selector(GearMenuTarget.exportDiagnosticsClicked(_:)),
            keyEquivalent: ""
        )
        diagnostics.target = GearMenuTarget.shared
        menu.addItem(diagnostics)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit ZackEyes",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quit.target = NSApp
        menu.addItem(quit)

        GearMenuTarget.shared.downloader = downloader
        GearMenuTarget.shared.dmgURL = updateChecker.dmgURL
        GearMenuTarget.shared.releaseURL = updateChecker.releaseURL
        GearMenuTarget.shared.updateChecker = updateChecker
        GearMenuTarget.shared.modeStore = modeStore
        GearMenuTarget.shared.usageTracker = usageTracker

        // Anchor in window coordinates, relative to the gear's NSView.
        // popUp(positioning:at:in:) interprets `at` in the coordinate
        // space of `in:` — passing the gear view itself means we don't
        // need to know which screen / window we're on.
        if let view = gearHost.view {
            let bounds = view.bounds
            // Below the gear, left edge aligned. NSView default coords
            // are flipped on macOS only if isFlipped — for SwiftUI's
            // hosting view, AppKit origin is bottom-left, so "below"
            // means y = bounds.minY - small gap.
            let anchor = NSPoint(x: bounds.minX, y: bounds.minY - 2)
            menu.popUp(positioning: nil, at: anchor, in: view)
        } else {
            // Fallback: pop at mouse location.
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }

    @ViewBuilder
    private func usageBar<Trailing: View>(
        label: String,
        agent: AgentKind = .claude,
        usedPct: Double?,
        resetsAt: Date?,
        eta: CapETA? = nil,
        limitReached: Bool = false,
        limitResetsAt: Date? = nil,
        usedLabel: Bool = false,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) -> some View {
        let cell = UsageCellState.make(usedPct: usedPct, limitReached: limitReached)
        let used = usedPct ?? 0
        let color = cell.isExhausted ? Color.usageLimitRed : barColor(for: used)
        let hasData = usedPct != nil || limitReached
        let accent = AgentBadge.accentColor(for: agent)
        let resetDisplay = (cell.isExhausted ? (limitResetsAt ?? resetsAt) : resetsAt)?.usageResetDisplay

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.7))
                    .frame(width: 22, alignment: .leading)

                // Agent tag — small label so the user knows which agent's
                // quota this bar represents when only one is active.
                Text(agent == .claude ? "Claude" : "Codex")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(accent)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(accent.opacity(0.15))
                    .clipShape(Capsule())

                if cell.isExhausted {
                    Text("limit reached")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Color.usageLimitRed)
                } else if hasData {
                    Text(usedLabel
                        ? String(format: "%d%% used", Int(used.rounded()))
                        : String(format: "%d%% remaining", cell.remainingPct))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(color)
                } else {
                    Text("no data")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.4))
                }

                if !cell.isExhausted { CapETABadge(eta: eta) }   // #86 — cap ETA badge (5h only)

                Spacer(minLength: 0)

                if let reset = resetDisplay {
                    Text("resets in \(reset)")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.45))
                }

                trailing()
            }

            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.white.opacity(0.10))
                        .frame(height: 6)
                    if hasData {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(color)
                            .frame(width: geo.size.width * CGFloat(cell.fillFraction), height: 6)
                    }
                }
            }
            .frame(height: 6)
        }
    }

    // MARK: - Helpers

    private func barColor(for used: Double) -> Color {
        .usageLevelColor(usedPct: used)
    }

}

public extension Notification.Name {
    static let hotkeyConfigChanged = Notification.Name("hotkeyConfigChanged")
    static let compactAgentChanged = Notification.Name("compactAgentChanged")
    static let notchVisibilityChanged = Notification.Name("notchVisibilityChanged")
    static let notchMoveModeRequested = Notification.Name("notchMoveModeRequested")
    static let notchResetPositionRequested = Notification.Name("notchResetPositionRequested")
}
