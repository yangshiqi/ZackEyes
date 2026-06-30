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
    /// Tool names approved via "Allow Always" for the rest of this session.
    /// Session-scoped only — disappears with the SessionInfo when the session
    /// is removed (liveness sweep / SessionEnd). Never persisted to disk.
    public var autoAllowedTools: Set<String> = []
    public var startedAt: Date
    public var lastActiveAt: Date
    public var toolCallCount: Int
    public var source: SessionSource = .live
    public var tasks: [TaskItem] = []
    public var claudePid: Int?   // PID of the claude/codex process (from bridge ppid)
    public var transcriptPath: String?  // Path to the JSONL transcript file (for lsof lookup)
    public var errorMessage: String?
    public var errorAt: Date?

    // Per-session context window data (Claude statusLine or Codex token_count)
    public var contextUsedPct: Double?
    public var contextWindowSize: Int?
    public var modelDisplayName: String?
    public var totalCostUSD: Double?

    /// Codex-only: name of the subagent owning this thread when the rollout's
    /// `session_meta.source.subagent` is populated (e.g. "guardian", "review").
    /// Nil for the main user thread.
    public var subagentLabel: String?

    /// Cross-agent permission risk. Nil = default "asks every time" stance
    /// (no badge). Populated from Claude `permission_mode` hook field, or
    /// from Codex `turn_context` policy fields.
    public var permissionRisk: PermissionRiskLevel?

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

/// Cross-agent risk classification for the session's current permission stance.
/// Both Claude (`permission_mode`) and Codex (`turn_context.approval_policy`
/// + `sandbox_policy.type`) collapse into this enum so the badge UI is
/// agent-agnostic. Nil = default "asks for permission" stance — no badge.
public enum PermissionRiskLevel: String, Sendable, Equatable {
    /// Claude `plan` mode — read-only by design.
    case plan
    /// Auto-approves within bounded scope. Claude `acceptEdits`, or Codex
    /// `never` approval + `workspace-write` sandbox, or Codex `on-request`
    /// approval + `danger-full-access` (asks per-command but unsandboxed).
    case auto
    /// Unconstrained access. Claude `bypassPermissions`, or Codex `never`
    /// approval + `danger-full-access` sandbox.
    case yolo

    /// Map Claude's `permission_mode` payload value. Returns nil for the
    /// default "asks each time" mode.
    public static func fromClaudeMode(_ raw: String) -> PermissionRiskLevel? {
        switch raw {
        case "acceptEdits":       return .auto
        case "bypassPermissions": return .yolo
        case "plan":              return .plan
        default:                  return nil
        }
    }

    /// Map Codex's per-turn approval + sandbox combination.
    public static func fromCodex(approvalPolicy: String?, sandboxType: String?) -> PermissionRiskLevel? {
        // Default mode is "on-request + workspace-write" — codex asks, scope
        // is project. No badge needed.
        let approval = approvalPolicy ?? "on-request"
        let sandbox = sandboxType ?? "workspace-write"

        // Read-only sandbox is structurally harmless — codex literally cannot
        // mutate the filesystem, so the absence of an interactive gate
        // ("never") doesn't matter. No badge.
        if sandbox == "read-only" { return nil }

        if approval == "never" && sandbox == "danger-full-access" {
            return .yolo
        }
        if approval == "never" && sandbox == "workspace-write" {
            // Silent edits within the project — surface as .auto.
            return .auto
        }
        if approval == "on-request" && sandbox == "danger-full-access" {
            // Asks per-command but the approved command runs unsandboxed.
            return .auto
        }
        return nil
    }
}

@MainActor
public final class SessionStore: ObservableObject {
    /// All active sessions, keyed by session_id.
    @Published public var sessions: [String: SessionInfo] = [:]

    public init() {}

    /// #78: injected Codex price lookup (raw model id → ModelPrice). Set by
    /// AppDelegate from PricingStore so SessionStore stays decoupled from
    /// Bundle/network. nil → no per-session Codex cost computed.
    public var codexPriceLookup: ((String) -> ModelPrice?)?

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
            // Reject-by-new-prompt path: user ESC'd an open AskUQ and typed a
            // new prompt instead of picking an option. CC synthesizes a
            // "User rejected tool use" tool_result and does NOT fire
            // PostToolUse, so the popup-clearing branch in PostToolUse never
            // runs. Same-session UserPromptSubmit is the earliest reliable
            // signal that the question is dead — clear here, gated on
            // isAskUserQuestion so blocking PermissionRequests (which need a
            // real socket responder) are never stripped underneath.
            // Also reset state to .working — handlePermissionRequest left it
            // at .waiting, and without this the session would stay flagged
            // as waiting (wrongly prioritized in the UI ranking) even though
            // there's nothing waiting on the user anymore.
            if session.pendingPermission?.isAskUserQuestion == true {
                session.pendingPermission = nil
                session.state = .working
            }
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
            // Backstop for the UserPromptSubmit branch above: if a turn ends
            // with a stale AskUQ still pending (no rejection prompt, no
            // PostToolUse fired), it can never be resolved. Same gate.
            if session.pendingPermission?.isAskUserQuestion == true {
                session.pendingPermission = nil
            }
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

