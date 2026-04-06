import Foundation
import Shared

/// Per-session state (one per Claude Code session).
public struct TaskItem: Identifiable, Sendable {
    public let id: String
    public var subject: String
    public var status: String  // "pending" | "in_progress" | "completed" | "deleted"

    public var isDone: Bool { status == "completed" || status == "deleted" }
    public var isInProgress: Bool { status == "in_progress" }
}

public struct SessionInfo: Identifiable {
    public let id: String
    public var cwd: String?
    public var state: SessionState
    public var currentToolName: String?
    public var currentToolInput: [String: Any]?
    public var lastUserPrompt: String?
    public var pendingPermission: PendingPermission?
    public var startedAt: Date
    public var lastActiveAt: Date
    public var toolCallCount: Int
    public var source: SessionSource = .live
    public var tasks: [TaskItem] = []
    public var claudePid: Int?   // PID of the claude process (from bridge ppid)
    public var transcriptPath: String?  // Path to the JSONL transcript file (for lsof lookup)

    /// Display name — last path component of cwd, or first 8 chars of id
    public var displayName: String {
        if let cwd = cwd, !cwd.isEmpty {
            return (cwd as NSString).lastPathComponent
        }
        return String(id.prefix(8))
    }

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
        self.currentToolInput = nil
        self.lastUserPrompt = nil
        self.pendingPermission = nil
        self.startedAt = startedAt
        self.lastActiveAt = startedAt
        self.toolCallCount = 0
    }
}

public enum SessionSource: Sendable {
    case live        // tracked via hooks (real-time)
    case detected    // discovered by scanning ~/.claude/projects/ (read-only)
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

        // Any live hook event upgrades a detected session to live
        if let existing = sessions[sid], existing.source == .detected {
            upgradeToLive(sessionId: sid)
        }

        // Capture claude pid + transcript path from bridge if available
        if var existing = sessions[sid] {
            if let ppid = event.bridgePpid, existing.claudePid == nil {
                existing.claudePid = ppid
            }
            if let tp = event.transcriptPath, existing.transcriptPath == nil {
                existing.transcriptPath = tp
            }
            sessions[sid] = existing
        }

        switch event.bridgeEvent {
        case "SessionStart":
            var newSession = SessionInfo(id: sid, cwd: event.cwd)
            newSession.claudePid = event.bridgePpid
            sessions[sid] = newSession

        case "SessionEnd":
            sessions.removeValue(forKey: sid)

        case "PreToolUse":
            var session = sessions[sid] ?? SessionInfo(id: sid, cwd: event.cwd)
            session.currentToolName = event.toolName
            session.currentToolInput = event.toolInput?.mapValues { $0.value }
            session.toolCallCount += 1
            session.lastActiveAt = Date()
            if session.state == .idle { session.state = .working }

            // Intercept Task tool calls to track tasks
            if let toolName = event.toolName,
               let input = event.toolInput?.mapValues({ $0.value }) {
                updateTasks(on: &session, toolName: toolName, input: input)
            }

            sessions[sid] = session

        case "UserPromptSubmit":
            var session = sessions[sid] ?? SessionInfo(id: sid, cwd: event.cwd)
            if let prompt = event.userPrompt {
                session.lastUserPrompt = prompt
            }
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

    /// Answer an AskUserQuestion with the user's selected option labels.
    public func resolveQuestion(sessionId: String, selections: [String]) {
        guard var session = sessions[sessionId], let pending = session.pendingPermission else { return }
        let response = PermissionResponse.answer(selections: selections)
        pending.responder(response)
        session.pendingPermission = nil
        session.state = .working
        session.lastActiveAt = Date()
        sessions[sessionId] = session
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

    /// Import sessions discovered by SessionScanner. These are read-only and
    /// marked as `.detected` — user needs to restart them for live tracking.
    public func importDetectedSessions(_ detected: [SessionScanner.DetectedSession]) {
        for d in detected {
            // Don't overwrite live sessions if we already have them
            if sessions[d.id]?.source == .live { continue }

            var session = SessionInfo(id: d.id, cwd: d.cwd, state: .idle, startedAt: d.lastModified)
            session.lastActiveAt = d.lastModified
            session.lastUserPrompt = d.lastUserPrompt
            session.transcriptPath = d.transcriptPath
            session.source = .detected
            sessions[d.id] = session
        }
    }

    /// Upgrade a detected session to live when we receive our first hook event for it.
    public func upgradeToLive(sessionId: String) {
        guard var session = sessions[sessionId], session.source == .detected else { return }
        session.source = .live
        sessions[sessionId] = session
    }

    /// Update the task list based on TaskCreate / TaskUpdate tool calls.
    /// Claude Code's Task tool uses these as tool names in PreToolUse events.
    private func updateTasks(on session: inout SessionInfo, toolName: String, input: [String: Any]) {
        switch toolName {
        case "TaskCreate":
            // input: { subject, description, activeForm? }
            guard let subject = input["subject"] as? String else { return }
            // Generate a synthetic id since we don't have the real one until TaskList/TaskGet
            let newId = "pending-\(UUID().uuidString.prefix(8))"
            session.tasks.append(TaskItem(id: newId, subject: subject, status: "pending"))

        case "TaskUpdate":
            // input: { taskId, status?, subject?, ... }
            guard let taskId = input["taskId"] as? String else { return }
            if let idx = session.tasks.firstIndex(where: { $0.id == taskId }) {
                if let newStatus = input["status"] as? String {
                    session.tasks[idx].status = newStatus
                }
                if let newSubject = input["subject"] as? String {
                    session.tasks[idx].subject = newSubject
                }
            } else {
                // Task not tracked yet — create a stub
                let subject = (input["subject"] as? String) ?? "Task \(taskId.prefix(6))"
                let status = (input["status"] as? String) ?? "pending"
                session.tasks.append(TaskItem(id: taskId, subject: subject, status: status))
            }

        default:
            break
        }
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

    public var isAskUserQuestion: Bool {
        toolName == "AskUserQuestion"
    }

    /// Parse the AskUserQuestion tool_input into structured questions.
    public var questions: [Question] {
        guard let raw = toolInput["questions"] as? [[String: Any]] else { return [] }
        return raw.compactMap { dict -> Question? in
            guard let text = dict["question"] as? String else { return nil }
            let header = dict["header"] as? String
            let multiSelect = (dict["multiSelect"] as? Bool) ?? false
            let optionsRaw = dict["options"] as? [[String: Any]] ?? []
            let options = optionsRaw.compactMap { opt -> QuestionOption? in
                guard let label = opt["label"] as? String else { return nil }
                return QuestionOption(
                    label: label,
                    description: opt["description"] as? String
                )
            }
            return Question(text: text, header: header, multiSelect: multiSelect, options: options)
        }
    }

    public struct Question: Sendable {
        public let text: String
        public let header: String?
        public let multiSelect: Bool
        public let options: [QuestionOption]
    }

    public struct QuestionOption: Sendable, Identifiable {
        public let label: String
        public let description: String?
        public var id: String { label }
    }
}
