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
    public var agent: AgentKind = .claude
    public var cwd: String?
    public var state: SessionState
    public var currentToolName: String?
    public var currentToolInput: [String: Any]?
    public var isToolRunning: Bool = false
    public var lastUserPrompt: String?
    public var lastAssistantMessage: String?
    public var pendingPermission: PendingPermission?
    public var startedAt: Date
    public var lastActiveAt: Date
    public var toolCallCount: Int
    public var source: SessionSource = .live
    public var tasks: [TaskItem] = []
    public var claudePid: Int?   // PID of the claude/codex process (from bridge ppid)
    public var transcriptPath: String?  // Path to the JSONL transcript file (for lsof lookup)
    public var errorMessage: String?
    public var errorAt: Date?

    // Per-session context window data (from statusLine — Claude only)
    public var contextUsedPct: Double?
    public var contextWindowSize: Int?
    public var modelDisplayName: String?
    public var totalCostUSD: Double?

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
        agent: AgentKind = .claude,
        state: SessionState = .working,
        startedAt: Date = Date()
    ) {
        self.id = id
        self.agent = agent
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

    /// All sessions sorted for the list display.
    ///
    /// Tiered ordering — sort by urgency first, then recency within a tier.
    /// A pure `lastActiveAt` sort caused working and idle sessions to
    /// constantly swap places (any idle session that got a status-line
    /// update would briefly leapfrog a working one between its tool calls).
    ///
    /// Tiers, top to bottom:
    ///   0. pendingPermission != nil  — user action needed (most urgent)
    ///   1. state == .working          — actively running
    ///   2. state == .waiting          — waiting on something
    ///   3. state == .idle             — at rest
    ///   4. state == .stopped          — finished
    public var orderedSessions: [SessionInfo] {
        sessions.values.sorted { lhs, rhs in
            let lp = sortPriority(lhs)
            let rp = sortPriority(rhs)
            if lp != rp { return lp < rp }
            return lhs.lastActiveAt > rhs.lastActiveAt
        }
    }

    private func sortPriority(_ session: SessionInfo) -> Int {
        if session.pendingPermission != nil { return 0 }
        switch session.state {
        case .working: return 1
        case .waiting: return 2
        case .idle:    return 3
        case .stopped: return 4
        }
    }

    // MARK: - Event handling

    public func handleEvent(_ event: BridgeEvent) {
        guard let sid = event.sessionId else { return }

        // Any live hook event upgrades a detected session to live
        if let existing = sessions[sid], existing.source == .detected {
            upgradeToLive(sessionId: sid)
        }

        // statusLine carries per-session context window + model + cost
        applyStatusLineFields(event: event, sid: sid)

        // Capture claude pid + transcript path from bridge if available;
        // also stamp the session's agent if the existing record doesn't
        // have one yet (defensive — should already match).
        if var existing = sessions[sid] {
            if let ppid = event.bridgePpid, existing.claudePid == nil {
                existing.claudePid = ppid
            }
            if let tp = event.transcriptPath, existing.transcriptPath == nil {
                existing.transcriptPath = tp
            }
            sessions[sid] = existing
        }

        let agent = event.agent

        switch event.bridgeEvent {
        case "SessionStart":
            var newSession = SessionInfo(id: sid, cwd: event.cwd, agent: agent)
            newSession.claudePid = event.bridgePpid
            sessions[sid] = newSession

        case "SessionEnd":
            // Codex doesn't emit SessionEnd; only Claude does.
            sessions.removeValue(forKey: sid)

        case "PreToolUse":
            var session = sessions[sid] ?? SessionInfo(id: sid, cwd: event.cwd, agent: agent)
            session.currentToolName = event.toolName
            session.currentToolInput = event.toolInput?.mapValues { $0.value }
            session.isToolRunning = true
            session.toolCallCount += 1
            session.lastActiveAt = Date()
            if session.state == .idle { session.state = .working }

            sessions[sid] = session

        case "UserPromptSubmit":
            var session = sessions[sid] ?? SessionInfo(id: sid, cwd: event.cwd, agent: agent)
            if let prompt = event.userPrompt {
                session.lastUserPrompt = prompt
                session.lastAssistantMessage = nil  // clear stale reply on new prompt
            }
            session.errorMessage = nil       // user is retrying
            session.errorAt = nil
            session.lastActiveAt = Date()
            if session.state == .idle { session.state = .working }
            sessions[sid] = session

        case "PostToolUse":
            // Don't clear currentToolName — keep it as "most recent action".
            // Just mark that the tool is no longer running.
            var session = sessions[sid] ?? SessionInfo(id: sid, cwd: event.cwd, agent: agent)
            session.isToolRunning = false
            session.lastActiveAt = Date()

            // If a Task* tool just completed, refresh task list from transcript
            // (TaskUpdate hook input lacks subject; transcript has the source of truth)
            if let tool = event.toolName,
               tool.hasPrefix("Task"),
               let path = session.transcriptPath ?? event.transcriptPath {
                session.transcriptPath = path
                session.tasks = TaskExtractor.extractTasks(fromTranscriptAt: path)
            }

            // Path 2 dual-surface AskUQ: when CC's terminal UI closes (i.e.
            // the user answered in either surface), CC fires PostToolUse for
            // AskUserQuestion. Clear any AskUQ popup still open for this
            // session so it doesn't sit there pointing at a question that's
            // already been resolved.
            if event.toolName == "AskUserQuestion",
               let pending = session.pendingPermission,
               pending.isAskUserQuestion {
                session.pendingPermission = nil
                session.state = .working
            }

            sessions[sid] = session

        case "Stop":
            // Stop = agent finished current turn, session still active.
            // Codex uses Stop in place of SessionEnd, so we leave the
            // session alive (it'll naturally idle out).
            var session = sessions[sid] ?? SessionInfo(id: sid, cwd: event.cwd, agent: agent)
            session.state = .idle
            session.isToolRunning = false
            if let msg = event.lastAssistantMessage {
                session.lastAssistantMessage = msg
                // Detect API errors / rate limits in assistant output
                if let errText = Self.detectError(in: msg) {
                    session.errorMessage = errText
                    session.errorAt = Date()
                }
            }
            session.lastActiveAt = Date()
            sessions[sid] = session

        case "Notification":
            // Claude-only — Codex doesn't define Notification.
            var session = sessions[sid] ?? SessionInfo(id: sid, cwd: event.cwd, agent: agent)
            // The notification text is in lastAssistantMessage or we can check tool_input
            let notifText = event.lastAssistantMessage ?? ""
            if let errText = Self.detectError(in: notifText) {
                session.errorMessage = errText
                session.errorAt = Date()
                session.lastActiveAt = Date()
                sessions[sid] = session
            }

        default:
            break
        }
    }

    public func handlePermissionRequest(
        sessionId: String,
        permission: PendingPermission,
        agent: AgentKind = .claude
    ) {
        var session = sessions[sessionId]
            ?? SessionInfo(id: sessionId, cwd: permission.cwd, agent: agent)
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
        pending.responder(.permission(response))
        session.pendingPermission = nil
        session.state = .working
        session.lastActiveAt = Date()
        sessions[sessionId] = session
    }

    /// Submit AskUserQuestion answers chosen in the popup. Path 2: instead
    /// of replying via the (now closed) socket, drive CC's native terminal
    /// AskUQ UI by injecting the same keystrokes a human would type. CC
    /// will fire `PostToolUse(AskUserQuestion)` when its UI closes; the
    /// popup auto-dismisses on that event regardless of which surface
    /// answered first.
    ///
    /// `answers` is keyed by question text; for multi-select the value is
    /// a comma-joined string of selected option labels.
    ///
    /// **Scope (v1)**: only single-question AskUQ is wired through the
    /// popup. CC's multi-question TUI uses tab/submit semantics that
    /// vary by terminal — multi-question prompts keep the popup as an
    /// informational mirror, and the user answers each question in the
    /// terminal directly. The PostToolUse hook still closes the popup.
    @discardableResult
    public func submitAskUQAnswer(sessionId: String, answers: [String: String]) -> Bool {
        guard var session = sessions[sessionId],
              let pending = session.pendingPermission,
              pending.isAskUserQuestion else { return false }
        let questions = pending.questions
        guard questions.count == 1, let question = questions.first else {
            // Multi-question — let the user answer in the terminal. PostToolUse
            // will dismiss this popup when CC's TUI closes.
            return false
        }
        guard let answerValue = answers[question.text] else { return false }

        let injected: Bool
        if question.multiSelect {
            let labels = answerValue
                .split(separator: ",", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            let indices = labels.compactMap { label in
                question.options.firstIndex { $0.label == label }
            }
            guard !indices.isEmpty,
                  let pid = session.claudePid else { return false }
            injected = KeystrokeInjector.sendMultiSelect(
                agentPid: pid,
                cwd: session.cwd,
                sessionId: session.id,
                selectedIndices: indices
            )
        } else {
            guard let idx = question.options.firstIndex(where: { $0.label == answerValue }),
                  let pid = session.claudePid else { return false }
            injected = KeystrokeInjector.sendSingleSelect(
                agentPid: pid,
                cwd: session.cwd,
                sessionId: session.id,
                optionIndex: idx
            )
        }

        // Clear the popup eagerly when injection succeeded — the user has
        // committed an answer. On failure (no AX permission, etc.) leave
        // the popup up so the user can retry from the terminal; PostToolUse
        // will eventually clear it when CC's UI closes.
        if injected {
            session.pendingPermission = nil
            session.state = .working
            session.lastActiveAt = Date()
            sessions[sessionId] = session
        }
        return injected
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

    /// Apply a Codex `event_msg.task_complete` observation to the session
    /// state. This is the jsonl-tailer fallback path (used when codex's TUI
    /// predates our hooks and never fires `Stop`). Mirrors the Stop branch
    /// of `handleEvent`: marks the session idle, captures the agent's last
    /// reply, refreshes activity timestamps, and stamps any missing cwd /
    /// transcript metadata. Returns the updated `SessionInfo` so callers
    /// (AppDelegate) can fire UI notifications without re-reading the
    /// store.
    @discardableResult
    public func recordCodexTaskComplete(
        sessionId: String,
        cwd: String?,
        lastAgentMessage: String?,
        transcriptPath: String?,
        completedAt: Date
    ) -> SessionInfo {
        let didCreateSession = sessions[sessionId] == nil
        var session = sessions[sessionId]
            ?? SessionInfo(
                id: sessionId,
                cwd: cwd,
                agent: .codex,
                state: .idle,
                startedAt: completedAt
            )
        session.agent = .codex
        if session.cwd == nil { session.cwd = cwd }
        if session.transcriptPath == nil { session.transcriptPath = transcriptPath }
        if let msg = lastAgentMessage, !msg.isEmpty {
            session.lastAssistantMessage = msg
        }
        if didCreateSession {
            session.source = .detected
        }
        session.state = .idle
        session.isToolRunning = false
        session.lastActiveAt = completedAt
        sessions[sessionId] = session
        return session
    }

    public func recordCodexTaskStarted(
        sessionId: String,
        cwd: String?,
        transcriptPath: String?,
        startedAt: Date,
        turnId: String?
    ) {
        let didCreateSession = sessions[sessionId] == nil
        var session = sessions[sessionId]
            ?? SessionInfo(
                id: sessionId,
                cwd: cwd,
                agent: .codex,
                state: .working,
                startedAt: startedAt
            )
        session.agent = .codex
        if session.cwd == nil { session.cwd = cwd }
        if session.transcriptPath == nil { session.transcriptPath = transcriptPath }
        session.currentToolName = "Codex"
        if let turnId {
            session.currentToolInput = ["turn_id": turnId]
        }
        if didCreateSession {
            session.source = .detected
        }
        session.isToolRunning = true
        session.state = .working
        session.lastActiveAt = startedAt
        sessions[sessionId] = session
    }

    /// Import sessions discovered by SessionScanner. These are read-only and
    /// marked as `.detected` — user needs to restart them (or open a new
    /// thread, in Codex's case) for live tracking.
    public func importDetectedSessions(_ detected: [SessionScanner.DetectedSession]) {
        for d in detected {
            // Don't overwrite live sessions if we already have them
            if sessions[d.id]?.source == .live { continue }

            var session = SessionInfo(
                id: d.id,
                cwd: d.cwd,
                agent: d.agent,
                state: .idle,
                startedAt: d.lastModified
            )
            session.lastActiveAt = d.lastModified
            session.lastUserPrompt = d.lastUserPrompt
            session.transcriptPath = d.transcriptPath
            // TaskExtractor only knows the Claude transcript schema. Codex
            // tasks would need their own extractor (deferred).
            if d.agent == .claude {
                session.tasks = TaskExtractor.extractTasks(fromTranscriptAt: d.transcriptPath)
            }
            session.source = .detected
            sessions[d.id] = session
        }
    }

    /// Remove sessions by id. Skips any session that currently has a
    /// pendingPermission — that's an active user-action prompt and must
    /// only be cleared via the bridge socket's abandon path. The actual
    /// "is this session dead" decision is made by the caller (typically
    /// `AppDelegate`, which runs `lsof` off the main actor).
    public func removeSessions(ids: Set<String>) {
        for sid in ids {
            guard let session = sessions[sid] else { continue }
            if session.pendingPermission != nil { continue }
            sessions.removeValue(forKey: sid)
        }
    }

    /// Upgrade a detected session to live when we receive our first hook event for it.
    public func upgradeToLive(sessionId: String) {
        guard var session = sessions[sessionId], session.source == .detected else { return }
        session.source = .live
        sessions[sessionId] = session
    }

    /// Apply per-session statusLine fields (context window, model, cost) to the
    /// session if present in the event. Creates the session if it doesn't exist.
    private func applyStatusLineFields(event: BridgeEvent, sid: String) {
        let hasAny = event.contextWindow != nil || event.model != nil || event.cost != nil
        guard hasAny else { return }

        var session = sessions[sid] ?? SessionInfo(id: sid, cwd: event.cwd, agent: event.agent)

        if let cw = event.contextWindow {
            if let used = (cw["used_percentage"]?.value as? Double)
                ?? (cw["used_percentage"]?.value as? Int).map(Double.init) {
                session.contextUsedPct = used
            }
            if let size = (cw["context_window_size"]?.value as? Int)
                ?? (cw["context_window_size"]?.value as? Double).map(Int.init) {
                session.contextWindowSize = size
            }
        }

        if let model = event.model {
            if let name = model["display_name"]?.value as? String {
                session.modelDisplayName = name
            }
        }

        if let cost = event.cost {
            if let usd = (cost["total_cost_usd"]?.value as? Double)
                ?? (cost["total_cost_usd"]?.value as? Int).map(Double.init) {
                session.totalCostUSD = usd
            }
        }

        if let cwd = event.cwd, session.cwd == nil {
            session.cwd = cwd
        }
        session.lastActiveAt = Date()
        sessions[sid] = session
    }

    /// Detect Claude Code / Anthropic API error patterns in assistant output.
    /// Returns a short user-facing error string, or nil if no error found.
    ///
    /// HTTP status codes must appear as **standalone number tokens** (not
    /// embedded in prose like `<500=low` or `$500k`) AND be accompanied by
    /// a matching error phrase. The previous `contains("500")` check fired
    /// on any assistant message that happened to mention the number 500.
    static func detectError(in text: String) -> String? {
        let lower = text.lowercased()

        // Helper — matches a number only when surrounded by whitespace or
        // string boundaries. Rejects `<500=`, `$500k`, `500,000` etc.
        func hasStandaloneStatus(_ code: String) -> Bool {
            let pattern = #"(?<!\S)"# + code + #"(?!\S)"#
            return lower.range(of: pattern, options: .regularExpression) != nil
        }

        // HTTP status errors: status code + corroborating error phrase
        if hasStandaloneStatus("503") && lower.contains("service unavailable") {
            return "Service unavailable (503)"
        }
        if hasStandaloneStatus("500") &&
            (lower.contains("internal server") || lower.contains("server error")) {
            return "Server error (500)"
        }
        if hasStandaloneStatus("502") && lower.contains("bad gateway") {
            return "Bad gateway (502)"
        }
        if hasStandaloneStatus("504") &&
            (lower.contains("gateway timeout") || lower.contains("timed out")) {
            return "Gateway timeout (504)"
        }
        if hasStandaloneStatus("429") &&
            (lower.contains("too many requests") || lower.contains("rate limit")) {
            return "Rate limited (429)"
        }
        if hasStandaloneStatus("401") && lower.contains("unauthorized") {
            return "Unauthorized (401)"
        }
        if hasStandaloneStatus("403") && lower.contains("forbidden") {
            return "Forbidden (403)"
        }

        // Rate limit / quota — no status code required
        if lower.contains("rate_limit_error") { return "Rate limited" }
        if lower.contains("rate limit") &&
            (lower.contains("exceeded") || lower.contains("reached")
                || lower.contains("hit") || lower.contains("too many")) {
            return "Rate limited"
        }
        if lower.contains("quota") && lower.contains("exceeded") {
            return "Quota exceeded"
        }
        if lower.contains("usage limit") &&
            (lower.contains("reached") || lower.contains("exceeded")) {
            return "Usage limit reached"
        }

        // Auth / billing
        if lower.contains("credit balance") &&
            (lower.contains("low") || lower.contains("insufficient")) {
            return "Insufficient credits"
        }

        // Overload
        if lower.contains("overloaded_error") || lower.contains("api overloaded")
            || lower.contains("is overloaded") {
            return "API overloaded"
        }

        // Explicit connection / rejection
        if lower.contains("connection error") { return "Connection error" }
        if lower.contains("request rejected") { return "Request rejected" }

        return nil
    }

    // Note: Task list changes are handled by re-extracting from the transcript JSONL
    // on PostToolUse of Task* tools. See `handleEvent` above and `TaskExtractor`.
}

public struct PendingPermission {
    public let toolName: String
    public let toolInput: [String: Any]
    public let cwd: String?
    public let responder: @Sendable (BridgeResponse) -> Void

    public init(
        toolName: String,
        toolInput: [String: Any],
        cwd: String?,
        responder: @escaping @Sendable (BridgeResponse) -> Void
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
