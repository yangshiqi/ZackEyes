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
            if let pid = session.claudePid {
                _ = TerminalLocator.activateTerminal(containingPid: pid)
            }
        }) {
            sessionCardContent(session)
        }
        .buttonStyle(.plain)
        .disabled(session.claudePid == nil)
    }

    @ViewBuilder
    private func sessionCardContent(_ session: SessionInfo) -> some View {
        HStack(alignment: .top, spacing: 10) {
            // Avatar
            PixelAvatar(seed: session.id, size: 28)
                .opacity(session.source == .detected ? 0.4 : 1.0)

            VStack(alignment: .leading, spacing: 6) {
                // Row 1: display name + badges + elapsed
                HStack(spacing: 6) {
                    Text(session.displayName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 4)

                    if session.source == .live && session.state == .working {
                        // Active indicator
                        Circle()
                            .fill(statusColor(for: session))
                            .frame(width: 6, height: 6)
                            .shadow(color: statusColor(for: session).opacity(0.6), radius: 2)
                    }

                    Text("Claude")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.1))
                        .cornerRadius(4)

                    Text(elapsedString(since: session.lastActiveAt))
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.5))
                }

                // Row 2: last user prompt (You: ...)
                if let prompt = session.lastUserPrompt, !prompt.isEmpty {
                    HStack(alignment: .top, spacing: 4) {
                        Text("You:")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.white.opacity(0.6))
                        Text(truncate(prompt, length: 80))
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.75))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }

                // Row 3: current tool action (like "Edit Sources/...")
                if let tool = session.currentToolName {
                    HStack(spacing: 6) {
                        Text(tool)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(Color(red: 0.31, green: 0.80, blue: 0.77))
                        if let input = toolInputShortPreview(session.currentToolInput) {
                            Text(input)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.white.opacity(0.6))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
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

                // Detected (read-only) hint
                if session.source == .detected {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 9))
                        Text("Restart session for live tracking")
                            .font(.system(size: 10))
                    }
                    .foregroundColor(Color(red: 0.96, green: 0.65, blue: 0.14))
                    .padding(.top, 2)
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
    private func taskList(_ tasks: [TaskItem]) -> some View {
        let done = tasks.filter { $0.isDone }.count
        let inProgress = tasks.filter { $0.isInProgress }.count
        let open = tasks.count - done - inProgress

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text("Tasks")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(0.8))
                Text("(\(done) done, \(inProgress) in progress, \(open) open)")
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.5))
            }
            .padding(.top, 4)

            ForEach(tasks.prefix(5)) { task in
                HStack(spacing: 6) {
                    Image(systemName: task.isDone ? "checkmark.square.fill" : (task.isInProgress ? "arrow.triangle.2.circlepath" : "square"))
                        .font(.system(size: 10))
                        .foregroundColor(task.isDone ? .gray : (task.isInProgress ? Color(red: 0.31, green: 0.80, blue: 0.77) : .white.opacity(0.6)))
                    Text(task.subject)
                        .font(.system(size: 10))
                        .foregroundColor(task.isDone ? .gray : .white.opacity(0.75))
                        .strikethrough(task.isDone, color: .gray)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            if tasks.count > 5 {
                Text("+ \(tasks.count - 5) more")
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.4))
                    .padding(.leading, 16)
            }
        }
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
        if session.source == .detected {
            return .gray.opacity(0.5)
        }
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
