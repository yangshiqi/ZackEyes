import Foundation
import Shared

/// Per-session state (one per Claude Code session).
public struct SessionInfo: Identifiable {
    public let id: String
    public var cwd: String?
    public var state: SessionState
    public var currentToolName: String?
    public var pendingPermission: PendingPermission?
    public var startedAt: Date
    public var lastActiveAt: Date
    public var toolCallCount: Int

    public init(
        id: String,
        cwd: String?,
        state: SessionState = .working,
        startedAt: Date = Date()
    ) {
        self.id = id
        self.cwd = cwd
        self.state = state
        self.currentToolName = nil
        self.pendingPermission = nil
        self.startedAt = startedAt
        self.lastActiveAt = startedAt
        self.toolCallCount = 0
    }
}

@MainActor
public final class SessionStore: ObservableObject {
    /// All active sessions, keyed by session_id.
    @Published public var sessions: [String: SessionInfo] = [:]

    public init() {}

    // MARK: - Computed views

    /// The "primary" session shown in the UI. Priority:
    /// 1. Session with pending permission
    /// 2. Most recently active working/waiting session
    /// 3. Most recently active session overall
    public var primarySession: SessionInfo? {
        if let pending = sessions.values.first(where: { $0.pendingPermission != nil }) {
            return pending
        }
        let active = sessions.values.filter { $0.state == .working || $0.state == .waiting }
        if let mostRecent = active.max(by: { $0.lastActiveAt < $1.lastActiveAt }) {
            return mostRecent
        }
        return sessions.values.max(by: { $0.lastActiveAt < $1.lastActiveAt })
    }

    /// Aggregated state for menu bar icon.
    public var aggregateState: SessionState {
        if sessions.values.contains(where: { $0.pendingPermission != nil }) {
            return .waiting
        }
        if sessions.values.contains(where: { $0.state == .working }) {
            return .working
        }
        return .idle
    }

    /// All sessions sorted by most recent activity (for list display).
    public var orderedSessions: [SessionInfo] {
        sessions.values.sorted { $0.lastActiveAt > $1.lastActiveAt }
    }

    // MARK: - Event handling

    public func handleEvent(_ event: BridgeEvent) {
        guard let sid = event.sessionId else { return }

        switch event.bridgeEvent {
        case "SessionStart":
            sessions[sid] = SessionInfo(id: sid, cwd: event.cwd)

        case "SessionEnd":
            sessions.removeValue(forKey: sid)

        case "PreToolUse":
            var session = sessions[sid] ?? SessionInfo(id: sid, cwd: event.cwd)
            session.currentToolName = event.toolName
            session.toolCallCount += 1
            session.lastActiveAt = Date()
            if session.state == .idle { session.state = .working }
            sessions[sid] = session

        case "PostToolUse":
            var session = sessions[sid] ?? SessionInfo(id: sid, cwd: event.cwd)
            session.currentToolName = nil
            session.lastActiveAt = Date()
            sessions[sid] = session

        case "Stop":
            // Stop = Claude finished current turn, session still active.
            var session = sessions[sid] ?? SessionInfo(id: sid, cwd: event.cwd)
            session.state = .idle
            session.currentToolName = nil
            session.lastActiveAt = Date()
            sessions[sid] = session

        default:
            break
        }
    }

    public func handlePermissionRequest(sessionId: String, permission: PendingPermission) {
        var session = sessions[sessionId] ?? SessionInfo(id: sessionId, cwd: permission.cwd)
        session.state = .waiting
        session.pendingPermission = permission
        session.lastActiveAt = Date()
        sessions[sessionId] = session
    }

    public func resolvePermission(sessionId: String, allow: Bool) {
        guard var session = sessions[sessionId], let pending = session.pendingPermission else { return }
        let response: PermissionResponse = allow
            ? .allow(message: "User approved via ZackEyes")
            : .deny(message: "User denied via ZackEyes")
        pending.responder(response)
        session.pendingPermission = nil
        session.state = .working
        session.lastActiveAt = Date()
        sessions[sessionId] = session
    }

    /// Resolve the primary pending permission (convenience for single-session UI).
    public func resolvePrimaryPermission(allow: Bool) {
        guard let primary = primarySession, primary.pendingPermission != nil else { return }
        resolvePermission(sessionId: primary.id, allow: allow)
    }

    /// Called when the bridge disconnects without the user responding via ZackEyes
    /// (e.g., user answered in terminal, or bridge timed out). Clear the pending state.
    public func abandonPermission(sessionId: String) {
        guard var session = sessions[sessionId], session.pendingPermission != nil else { return }
        session.pendingPermission = nil
        session.state = .working  // back to normal
        session.lastActiveAt = Date()
        sessions[sessionId] = session
    }
}

public struct PendingPermission {
    public let toolName: String
    public let toolInput: [String: Any]
    public let cwd: String?
    public let responder: @Sendable (PermissionResponse) -> Void

    public init(
        toolName: String,
        toolInput: [String: Any],
        cwd: String?,
        responder: @escaping @Sendable (PermissionResponse) -> Void
    ) {
        self.toolName = toolName
        self.toolInput = toolInput
        self.cwd = cwd
        self.responder = responder
    }
}
