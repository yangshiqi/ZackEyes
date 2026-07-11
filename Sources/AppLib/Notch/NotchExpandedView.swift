import SwiftUI

struct NotchExpandedView: View {
    @ObservedObject var viewModel: NotchViewModel
    @State private var pulseOpacity: Double = 1.0
    @State private var tick: Date = Date()
    @State private var recentExpanded = false
    /// #43 — session ids whose resting-card recap is expanded to full text.
    @State private var expandedRecaps: Set<String> = []

    private let durationTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    // Read theme once per body evaluation (1/second via durationTimer)
    // instead of per-session inside sessionCardContent.
    private var currentTheme: BuddyTheme { ConfigStore().loadTheme() }

    var body: some View {
        let theme = currentTheme
        let sections = SessionListPresentation.sections(
            from: viewModel.sessionStore.orderedSessions
        )
        VStack(alignment: .leading, spacing: 12) {
            if viewModel.sessionStore.sessions.isEmpty {
                emptyState
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(sections) { section in
                        VStack(alignment: .leading, spacing: 8) {
                            sectionHeader(section)
                            if section.group != .recent || recentExpanded {
                                ForEach(section.sessions, id: \.id) { session in
                                    sessionCard(session, theme: theme)
                                }
                            }
                        }
                    }
                }

            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .onReceive(durationTimer) { now in
            tick = now
        }
    }

    @ViewBuilder
    private func sectionHeader(_ section: SessionListSection) -> some View {
        if section.group == .recent {
            Button {
                withAnimation(.easeOut(duration: 0.18)) {
                    recentExpanded.toggle()
                }
            } label: {
                sectionHeaderContent(section, collapsible: true)
            }
            .buttonStyle(.plain)
        } else {
            sectionHeaderContent(section, collapsible: false)
        }
    }

    private func sectionHeaderContent(
        _ section: SessionListSection,
        collapsible: Bool
    ) -> some View {
        HStack(spacing: 6) {
            Text(section.group.title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(section.group == .needsYou
                    ? AppColors.attention.color
                    : .white.opacity(0.55))
            Text("\(section.sessions.count)")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.35))
            Spacer(minLength: 0)
            if collapsible {
                Image(systemName: recentExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.white.opacity(0.4))
            }
        }
        .contentShape(Rectangle())
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 24))
                .foregroundColor(.gray.opacity(0.5))
            Text("No active sessions")
                .font(.system(size: 11))
                .foregroundColor(.gray)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }

    // MARK: - Session card

    @ViewBuilder
    private func sessionCard(_ session: SessionInfo, theme: BuddyTheme) -> some View {
        // .onTapGesture on the content (not a wrapping Button) so the inner
        // Deny / Allow Once buttons inside sessionCardContent aren't nested
        // inside another Button — nested buttons make the outer action fire
        // when a child button is clicked, which would jump the terminal on
        // every Allow/Deny click.
        sessionCardContent(session, theme: theme)
            .contentShape(Rectangle())
            .onTapGesture {
                viewModel.activateTerminal(for: session)
            }
    }

    @ViewBuilder
    private func sessionCardContent(_ session: SessionInfo, theme: BuddyTheme) -> some View {
        let buddy = Buddy.from(sessionId: session.id, theme: theme)

        // Defer the sleeping animation for 30s after the last activity so a
        // freshly-finished session doesn't snap straight into Zzz. Re-evaluated
        // every tick (the durationTimer fires once per second).
        let isAtRest = (session.state == .idle || session.state == .stopped)
            && session.pendingPermission == nil
        let recentlyActive = isAtRest && tick.timeIntervalSince(session.lastActiveAt) < 30

        // F1 theme: derive team color from the buddy name ("Max from Red Bull" → Red Bull blue)
        let teamColor = theme == .f1 ? PixelAvatar.teamColor(forBuddyName: buddy.name) : nil

        HStack(alignment: .top, spacing: 10) {
            // Animated buddy avatar
            BuddyAvatar(
                seed: session.id,
                state: session.state,
                isWaiting: session.pendingPermission != nil,
                recentlyActive: recentlyActive,
                theme: currentTheme,
                teamColor: teamColor,
                size: 32
            )

            VStack(alignment: .leading, spacing: 6) {
                // Project identity leads; agent/risk/time remain scan metadata.
                HStack(spacing: 6) {
                    Text(session.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer(minLength: 4)

                    AgentBadge(agent: session.agent, subagentLabel: session.subagentLabel)

                    if let risk = session.permissionRisk {
                        PermissionBadge(risk: risk)
                    }

                    Text(elapsedString(since: session.lastActiveAt))
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.5))
                }

                // Row 1.5: session context — user prompt (identifies the session)
                // Falls back to reading the Bridge's title cache, then buddy tagline.
                Text(truncate(
                    session.lastUserPrompt
                        ?? Self.readCachedPrompt(sessionId: session.id)
                        ?? buddy.tagline,
                    length: 50
                ))
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(.white.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(buddy.name)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.white.opacity(0.4))
                    .lineLimit(1)
                    .truncationMode(.tail)

                // Row 1.6: context window usage bar (per-session, from statusLine)
                if let used = session.contextUsedPct {
                    contextBar(usedPct: used,
                               windowSize: session.contextWindowSize,
                               cost: session.totalCostUSD,
                               model: session.modelDisplayName)
                }

                // (User prompt now shown in Row 1.5 above)

                // Row 3: agent's last reply (live) / completion recap (resting).
                if let reply = session.lastAssistantMessage, !reply.isEmpty {
                    if isResting(session) {
                        recapBlock(session, reply: reply)
                    } else {
                        HStack(alignment: .top, spacing: 4) {
                            Text(session.agent == .codex ? "Codex:" : "Claude:")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(AppColors.activity.color.opacity(0.8))
                            Text(truncate(reply, length: 100))
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.75))
                                .lineLimit(2)
                                .truncationMode(.tail)
                        }
                    }
                }

                // Row 4: current/last tool action with running indicator
                if let tool = session.currentToolName {
                    HStack(spacing: 6) {
                        if session.isToolRunning {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .scaleEffect(0.4)
                                .frame(width: 10, height: 10)
                        } else {
                            Image(systemName: "checkmark")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(.white.opacity(0.4))
                        }
                        Text(tool)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(session.isToolRunning
                                ? AppColors.activity.color
                                : .white.opacity(0.55))
                        if let input = toolInputShortPreview(session.currentToolInput) {
                            Text(input)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.white.opacity(0.6))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }

                // Error banner (rate limit / API error)
                if let errMsg = session.errorMessage {
                    errorBanner(errMsg, detail: session.lastAssistantMessage)
                }

                // Tasks section — hidden once the session goes idle/stopped
                // (and there's no pending permission to act on). At that
                // point the task list is just stale clutter; the context
                // progress bar above is enough to convey "this session
                // exists, it's resting".
                if !session.tasks.isEmpty && !isResting(session) {
                    taskList(session.tasks)
                }

                // Permission request details + approval buttons (regular PermissionRequest only).
                // AskUserQuestion renders its own block with a terminal CTA footer.
                if let pending = session.pendingPermission {
                    if pending.isAskUserQuestion {
                        askUserQuestionBlock(session: session, pending: pending)
                    } else {
                        permissionDetailBlock(pending)
                        permissionApprovalButtons(
                            sessionId: session.id,
                            isPrimary: viewModel.primarySession?.id == session.id
                        )
                        .padding(.top, 4)
                    }
                }

            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(session.pendingPermission != nil ? 0.06 : 0.03))
        )
        .onAppear {
            if session.pendingPermission != nil {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    pulseOpacity = 0.3
                }
            }
        }
    }

    @ViewBuilder
    private func contextBar(usedPct: Double, windowSize: Int?, cost: Double?, model: String?) -> some View {
        let color = contextColor(for: usedPct)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text("Context")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.white.opacity(0.55))
                Text(String(format: "%.0f%%", usedPct))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(color)
                if let size = windowSize {
                    Text(formatWindowSize(size))
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.4))
                }
                if let model = model {
                    Text(model)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if let cost = cost, cost > 0 {
                    Text(String(format: "$%.2f", cost))
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.5))
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.white.opacity(0.08))
                        .frame(height: 3)
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(color)
                        .frame(width: geo.size.width * CGFloat(min(usedPct, 100)) / 100, height: 3)
                }
            }
            .frame(height: 3)
        }
    }

    private func contextColor(for usedPct: Double) -> Color {
        switch usedPct {
        case ..<60: return AppColors.activity.color
        case ..<85: return AppColors.attention.color
        default:    return AppColors.critical.color
        }
    }

    private func formatWindowSize(_ size: Int) -> String {
        if size >= 1_000_000 { return String(format: "%.0fM", Double(size) / 1_000_000) }
        if size >= 1_000 { return String(format: "%.0fk", Double(size) / 1_000) }
        return "\(size)"
    }

    @ViewBuilder
    private func errorBanner(_ label: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(AppColors.critical.color)
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(AppColors.critical.color)
                Spacer(minLength: 0)
            }
            if let detail = detail, !detail.isEmpty {
                Text(truncate(detail, length: 140))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.8))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(AppColors.critical.color.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(AppColors.critical.color.opacity(0.4), lineWidth: 1)
                )
        )
    }

    @ViewBuilder
    private func taskList(_ tasks: [TaskItem]) -> some View {
        let doneTasks = tasks.filter { $0.isDone }
        let inProgressTasks = tasks.filter { $0.isInProgress }
        let openTasks = tasks.filter { !$0.isDone && !$0.isInProgress }

        // Display policy: focus on current work.
        // - Show all in_progress and open tasks
        // - Show only 1 most recent done (just enough to show what just finished)
        // - If everything is done: show 2 most recent
        let hasActive = !inProgressTasks.isEmpty || !openTasks.isEmpty
        let doneLimit = hasActive ? 1 : 2
        let recentDone = Array(doneTasks.suffix(doneLimit))
        let hiddenDoneCount = doneTasks.count - recentDone.count

        VStack(alignment: .leading, spacing: 6) {
            // Header — "Tasks (1 done, 1 in progress, 0 open)"
            HStack(spacing: 6) {
                Text("Tasks")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)
                Text("(\(doneTasks.count) done, \(inProgressTasks.count) in progress, \(openTasks.count) open)")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.5))
                Spacer(minLength: 0)
            }
            .padding(.top, 6)

            // Order: in_progress → open → recent done → "+ N more done"
            ForEach(inProgressTasks) { task in taskRow(task) }
            ForEach(openTasks) { task in taskRow(task) }
            ForEach(recentDone) { task in taskRow(task) }

            if hiddenDoneCount > 0 {
                Text("+ \(hiddenDoneCount) more done")
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.35))
                    .padding(.leading, 16)
            }
        }
    }

    @ViewBuilder
    private func taskRow(_ task: TaskItem) -> some View {
        HStack(alignment: .center, spacing: 6) {
            taskIcon(task)
            Text(task.subject)
                .font(.system(size: 10, weight: task.isInProgress ? .semibold : .regular))
                .foregroundColor(taskTextColor(task))
                .strikethrough(task.isDone, color: .gray.opacity(0.6))
                .lineLimit(2)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 1)
    }

    @ViewBuilder
    private func taskIcon(_ task: TaskItem) -> some View {
        if task.isDone {
            Image(systemName: "checkmark.square.fill")
                .font(.system(size: 10))
                .foregroundColor(AppColors.activity.color.opacity(0.6))
        } else if task.isInProgress {
            // Animated pulsing dot for in-progress
            Circle()
                .fill(AppColors.activity.color)
                .frame(width: 8, height: 8)
                .shadow(color: AppColors.activity.color.opacity(0.6), radius: 3)
                .overlay(
                    Circle()
                        .stroke(AppColors.activity.color.opacity(0.4), lineWidth: 1)
                        .scaleEffect(pulseOpacity * 1.5 + 1.0)
                )
        } else {
            Image(systemName: "square")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.45))
        }
    }

    private func taskTextColor(_ task: TaskItem) -> Color {
        if task.isDone {
            return .white.opacity(0.4)
        }
        if task.isInProgress {
            return .white
        }
        return .white.opacity(0.75)
    }

    @ViewBuilder
    private func askUserQuestionBlock(session: SessionInfo, pending: PendingPermission) -> some View {
        // Notice-only surface: shows the question text so the user knows
        // what's being asked, plus a CTA hint to answer in the terminal.
        // The wrapping session card already has an .onTapGesture that
        // activates the terminal tab, so no additional gesture is needed
        // here. We dropped the in-popup option list + KeystrokeInjector
        // path because driving CC's terminal UI by injecting keystrokes
        // turned out to be brittle across multi-tab Ghostty layouts and
        // accumulated four distinct bug surfaces; "answer in terminal"
        // is the simple, robust path.
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 11))
                    .foregroundColor(AppColors.activity.color)
                Text("Claude's Question")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(AppColors.activity.color)
            }

            ForEach(Array(pending.questions.enumerated()), id: \.offset) { _, question in
                HStack(alignment: .top, spacing: 4) {
                    if let header = question.header {
                        Text("[\(header)]")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(AppColors.activity.color)
                    }
                    Text(question.text)
                        .font(.system(size: 11))
                        .foregroundColor(.white)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // A real Button (not the card's bubbled .onTapGesture): the card
            // is wrapped in a ScrollView (NotchCompactView / SimulatedNotchFullView),
            // where a container-level .onTapGesture competes with scroll
            // recognition and often never fires — so the CTA "did nothing".
            // Button hit-testing is coordinated with ScrollView (same reason
            // Deny/Allow work reliably here), so this guarantees the tap.
            Button(action: { viewModel.activateTerminal(for: session) }) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.right.square.fill")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Click to answer in terminal")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 0)
                }
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(AppColors.activity.color.opacity(0.45))
                )
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .padding(.top, 6)
        .padding(.leading, 16)
    }

    @ViewBuilder
    private func permissionDetailBlock(_ pending: PendingPermission) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("PERMISSION REQUEST")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(AppColors.attention.color)
                .kerning(0.5)

            Text(pending.toolName)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(AppColors.attention.color)

            if let preview = toolInputFullPreview(pending) {
                Text(preview)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.8))
                    .lineLimit(3)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.05))
                    .cornerRadius(6)
            }
        }
        .padding(.top, 6)
        .padding(.leading, 16)
    }

    // MARK: - Approval buttons (rendered inside the owning session's card)

    @ViewBuilder
    private func permissionApprovalButtons(sessionId: String, isPrimary: Bool) -> some View {
        let toolName = viewModel.sessionStore.sessions[sessionId]?.pendingPermission?.toolName
        let highRisk = toolName.map(SessionStore.isHighRisk) ?? false
        HStack(spacing: 8) {
            denyButton(sessionId: sessionId, isPrimary: isPrimary)
            allowButton(sessionId: sessionId, isPrimary: isPrimary)
            // High-risk tools (e.g. Bash) don't offer "Allow Always" — a single
            // approval would auto-run every future invocation this session (#128).
            if !highRisk {
                allowAlwaysButton(sessionId: sessionId, isPrimary: isPrimary)
            }
        }
    }

    @ViewBuilder
    private func denyButton(sessionId: String, isPrimary: Bool) -> some View {
        let base = Button(action: { viewModel.deny(sessionId: sessionId) }) {
            HStack(spacing: 4) {
                Text("Deny")
                if isPrimary {
                    Text("⌘N")
                        .font(.system(size: 8, weight: .regular, design: .monospaced))
                        .opacity(0.6)
                }
            }
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(AppColors.critical.color)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(AppColors.critical.color.opacity(0.15))
                .cornerRadius(8)
        }
        .buttonStyle(.plain)

        if isPrimary {
            base.keyboardShortcut("n", modifiers: .command)
        } else {
            base
        }
    }

    @ViewBuilder
    private func allowButton(sessionId: String, isPrimary: Bool) -> some View {
        let base = Button(action: { viewModel.approve(sessionId: sessionId) }) {
            HStack(spacing: 4) {
                Text("Allow Once")
                if isPrimary {
                    Text("⌘Y")
                        .font(.system(size: 8, weight: .regular, design: .monospaced))
                        .opacity(0.6)
                }
            }
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(AppColors.activity.color)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(AppColors.activity.color.opacity(0.15))
                .cornerRadius(8)
        }
        .buttonStyle(.plain)

        if isPrimary {
            base.keyboardShortcut("y", modifiers: .command)
        } else {
            base
        }
    }

    @ViewBuilder
    private func allowAlwaysButton(sessionId: String, isPrimary: Bool) -> some View {
        let activity = AppColors.activity.color
        let base = Button(action: { viewModel.approveAlways(sessionId: sessionId) }) {
            HStack(spacing: 4) {
                // #87 — "Allow Always" (not "Allow All"): auto-allow is per-tool,
                // not all-tools. Pairs with "Allow Once" as the temporal contrast.
                Text("Allow Always")
                if isPrimary {
                    Text("⇧⌘Y")
                        .font(.system(size: 8, weight: .regular, design: .monospaced))
                        .opacity(0.7)
                }
            }
                // Filled (vs Allow Once's translucent fill) to signal the broader,
                // for-the-rest-of-this-session scope (still just this one tool).
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(activity)
                .cornerRadius(8)
        }
        .buttonStyle(.plain)
        .help("Auto-allow this tool for the rest of this session")

        if isPrimary {
            base.keyboardShortcut("y", modifiers: [.command, .shift])
        } else {
            base
        }
    }

    // MARK: - Helpers

    /// Mirrors `BuddyAvatar.isIdle`: a session is "resting" when it's idle
    /// or stopped AND there's nothing waiting on the user. Used to hide
    /// stale UI like the completed task list.
    private func isResting(_ session: SessionInfo) -> Bool {
        (session.state == .idle || session.state == .stopped) && session.pendingPermission == nil
    }

    /// #43 — completion recap shown on resting (idle/stopped) cards: the agent's
    /// last reply (2 lines, tap the card to expand to full text) plus a terse
    /// metadata line. Missing pieces degrade silently (detected/scanned sessions
    /// have only the reply text). Stale text is already prevented upstream —
    /// SessionStore clears `lastAssistantMessage` on each new user prompt.
    @ViewBuilder
    private func recapBlock(_ session: SessionInfo, reply: String) -> some View {
        let expanded = expandedRecaps.contains(session.id)
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top, spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundColor(AppColors.activity.color.opacity(0.8))
                Text(expanded ? reply : truncate(reply, length: 100))
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.75))
                    .lineLimit(expanded ? nil : 2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let meta = recapMetadata(session) {
                Text(meta)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.white.opacity(0.45))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if expanded { expandedRecaps.remove(session.id) }
            else { expandedRecaps.insert(session.id) }
        }
    }

    /// Terse recap metadata: `N tools · 12m · $0.42`. Each piece is included only
    /// when the data exists, so detected sessions (no tool count / cost) just
    /// show fewer parts — or nothing, in which case the subline is hidden.
    /// Error reason is intentionally omitted: the error banner below already
    /// surfaces it on resting cards.
    private func recapMetadata(_ session: SessionInfo) -> String? {
        var parts: [String] = []
        if session.toolCallCount > 0 {
            parts.append("\(session.toolCallCount) tool\(session.toolCallCount == 1 ? "" : "s")")
        }
        let dur = session.lastActiveAt.timeIntervalSince(session.startedAt)
        if dur >= 60 { parts.append(durationString(dur)) }
        if let cost = session.totalCostUSD, cost > 0 {
            parts.append(String(format: "$%.2f", cost))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func durationString(_ seconds: TimeInterval) -> String {
        let m = Int(seconds) / 60
        if m < 60 { return "\(m)m" }
        return "\(m / 60)h \(m % 60)m"
    }

    private func statusColor(for session: SessionInfo) -> Color {
        if session.pendingPermission != nil {
            return AppColors.attention.color
        }
        switch session.state {
        case .working: return AppColors.activity.color
        case .waiting: return AppColors.attention.color
        case .idle, .stopped: return .gray
        }
    }

    private func toolInputShortPreview(_ input: [String: Any]?) -> String? {
        guard let input = input else { return nil }
        if let filePath = input["file_path"] as? String {
            return (filePath as NSString).lastPathComponent
        }
        if let command = input["command"] as? String {
            return command
        }
        if let path = input["path"] as? String {
            return (path as NSString).lastPathComponent
        }
        return nil
    }

    private func toolInputFullPreview(_ pending: PendingPermission) -> String? {
        if let command = pending.toolInput["command"] as? String {
            return command
        }
        if let filePath = pending.toolInput["file_path"] as? String {
            return filePath
        }
        return nil
    }

    private func elapsedString(since date: Date) -> String {
        let seconds = Int(tick.timeIntervalSince(date))
        if seconds < 60 {
            return "<1m"
        } else if seconds < 3600 {
            return "\(seconds / 60)m"
        } else {
            return "\(seconds / 3600)h"
        }
    }

    private func truncate(_ str: String, length: Int) -> String {
        if str.count <= length {
            return str
        }
        return String(str.prefix(length)) + "..."
    }

    /// Read the first-prompt cache written by Bridge's TerminalTitleWriter.
    /// Returns nil if the file doesn't exist or can't be read.
    private static func readCachedPrompt(sessionId: String) -> String? {
        let prefix = String(sessionId.prefix(16))
        let path = (NSHomeDirectory() as NSString)
            .appendingPathComponent(".zackeyes/osc2-titles/\(prefix)")
        guard let text = try? String(contentsOfFile: path, encoding: .utf8),
              !text.isEmpty else { return nil }
        return text
    }
}
