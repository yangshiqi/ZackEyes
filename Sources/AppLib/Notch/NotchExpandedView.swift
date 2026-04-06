import SwiftUI

struct NotchExpandedView: View {
    @ObservedObject var viewModel: NotchViewModel
    @State private var pulseOpacity: Double = 1.0
    @State private var tick: Date = Date()

    private let durationTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(spacing: 8) {
                Circle()
                    .fill(viewModel.statusColor)
                    .frame(width: 8, height: 8)
                    .shadow(color: viewModel.statusColor, radius: 3)
                    .opacity(viewModel.aggregateState == .waiting ? pulseOpacity : 1.0)
                    .onAppear {
                        withAnimation(
                            .easeInOut(duration: 0.9)
                            .repeatForever(autoreverses: true)
                        ) {
                            pulseOpacity = 0.3
                        }
                    }

                Text("Claude Code")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)

                Spacer()

                Text(viewModel.statusText)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(viewModel.statusColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(viewModel.statusColor.opacity(0.15))
                    .clipShape(Capsule())
            }

            if viewModel.sessionStore.sessions.isEmpty {
                Text("No active sessions")
                    .font(.system(size: 11))
                    .foregroundColor(.gray)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            } else if let primary = viewModel.primarySession {
                // Primary session detail
                primarySessionView(primary)

                // Other sessions list (if multiple)
                let others = viewModel.sessionStore.orderedSessions.filter { $0.id != primary.id }
                if !others.isEmpty {
                    Divider().background(Color.white.opacity(0.1))
                    Text("OTHER SESSIONS")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.gray)
                        .kerning(0.5)
                    VStack(spacing: 4) {
                        ForEach(others, id: \.id) { session in
                            otherSessionRow(session)
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
    }

    @ViewBuilder
    private func primarySessionView(_ session: SessionInfo) -> some View {
        // CWD
        if let cwd = session.cwd {
            Text(cwd)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.gray)
                .lineLimit(1)
                .truncationMode(.middle)
        }

        // Session stats
        HStack(spacing: 12) {
            let endTime = (session.state == .working || session.state == .waiting)
                ? tick
                : session.lastActiveAt
            Label(durationString(from: session.startedAt, to: endTime), systemImage: "clock")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.6))
                .labelStyle(.titleAndIcon)

            Label("\(session.toolCallCount) tools", systemImage: "wrench.adjustable")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.6))
                .labelStyle(.titleAndIcon)

            if let tool = session.currentToolName {
                Text(tool)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.8))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.08))
                    .cornerRadius(4)
            }
        }
        .onReceive(durationTimer) { now in
            if session.state == .working || session.state == .waiting {
                tick = now
            }
        }

        // Permission request section
        if let pending = session.pendingPermission {
            Divider().background(Color.white.opacity(0.1))

            VStack(alignment: .leading, spacing: 8) {
                Text("PERMISSION REQUEST")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.gray)
                    .kerning(0.5)

                Text(pending.toolName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color(red: 0.96, green: 0.65, blue: 0.14))

                if let preview = toolInputPreview(pending) {
                    Text(preview)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.white.opacity(0.8))
                        .lineLimit(3)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.white.opacity(0.05))
                        .cornerRadius(6)
                }

                HStack(spacing: 8) {
                    Button(action: { viewModel.deny() }) {
                        Text("Deny")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.red)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(Color.red.opacity(0.15))
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)

                    Button(action: { viewModel.approve() }) {
                        Text("Allow Once")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Color(red: 0.31, green: 0.80, blue: 0.77))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(Color(red: 0.31, green: 0.80, blue: 0.77).opacity(0.15))
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private func otherSessionRow(_ session: SessionInfo) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor(for: session))
                .frame(width: 6, height: 6)
            Text(session.cwd.map { ($0 as NSString).lastPathComponent } ?? String(session.id.prefix(8)))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.white.opacity(0.7))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text("\(session.toolCallCount) tools")
                .font(.system(size: 9))
                .foregroundColor(.white.opacity(0.5))
        }
    }

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

    private func toolInputPreview(_ pending: PendingPermission) -> String? {
        if let command = pending.toolInput["command"] as? String {
            return command
        }
        if let filePath = pending.toolInput["file_path"] as? String {
            return filePath
        }
        return nil
    }

    private func durationString(from start: Date, to now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(start))
        if seconds < 60 {
            return "\(seconds)s"
        } else if seconds < 3600 {
            return "\(seconds / 60)m \(seconds % 60)s"
        } else {
            return "\(seconds / 3600)h \(seconds / 60 % 60)m"
        }
    }
}