        // Post-switch stamp: capture claude pid + transcript path if the
        // bridge supplied them. Runs after the switch so it covers sessions
        // that were freshly created in a switch case (e.g. PreToolUse arriving
        // before any SessionStart, which happens when CC was started before
        // ZackEyes or after a ZackEyes restart). Without this, AskUQ Submit
        // dies at GUARD-4 because KeystrokeInjector has no terminal pid.
        if var existing = sessions[sid] {
            var dirty = false
            if let ppid = event.bridgePpid, existing.claudePid == nil {
                existing.claudePid = ppid
                dirty = true
            }
            if let tp = event.transcriptPath, existing.transcriptPath == nil {
                existing.transcriptPath = tp
                dirty = true
            }
            // Claude-only: stamp permission_mode whenever the payload carries
            // it. The user can switch modes mid-session (Shift-Tab cycle), so
            // overwrite on every event — going back to "default" clears the
            // badge. Codex's equivalent flows through the tailer policy event.
            if event.agent == .claude, let modeStr = event.permissionMode {
                let newRisk = PermissionRiskLevel.fromClaudeMode(modeStr)
                if existing.permissionRisk != newRisk {
                    existing.permissionRisk = newRisk
                    dirty = true
                }
            }
            if dirty { sessions[sid] = existing }
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

    /// Resolve the primary pending permission (convenience for single-session UI).
    public func resolvePrimaryPermission(allow: Bool) {
        guard let primary = primarySession, primary.pendingPermission != nil else { return }
        resolvePermission(sessionId: primary.id, allow: allow)
    }

    /// Tools whose blanket "Allow Always" is too dangerous to honor — a single
    /// approval would silently auto-run every future invocation this session
    /// (e.g. any Bash command, `rm -rf` included). These always require a fresh
    /// confirmation (#128). Extend conservatively. Same-uid is out of the threat
    /// model; this is a defense-in-depth UX guardrail, not a security boundary.
    public static let highRiskTools: Set<String> = ["Bash"]

    public static func isHighRisk(_ toolName: String) -> Bool {
        highRiskTools.contains(toolName)
    }

    /// "Allow Always": approve the current request AND remember the tool name so
    /// future PermissionRequests for the same tool in this session are
    /// auto-allowed (see `isToolAutoAllowed` + the short-circuit in
    /// `AppDelegate.handleEvent`). Session-scoped, never persisted. A high-risk
    /// tool is approved once but NOT remembered (#128).
    public func allowAlways(sessionId: String) {
        guard var session = sessions[sessionId], let pending = session.pendingPermission else { return }
        if !Self.isHighRisk(pending.toolName) {
            session.autoAllowedTools.insert(pending.toolName)
            sessions[sessionId] = session
        }
        // Send the .allow for the current request + clear pending + go working.
        resolvePermission(sessionId: sessionId, allow: true)
    }

    /// True when the given tool was approved via "Allow Always" for this session
    /// and a fresh PermissionRequest should be auto-allowed without a popup.
    public func isToolAutoAllowed(sessionId: String, toolName: String) -> Bool {
        // High-risk tools are never auto-allowed, even if somehow recorded (#128).
        if Self.isHighRisk(toolName) { return false }
        return sessions[sessionId]?.autoAllowedTools.contains(toolName) ?? false
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
            // A real reply this turn = the agent recovered. Clear any error
            // banner left by a prior usage-limit hit. The error turn's OWN
            // task_complete carries a nil/empty message (see real rollouts),
            // so this never wrongly clears the error it just surfaced.
            session.errorMessage = nil
            session.errorAt = nil
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

    /// Notification dedup window for repeated identical Codex errors. Codex
    /// retries a usage-limit'd turn within seconds, re-emitting the same
    /// `error` row; collapse those into one notification while still keeping
    /// the banner fresh. A fresh attempt failing again after the window
    /// re-notifies.
    public static let codexErrorNotifyWindow: TimeInterval = 120

    /// Surface a Codex `event_msg.error` (usage-limit hit / API failure) on the
    /// owning session so the popup's error banner + a system notification fire.
    /// This is the jsonl-tailer path — Codex hooks never carry errors, so it's
    /// the only source, and (unlike task_complete) it must surface for hooked
    /// `.live` sessions too. Returns the updated session plus `isNew`: whether
    /// this error is worth notifying on (false for a deduped retry burst).
    @discardableResult
    public func recordCodexError(
        sessionId: String,
        cwd: String?,
        message: String,
        errorInfo: String?,
        transcriptPath: String?,
        observedAt: Date
    ) -> (session: SessionInfo, isNew: Bool) {
        let label = Self.codexErrorLabel(errorInfo: errorInfo, message: message)
        let didCreateSession = sessions[sessionId] == nil
        var session = sessions[sessionId]
            ?? SessionInfo(
                id: sessionId,
                cwd: cwd,
                agent: .codex,
                state: .idle,
                startedAt: observedAt
            )
        session.agent = .codex
        if session.cwd == nil { session.cwd = cwd }
        if session.transcriptPath == nil { session.transcriptPath = transcriptPath }
        if didCreateSession { session.source = .detected }

        // Dedup: same label still showing from within the window = the same
        // ongoing limit, not a fresh event.
        let isNew: Bool
        if let priorLabel = session.errorMessage, priorLabel == label,
           let priorAt = session.errorAt,
           observedAt.timeIntervalSince(priorAt) < Self.codexErrorNotifyWindow {
            isNew = false
        } else {
            isNew = true
        }

        session.errorMessage = label
        session.errorAt = observedAt
        // Mirror Claude's error path, where the full error text lives in the
        // assistant message: stash the message so the banner detail shows the
        // reset time + link.
        session.lastAssistantMessage = message
        session.lastActiveAt = observedAt
        sessions[sessionId] = session
        return (session, isNew)
    }

    /// Map a Codex `event_msg.error` to a short banner label. Prefers the
    /// structured `codex_error_info` code, then the generic assistant-output
    /// detector on the message, then a generic fallback (never empty).
    public static func codexErrorLabel(errorInfo: String?, message: String) -> String {
        switch errorInfo {
        case "usage_limit_exceeded": return "Usage limit reached"
        default: break
        }
        if let detected = detectError(in: message) { return detected }
        return "Codex error"
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

    /// Apply Codex's per-rollout `event_msg.token_count.info` context data
    /// to the same fields Claude statusLine uses, so the popup can share the
    /// existing context bar. Token-count events imply an active Codex turn,
    /// so a missing session is created as working.
    public func recordCodexContext(
        sessionId: String,
        cwd: String?,
        contextUsedPct: Double,
        contextWindowSize: Int?,
        transcriptPath: String?,
        observedAt: Date,
        cumulativeInput: Int? = nil,
        cumulativeCached: Int? = nil,
        cumulativeOutput: Int? = nil
    ) {
        let didCreateSession = sessions[sessionId] == nil
        var session = sessions[sessionId]
            ?? SessionInfo(
                id: sessionId,
                cwd: cwd,
                agent: .codex,
                state: .working,
                startedAt: observedAt
            )
        session.agent = .codex
        if session.cwd == nil { session.cwd = cwd }
        if session.transcriptPath == nil { session.transcriptPath = transcriptPath }
        if didCreateSession {
            session.source = .detected
        }
        session.contextUsedPct = contextUsedPct
        session.contextWindowSize = contextWindowSize
        session.currentToolName = session.currentToolName ?? "Codex"
        if didCreateSession || (session.state != .idle && session.state != .stopped) {
            session.isToolRunning = true
            session.state = .working
        }
        session.lastActiveAt = observedAt

        // #78: per-session Codex cost from cumulative totals × price. The raw
        // model id lives in `modelDisplayName` for codex (set from
        // turn_context.model). `cached` is a subset of `input` — mirrors the
        // codex branch of `buildDailyUsage`. Unknown model / missing tokens →
        // leave totalCostUSD unchanged (no $, consistent with "unpriced").
        if let model = session.modelDisplayName,
           let price = codexPriceLookup?(model),
           let input = cumulativeInput, let output = cumulativeOutput {
            let cached = cumulativeCached ?? 0
            let uncached = max(0, input - cached)
            session.totalCostUSD = Double(uncached) * price.inputPerToken
                + Double(cached) * price.cacheReadPerToken
                + Double(output) * price.outputPerToken
        }

        sessions[sessionId] = session
    }

    /// Apply Codex's per-turn `turn_context.model` to the session. Mirrors
    /// what `applyStatusLineFields` does for Claude via `model.display_name`.
    /// Creates a `.detected` session if missing — the watcher attaches at EOF
    /// and may bootstrap model from a quiescent rollout that never fires a
    /// streaming token_count, so we can't rely on `recordCodexContext` to
    /// create the row first.
    public func setCodexModelDisplayName(
        sessionId: String,
        cwd: String?,
        transcriptPath: String?,
        displayName: String
    ) {
        var session = sessions[sessionId] ?? SessionInfo(
            id: sessionId,
            cwd: cwd,
            agent: .codex,
            state: .idle,
            startedAt: Date()
        )
        if session.cwd == nil { session.cwd = cwd }
        if session.transcriptPath == nil { session.transcriptPath = transcriptPath }
        if sessions[sessionId] == nil {
            session.source = .detected
        }
        session.modelDisplayName = displayName
        sessions[sessionId] = session
    }

    /// Apply Codex's per-turn approval+sandbox policy as a unified
    /// `permissionRisk`. Setting nil clears the badge — happens naturally when
    /// the user toggles approval/sandbox back to defaults mid-session.
    public func setCodexPermissionRisk(
        sessionId: String,
        cwd: String?,
        transcriptPath: String?,
        risk: PermissionRiskLevel?
    ) {
        var session = sessions[sessionId] ?? SessionInfo(
            id: sessionId,
            cwd: cwd,
            agent: .codex,
            state: .idle,
            startedAt: Date()
        )
        if session.cwd == nil { session.cwd = cwd }
        if session.transcriptPath == nil { session.transcriptPath = transcriptPath }
        if sessions[sessionId] == nil {
            session.source = .detected
        }
        session.permissionRisk = risk
        sessions[sessionId] = session
    }

    /// Apply Codex's `session_meta.source.subagent` to the session. Subagent
    /// label is session-level (set once from line 1 of the rollout). Mirrors
    /// `setCodexModelDisplayName` — create-or-update so bootstrap races with
    /// SessionScanner don't drop the label.
    public func setCodexSubagentLabel(
        sessionId: String,
        cwd: String?,
        transcriptPath: String?,
        label: String
    ) {
        var session = sessions[sessionId] ?? SessionInfo(
            id: sessionId,
            cwd: cwd,
            agent: .codex,
            state: .idle,
            startedAt: Date()
        )
        if session.cwd == nil { session.cwd = cwd }
        if session.transcriptPath == nil { session.transcriptPath = transcriptPath }
        if sessions[sessionId] == nil {
            session.source = .detected
        }
        session.subagentLabel = label
        sessions[sessionId] = session
    }

    /// Import sessions discovered by SessionScanner. These are read-only and
    /// marked as `.detected` — user needs to restart them (or open a new
    /// thread, in Codex's case) for live tracking.
    ///
    /// Returns the number of sessions actually created/refreshed. The #83
    /// periodic rescan re-feeds known sessions every tick: when the
    /// transcript hasn't moved (`lastModified` matches `lastActiveAt`), the
    /// rebuild is skipped — no TaskExtractor re-parse, and any enrichment
    /// written since the last import (e.g. recap fallbacks) survives.
    @discardableResult
    public func importDetectedSessions(_ detected: [SessionScanner.DetectedSession]) -> Int {
        var imported = 0
        for d in detected {
            // Don't overwrite live sessions if we already have them
            if sessions[d.id]?.source == .live { continue }
            // Unchanged-skip (#83): same transcript mtime ⇒ nothing new.
            if let existing = sessions[d.id], existing.source == .detected,
               existing.lastActiveAt == d.lastModified { continue }

            var session = SessionInfo(
                id: d.id,
                cwd: d.cwd,
                agent: d.agent,
                state: .idle,
                startedAt: d.lastModified
            )
            session.lastActiveAt = d.lastModified
            session.lastUserPrompt = d.lastUserPrompt
            session.lastAssistantMessage = d.lastAssistantMessage   // #43 recap fallback
            session.transcriptPath = d.transcriptPath
            // TaskExtractor only knows the Claude transcript schema. Codex
            // tasks would need their own extractor (deferred).
            if d.agent == .claude {
                session.tasks = TaskExtractor.extractTasks(fromTranscriptAt: d.transcriptPath)
            }
            session.source = .detected
            // #83 — carry the activation cache across refreshes: a transcript
            // mtime bump must not put an already-activated session back into
            // the re-lsof / re-title path.
            session.claudePid = sessions[d.id]?.claudePid
            sessions[d.id] = session
            imported += 1
        }
        return imported
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
            (lower.contains("reached") || lower.contains("exceeded")
                || lower.contains("hit")) {
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
