import SwiftUI

struct NotchExpandedView: View {
    @ObservedObject var viewModel: NotchViewModel
    @State private var pulseOpacity: Double = 1.0
    @State private var tick: Date = Date()

    private let durationTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if viewModel.sessionStore.sessions.isEmpty {
                emptyState
            } else {
                // List all sessions (most recent first)
                VStack(spacing: 10) {
                    ForEach(viewModel.sessionStore.orderedSessions, id: \.id) { session in
                        sessionCard(session)
                    }
                }

                // If primary session has a regular permission request (not AskUserQuestion),
                // show approval buttons at bottom
                if let primary = viewModel.primarySession,
                   let pending = primary.pendingPermission,
                   !pending.isAskUserQuestion {
                    permissionApprovalButtons
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
    private func sessionCard(_ session: SessionInfo) -> some View {
        Button(action: {
            viewModel.activateTerminal(for: session)
        }) {
            sessionCardContent(session)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func sessionCardContent(_ session: SessionInfo) -> some View {
        let buddy = Buddy.from(sessionId: session.id)

        HStack(alignment: .top, spacing: 10) {
            // Animated buddy avatar
            BuddyAvatar(
                seed: session.id,
                state: session.state,
                isWaiting: session.pendingPermission != nil,
                size: 32
            )

            VStack(alignment: .leading, spacing: 6) {
                // Row 1: buddy name + project name + badges + elapsed
                HStack(spacing: 6) {
                    Text(buddy.name)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                    Text("·")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.4))
                    Text(session.displayName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.8))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 4)

                    Text(elapsedString(since: session.lastActiveAt))
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.5))
                }

                // Row 1.5: tagline (personality)
                Text(buddy.tagline)
                    .font(.system(size: 9, weight: .regular, design: .rounded))
                    .foregroundColor(.white.opacity(0.5))
                    .italic()

                // Row 1.6: context window usage bar (per-session, from statusLine)
                if let used = session.contextUsedPct {
                    contextBar(usedPct: used,
                               windowSize: session.contextWindowSize,
                               cost: session.totalCostUSD)
                }

                // Row 2: last user prompt (You: ...)
                if let prompt = session.lastUserPrompt, !prompt.isEmpty {
                    HStack(alignment: .top, spacing: 4) {
                        Text("You:")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.white.opacity(0.6))
                        Text(truncate(prompt, length: 100))
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.75))
                            .lineLimit(2)
                            .truncationMode(.tail)
                    }
                }

                // Row 3: Claude's last reply (Claude: ...)
                if let reply = session.lastAssistantMessage, !reply.isEmpty {
                    HStack(alignment: .top, spacing: 4) {
                        Text("Claude:")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(Color(red: 0.31, green: 0.80, blue: 0.77).opacity(0.8))
                        Text(truncate(reply, length: 100))
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.75))
                            .lineLimit(2)
                            .truncationMode(.tail)
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
                                ? Color(red: 0.31, green: 0.80, blue: 0.77)
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

                // Tasks section
                if !session.tasks.isEmpty {
                    taskList(session.tasks)
                }

                // Permission request details
                if let pending = session.pendingPermission {
                    if pending.isAskUserQuestion {
                        askUserQuestionBlock(session: session, pending: pending)
                    } else {
                        permissionDetailBlock(pending)
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
    private func contextBar(usedPct: Double, windowSize: Int?, cost: Double?) -> some View {
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
        case ..<60: return Color(red: 0.31, green: 0.80, blue: 0.77)  // teal
        case ..<85: return Color(red: 0.96, green: 0.65, blue: 0.14)  // orange
        default:    return Color(red: 0.95, green: 0.30, blue: 0.30)  // red
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
                    .foregroundColor(.red)
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.red)
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
                .fill(Color.red.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.red.opacity(0.4), lineWidth: 1)
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
                .foregroundColor(Color(red: 0.31, green: 0.80, blue: 0.77).opacity(0.6))
        } else if task.isInProgress {
            // Animated pulsing dot for in-progress
            Circle()
                .fill(Color(red: 0.31, green: 0.80, blue: 0.77))
                .frame(width: 8, height: 8)
                .shadow(color: Color(red: 0.31, green: 0.80, blue: 0.77).opacity(0.6), radius: 3)
                .overlay(
                    Circle()
                        .stroke(Color(red: 0.31, green: 0.80, blue: 0.77).opacity(0.4), lineWidth: 1)
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
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 11))
                    .foregroundColor(Color(red: 0.31, green: 0.80, blue: 0.77))
                Text("Claude's Question")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(red: 0.31, green: 0.80, blue: 0.77))
            }

            ForEach(Array(pending.questions.enumerated()), id: \.offset) { _, question in
                VStack(alignment: .leading, spacing: 8) {
                    // Question text with optional header
                    HStack(alignment: .top, spacing: 4) {
                        if let header = question.header {
                            Text("[\(header)]")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(Color(red: 0.31, green: 0.80, blue: 0.77))
                        }
                        Text(question.text)
                            .font(.system(size: 11))
                            .foregroundColor(.white)
                            .lineLimit(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // Options as numbered cards
                    VStack(spacing: 6) {
                        ForEach(Array(question.options.enumerated()), id: \.element.id) { index, option in
                            Button(action: {
                                viewModel.answerQuestion(sessionId: session.id, selection: option.label)
                            }) {
                                HStack(alignment: .top, spacing: 10) {
                                    Text("\(index + 1)")
                                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                                        .foregroundColor(Color(red: 0.31, green: 0.80, blue: 0.77))
                                        .frame(width: 20, height: 20)
                                        .background(
                                            RoundedRectangle(cornerRadius: 4)
                                                .fill(Color(red: 0.31, green: 0.80, blue: 0.77).opacity(0.15))
                                        )

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(option.label)
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundColor(.white)
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                        if let desc = option.description {
                                            Text(desc)
                                                .font(.system(size: 10))
                                                .foregroundColor(.white.opacity(0.6))
                                                .lineLimit(2)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 9))
                                        .foregroundColor(.white.opacity(0.3))
                                }
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(Color.white.opacity(0.05))
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(.top, 6)
        .padding(.leading, 16)
    }

    @ViewBuilder
    private func permissionDetailBlock(_ pending: PendingPermission) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("PERMISSION REQUEST")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(Color(red: 0.96, green: 0.65, blue: 0.14))
                .kerning(0.5)

            Text(pending.toolName)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Color(red: 0.96, green: 0.65, blue: 0.14))

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

    // MARK: - Approval buttons (shared across all pending permissions)

    private var permissionApprovalButtons: some View {
        HStack(spacing: 8) {
            Button(action: { viewModel.deny() }) {
                Text("Deny")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.red.opacity(0.15))
                    .cornerRadius(8)
            }
            .buttonStyle(.plain)

            Button(action: { viewModel.approve() }) {
                Text("Allow Once")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color(red: 0.31, green: 0.80, blue: 0.77))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color(red: 0.31, green: 0.80, blue: 0.77).opacity(0.15))
                    .cornerRadius(8)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Helpers

    private func statusColor(for session: SessionInfo) -> Color {
        if session.pendingPermission != nil {
            return Color(red: 0.96, green: 0.65, blue: 0.14)
        }
        switch session.state {
        case .working: return Color(red: 0.31, green: 0.80, blue: 0.77)
        case .waiting: return Color(red: 0.96, green: 0.65, blue: 0.14)
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
}
