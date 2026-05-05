import Foundation
import SwiftUI
import Combine
import Shared

@MainActor
public final class NotchViewModel: ObservableObject {
    public let sessionStore: SessionStore
    @Published public var panelState: PanelState = .compact
    /// Drives the first-launch welcome overlay rendered by `NotchRootView`
    /// and `SimulatedNotchFullView`. Toggled by `AppDelegate.maybeShowWelcome()`.
    @Published public var welcomeVisible: Bool = false
    private var cancellable: AnyCancellable?

    public init(sessionStore: SessionStore) {
        self.sessionStore = sessionStore
        // Forward SessionStore changes to trigger SwiftUI re-renders.
        // Nested ObservableObjects don't propagate automatically.
        cancellable = sessionStore.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    public var aggregateState: SessionState {
        sessionStore.aggregateState
    }

    public var primarySession: SessionInfo? {
        sessionStore.primarySession
    }

    public var statusColor: Color {
        switch aggregateState {
        case .idle, .stopped: return .gray
        case .working: return Color(red: 0.31, green: 0.80, blue: 0.77) // #4ecdc4
        case .waiting: return Color(red: 0.96, green: 0.65, blue: 0.14) // #f5a623
        }
    }

    public var statusText: String {
        let count = sessionStore.sessions.count
        switch aggregateState {
        case .idle, .stopped:
            return count == 0 ? "no sessions" : (count == 1 ? "idle" : "\(count) idle")
        case .working:
            let working = sessionStore.sessions.values.filter { $0.state == .working }.count
            return working > 1 ? "\(working) working" : "working"
        case .waiting:
            let waiting = sessionStore.sessions.values.filter { $0.pendingPermission != nil }.count
            return waiting > 1 ? "\(waiting) awaiting" : "awaiting approval"
        }
    }

    public func approve(sessionId: String) {
        sessionStore.resolvePermission(sessionId: sessionId, allow: true)
    }

    public func deny(sessionId: String) {
        sessionStore.resolvePermission(sessionId: sessionId, allow: false)
    }

    public func submitAskUQAnswer(sessionId: String, answers: [String: String]) {
        sessionStore.submitAskUQAnswer(sessionId: sessionId, answers: answers)
    }

    /// Click handler: jump to the terminal tab for this session.
    /// Runs on a background task so subprocess + AppleScript calls don't block the UI.
    public func activateTerminal(for session: SessionInfo) {
        let cachedPid = session.claudePid
        let transcriptPath = session.transcriptPath
        let cwd = session.cwd
        let sessionId = session.id
        let agent = session.agent
        let prompt = session.lastUserPrompt

        let isDetected = session.source == .detected
        Task.detached(priority: .userInitiated) { [weak self] in
            var pid = cachedPid

            if pid == nil && (!isDetected || agent == .codex) {
                // Detected Claude sessions skip slow discovery; detected
                // Codex sessions are jsonl-backed and can often be found by
                // rollout lsof or codex cwd matching.
                pid = TerminalLocator.findAgentPid(
                    agent: agent,
                    transcriptPath: transcriptPath,
                    cwd: cwd
                )
                if let found = pid {
                    await MainActor.run { [weak self] in
                        if var cached = self?.sessionStore.sessions[sessionId] {
                            cached.claudePid = found
                            self?.sessionStore.sessions[sessionId] = cached
                        }
                    }
                }
            }

            if let pid = pid {
                if agent == .codex, let cwd {
                    _ = TerminalLocator.writeSessionTitle(
                        containingPid: pid,
                        cwd: cwd,
                        sessionId: sessionId,
                        prompt: prompt
                    )
                }
                _ = TerminalLocator.activateTerminal(
                    containingPid: pid,
                    cwd: cwd,
                    sessionId: sessionId
                )
            } else {
                // No PID (detected session, or live session PID not found).
                // Jump directly via terminal AX/cwd matching.
                TerminalLocator.activateTerminalDirectly(
                    sessionId: sessionId, cwd: cwd
                )
            }
        }
    }
}
