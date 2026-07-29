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

/// One in-flight Claude subagent (a `Task` dispatch), tracked between its
/// `SubagentStart` and `SubagentStop` hooks (#40).
public struct ActiveSubagent: Identifiable, Sendable, Equatable {
    /// Claude Code's `agent_id`. Present on both start and stop, so it pairs
    /// them exactly rather than by guesswork.
    public let id: String
    /// `agent_type`, e.g. "Explore" / "general-purpose". Nil if a future
    /// Claude Code stops sending it — the subagent is still counted.
    public let type: String?
    /// What this subagent was asked to do, e.g. "Fix Task 5: add missing
    /// dedup tests" (#79). Comes from the parent's own `Agent` tool call,
    /// which `PreToolUse` already delivers — the `SubagentStart` payload
    /// itself carries no description. Nil when the two could not be paired.
    public let detail: String?
    public let startedAt: Date

    public init(id: String, type: String?, detail: String? = nil, startedAt: Date) {
        self.id = id
        self.type = type
        self.detail = detail
        self.startedAt = startedAt
    }
}

/// An `Agent` tool call seen via `PreToolUse`, waiting for the matching
/// `SubagentStart` to claim its description (#79).
public struct PendingSubagentCall: Sendable, Equatable {
    public let subagentType: String?
    public let description: String
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
    /// Permission requests still waiting on the user, oldest first.
    ///
    /// A session can have several in flight at once: Claude Code issues
    /// parallel tool calls, and every bridge connection is served by its own
    /// Task, each owning a separate responder and fd. Keying a single slot by
    /// sessionId made the newest request evict the previous one's responder,
    /// stranding that bridge and letting a click land on a request the user
    /// wasn't looking at (#199). Each request now carries its own id, and the
    /// queue keeps every one of them answerable.
    public var pendingPermissions: [PendingPermission] = []

    /// The request the UI is showing — the head of the queue.
    public var pendingPermission: PendingPermission? { pendingPermissions.first }

    /// Drop the oldest AskUserQuestion notice — one completion clears one
    /// question. Used by `PostToolUse(AskUserQuestion)`, which proves exactly
    /// one question finished; clearing the whole set there would dismiss a
    /// sibling question the user still has open in the terminal.
    ///
    /// We have no `tool_use_id` in the event protocol to correlate precisely,
    /// so oldest-first is the approximation. It is safe because these entries
    /// carry a no-op responder — they are UI notices, not blocking requests, so
    /// picking the wrong one costs a prompt card, never a stranded bridge.
    mutating func dropOldestStaleAskUserQuestion() {
        guard let idx = pendingPermissions.firstIndex(where: { $0.isAskUserQuestion }) else { return }
        pendingPermissions.remove(at: idx)
        rederiveWaitingState()
    }

    /// Drop every AskUserQuestion notice — at a turn boundary they are all dead
    /// by definition. Used by UserPromptSubmit / Stop / PostCompact.
    ///
    /// Position matters in both helpers: an AskUQ can be queued *behind* a
    /// blocking request, so a head-only check would miss it, and once its
    /// clearing event has passed nothing else would ever remove it — it would
    /// surface later as a zombie head, blocking the real requests behind it.
    /// Blocking PermissionRequests are never stripped: they own a real socket
    /// responder that must be answered.
    mutating func dropAllStaleAskUserQuestions() {
        pendingPermissions.removeAll { $0.isAskUserQuestion }
        rederiveWaitingState()
    }

    /// Re-derive the waiting flag from the queue, both directions.
    ///
    /// Anything left still needs the user, whatever the caller set. Draining the
    /// queue releases a `.waiting` the requests themselves put there — but only
    /// that one: `.idle` set by a turn-boundary caller (Stop / PostCompact) is
    /// left alone, so a finished turn stays finished.
    private mutating func rederiveWaitingState() {
        if pendingPermissions.isEmpty {
            if state == .waiting { state = .working }
        } else {
            state = .waiting
        }
    }

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
    /// Whether `claudePid` came from a hook (`_bridge_ppid`, the agent that
    /// actually ran it) rather than from `activateDetectedSessions`, which
    /// guesses by picking some agent process sharing the cwd. Only the former
    /// identifies THIS session's owner, so only the former may decide
    /// liveness (#217) — a guessed sibling exiting must never evict a live
    /// session. Terminal jump is happy with either.
    public var claudePidFromHook: Bool = false
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

    /// #76 — TCP ports anything in this session's process subtree is
    /// listening on, ascending. Empty means either "nothing listening" or
    /// "couldn't tell"; both render as no badge, which is correct for both.
    public var listeningPorts: [Int] = []

    /// #77 — branch + uncommitted-work state of `cwd`. Nil when the cwd is
    /// not a git repo, is gone, or git declined to answer.
    public var git: GitStatusReader.Snapshot?

    /// #40 — Claude subagents currently running under this session, oldest
    /// first. Claude-only: Codex marks whole threads as subagent-owned via
    /// `subagentLabel` instead, which is a different concept.
    public var activeSubagents: [ActiveSubagent] = []

    /// Ceiling on tracked subagents. A malformed or runaway event stream must
    /// not grow this without bound; real fan-outs are well under it.
    public static let maxTrackedSubagents = 64

    /// #79 — `Agent` tool calls seen but not yet claimed by a SubagentStart.
    ///
    /// The two events cannot be joined on an id: `PreToolUse` fires before the
    /// subagent exists, so there is no `agent_id` yet, and no `tool_use_id`
    /// reaches us to correlate on. Matching is therefore by `subagent_type`,
    /// FIFO within a type. That is exact for a single dispatch — the case
    /// where the description is actually rendered — and at worst swaps two
    /// descriptions between same-type siblings in a parallel fan-out, where
    /// the badge shows a count anyway and the detail only reaches a tooltip.
    public var pendingSubagentCalls: [PendingSubagentCall] = []

    /// Ceiling on unclaimed `Agent` calls held per session.
    public static let maxQueuedSubagentCalls = 32

    /// Cross-agent permission risk. Nil = default "asks every time" stance
    /// (no badge). Populated from Claude `permission_mode` hook field, or
    /// from Codex `turn_context` policy fields.
    public var permissionRisk: PermissionRiskLevel?

    /// #181 — "manual" | "auto" from the last PreCompact, cleared on
    /// PostCompact. Lets the finish notification fire even when the
    /// PostCompact payload itself omits `trigger`.
    public var compactTrigger: String?

    /// #186 — contextUsedPct snapshot taken at PreCompact. Interactive CC
    /// never fires PostCompact (upstream anthropics/claude-code#78760), so
    /// compact completion is inferred from the first StatusLine whose usage
    /// collapsed vs this baseline. Same lifecycle as `compactTrigger`.
    public var compactStartContextPct: Double?

    /// #42 — when the last click-to-jump failed, and why. Transient: it
    /// answers "I just clicked and nothing happened", which stops being a
    /// live question shortly after.
    public var jumpFailedAt: Date?
    public var jumpFailureReason: JumpFailureReason?

    /// Whether a just-failed jump is still worth showing on the card.
    public func recentlyFailedJump(now: Date = Date(), within: TimeInterval = 8) -> Bool {
        guard let jumpFailedAt else { return false }
        return now.timeIntervalSince(jumpFailedAt) < within
    }

    /// #37 — how many compactions this session has completed, and when the
    /// last one finished. Unlike `compactTrigger` (which is in-flight state
    /// cleared at every turn boundary) these accumulate for the life of the
    /// session, so the card can say "compacted 3 times" rather than only
    /// "compacting right now".
    public var compactCount: Int = 0
    public var lastCompactedAt: Date?

    /// True while a compaction is running. `compactTrigger` is set by
    /// PreCompact and cleared by both completion paths, so it doubles as the
    /// in-flight flag (#181/#186).
    public var isCompacting: Bool { compactTrigger != nil }

    /// Whether a just-finished compaction is still worth showing. The marker
    /// is transient by design: it explains a gap the user may have just
    /// watched, and stops being news shortly after.
    public func recentlyCompacted(now: Date = Date(), within: TimeInterval = 60) -> Bool {
        guard let lastCompactedAt else { return false }
        return now.timeIntervalSince(lastCompactedAt) < within
    }

    /// Both completion paths funnel here so the two can never disagree:
    /// the real `PostCompact` event, and #186's StatusLine-drop inference for
    /// interactive Claude Code, which never fires PostCompact at all.
    mutating func recordCompactFinished(at date: Date = Date()) {
        compactCount += 1
        lastCompactedAt = date
        compactTrigger = nil
        compactStartContextPct = nil
    }

    /// Display name — last path component of cwd, or first 8 chars of id
    public var displayName: String {
        if let cwd = cwd, !cwd.isEmpty {
            return (cwd as NSString).lastPathComponent
        }
        return String(id.prefix(8))
    }

    /// One attention policy shared by list grouping, compact status, and sorting.
    var needsAttention: Bool {
        errorMessage != nil || pendingPermission != nil || state == .waiting
    }

    /// Lower values render first. Errors lead because the compact surface also
    /// promotes any surfaced error to its red headline state.
    var urgencyRank: Int {
        if errorMessage != nil { return 0 }
        if pendingPermission != nil { return 1 }
        switch state {
        case .waiting: return 2
        case .working: return 3
        case .idle: return 4
        case .stopped: return 5
        }
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
        self.pendingPermissions = []
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
    ///   0. errorMessage != nil        — surfaced failure
    ///   1. pendingPermission != nil   — user action needed
    ///   2. state == .waiting          — waiting on something
    ///   3. state == .working          — actively running
    ///   4. state == .idle             — at rest
    ///   5. state == .stopped          — finished
    public var orderedSessions: [SessionInfo] {
        sessions.values.sorted { lhs, rhs in
            let lp = lhs.urgencyRank
            let rp = rhs.urgencyRank
            if lp != rp { return lp < rp }
            return lhs.lastActiveAt > rhs.lastActiveAt
        }
    }

    // MARK: - Event handling

    public func handleEvent(_ event: BridgeEvent) {
        guard let sid = event.sessionId else { return }

        // #217 — any hook event naming a session is proof that agent is
        // alive, whatever the event happens to be. The switch below only
        // refreshes `lastActiveAt` inside the cases it handles, so an event
        // it has no case for (SubagentStop today, and whatever a future
        // Claude Code adds tomorrow) threw that proof away — and the liveness
        // sweep, whose grace window is 90s, then judged a live session dead.
        if sessions[sid] != nil {
            sessions[sid]?.lastActiveAt = Date()
        }

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
            newSession.claudePidFromHook = event.bridgePpid != nil
            // #181 — SessionStart(source:"compact") is a mid-session
            // administrative restart, not a new conversation, and its order
            // vs PostCompact is not guaranteed. Preserve the in-flight
            // compaction marker (it arrives before PostCompact needs it) and
            // the activity state (a default .working after PostCompact
            // already idled the card would stick — no Stop follows a manual
            // compaction). Every other source (startup/resume/clear) keeps
            // the full reset.
            if event.source == "compact", let prior = sessions[sid] {
                newSession.compactTrigger = prior.compactTrigger
                newSession.compactStartContextPct = prior.compactStartContextPct
                newSession.state = prior.state
            }
            sessions[sid] = newSession

        case "SessionEnd":
            // Codex doesn't emit SessionEnd; only Claude does.
            sessions.removeValue(forKey: sid)

        case "PreToolUse":
            var session = sessions[sid] ?? SessionInfo(id: sid, cwd: event.cwd, agent: agent)
            session.currentToolName = event.toolName
            session.currentToolInput = event.toolInput?.mapValues { $0.value }
            // #79 — the parent's `Agent` call is the only place a subagent's
            // description exists at dispatch time; SubagentStart carries the
            // ids but no description. Queue it for the start to claim.
            if agent == .claude, event.toolName == "Agent",
               let input = event.toolInput,
               let description = (input["description"]?.value as? String)?
                   .trimmingCharacters(in: .whitespacesAndNewlines),
               !description.isEmpty,
               session.pendingSubagentCalls.count < SessionInfo.maxQueuedSubagentCalls {
                session.pendingSubagentCalls.append(PendingSubagentCall(
                    subagentType: input["subagent_type"]?.value as? String,
                    description: description))
            }
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
            session.compactTrigger = nil     // #181 — marker can't outlive its turn
            session.compactStartContextPct = nil
            // #40 — leak guard. Pairing is exact while both hooks arrive, but
            // a dropped SubagentStop would otherwise leave "3 agents" on the
            // card forever. A new user turn proves nothing from the previous
            // one is still worth showing.
            session.activeSubagents = []
            // #79 — likewise for descriptions whose dispatch never started a
            // subagent (denied, errored). Left queued, one would later be
            // claimed by an unrelated subagent and describe the wrong work.
            session.pendingSubagentCalls = []
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
            session.dropAllStaleAskUserQuestions()
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
            if event.toolName == "AskUserQuestion" {
                session.dropOldestStaleAskUserQuestion()
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
            session.dropAllStaleAskUserQuestions()
            // #181 — a compaction marker whose PostCompact was lost must not
            // survive the turn boundary and promote a later trigger-less
            // compaction to "manual".
            session.compactTrigger = nil
            session.compactStartContextPct = nil
            sessions[sid] = session

        // #40 — Claude subagent lifecycle. Both hooks carry `agent_id` and
        // `agent_type` (verified against real Claude Code payloads), so the
        // pairing is exact rather than positional.
        //
        // Neither case touches `state`, `lastAssistantMessage` or the tool
        // fields, and that restraint is the point: a subagent finishing is
        // NOT the parent finishing. Idling the card here would make every
        // Task dispatch look like the session was done mid-turn, and copying
        // the subagent's `last_assistant_message` over the parent's would
        // attribute a subagent's words to the main agent.
        case "SubagentStart":
            // Claude-only concept; Codex marks whole threads subagent-owned
            // via `subagentLabel`, which this must not collide with.
            guard agent == .claude else { break }
            // Without an id we could never pair the matching stop, so the
            // entry would be unremovable. An uncounted subagent beats a
            // permanently stuck counter.
            guard let agentId = event.agentId, !agentId.isEmpty else { break }
            guard var session = sessions[sid] else { break }
            guard !session.activeSubagents.contains(where: { $0.id == agentId }),
                  session.activeSubagents.count < SessionInfo.maxTrackedSubagents
            else { break }
            // #79 — claim the queued description for this type, oldest first.
            var detail: String?
            if let index = session.pendingSubagentCalls.firstIndex(where: {
                $0.subagentType == event.agentType
            }) ?? session.pendingSubagentCalls.indices.first {
                detail = session.pendingSubagentCalls[index].description
                session.pendingSubagentCalls.remove(at: index)
            }
            session.activeSubagents.append(ActiveSubagent(
                id: agentId, type: event.agentType, detail: detail, startedAt: Date()))
            sessions[sid] = session

        case "SubagentStop":
            guard agent == .claude else { break }
            guard let agentId = event.agentId, !agentId.isEmpty else { break }
            guard var session = sessions[sid] else { break }
            session.activeSubagents.removeAll { $0.id == agentId }
            sessions[sid] = session

        case "PreCompact":
            // #181 — remember which kind of compaction is running so the
            // PostCompact finish notification can gate on manual-vs-auto even
            // when the PostCompact payload omits `trigger`. Create-on-first-
            // event like PreToolUse: /compact can fire before ZackEyes saw
            // the session.
            var session = sessions[sid] ?? SessionInfo(id: sid, cwd: event.cwd, agent: agent)
            session.compactTrigger = event.trigger
            // #186 — baseline for the finish inference: usage at compact start.
            session.compactStartContextPct = session.contextUsedPct
            session.lastActiveAt = Date()
            sessions[sid] = session

        case "PostCompact":
            // Unknown session (app restarted mid-compaction): mint .idle, not
            // the default .working — with no trigger resolvable and no Stop
            // following a manual compaction, .working would stick forever. A
            // mid-turn auto compaction self-corrects on its next PreToolUse.
            var session = sessions[sid]
                ?? SessionInfo(id: sid, cwd: event.cwd, agent: agent, state: .idle)
            // Manual /compact ends its turn HERE — no Stop follows — so mirror
            // Stop's turn-end reset (state, isToolRunning, stale-AskUQ clear).
            // An unresolvable trigger takes this path too: wrongly idling a
            // mid-turn auto compaction is transient (next PreToolUse flips it
            // back), while NOT idling a finished manual compaction sticks
            // forever. Only a provably-auto reading leaves the turn running.
            let trigger = CompactFinishGate.resolvedTrigger(
                eventTrigger: event.trigger, storedTrigger: session.compactTrigger)
            if trigger != "auto" {
                session.state = .idle
                session.isToolRunning = false
                session.dropAllStaleAskUserQuestions()
            }
            // #37 — the real PostCompact path. Shares one recorder with
            // #186's inference (`clearCompactMarker`) so the count cannot
            // differ depending on which path observed the finish; it also
            // clears the in-flight marker, which is what used to happen here.
            session.recordCompactFinished()
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

        // Post-switch stamp: capture claude pid + transcript path if the
        // bridge supplied them. Runs after the switch so it covers sessions
        // that were freshly created in a switch case (e.g. PreToolUse arriving
        // before any SessionStart, which happens when CC was started before
        // ZackEyes or after a ZackEyes restart). Without this, AskUQ Submit
        // dies at GUARD-4 because KeystrokeInjector has no terminal pid.
        if var existing = sessions[sid] {
            var dirty = false
            // A hook's ppid is the agent that ran it, so it outranks whatever
            // is stored — including a PID `activateDetectedSessions` guessed
            // by cwd. Previously this only filled a nil, leaving a guess
            // uncorrected forever (#217).
            //
            // StatusLine is the one exception. When the user already has a
            // statusLine of their own, `deployStatusLineMux` runs the bridge
            // as a BACKGROUND PIPELINE member (`... | bridge … &`), so its
            // ppid is the mux shell — transient, and gone seconds later.
            // Trusting it would overwrite the real agent PID with a corpse:
            // terminal jump would miss, and the sweep would evict the session
            // the moment statusLine traffic paused past the grace window.
            // Real hooks supply the PID anyway; StatusLine only refreshes
            // `lastActiveAt`, which it still does above.
            if event.bridgeEvent != "StatusLine",
               let ppid = event.bridgePpid,
               existing.claudePid != ppid || !existing.claudePidFromHook {
                existing.claudePid = ppid
                existing.claudePidFromHook = true
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
        // Append, never replace: an in-flight request's responder is the only
        // way to answer its bridge (#199).
        session.pendingPermissions.append(permission)
        session.lastActiveAt = Date()
        sessions[sessionId] = session
    }

    /// Answer one specific request and promote the next, if any.
    ///
    /// `requestId` names the request the UI was showing when the user clicked.
    /// Without it a click resolves whatever happens to be at the head — and the
    /// head can change between render and click (the shown request's bridge
    /// disconnects, promoting the next one), which is the very mix-up #199 is
    /// about. An unknown id means that request is already gone: no-op.
    public func resolvePermission(sessionId: String, requestId: UUID, allow: Bool) {
        guard var session = sessions[sessionId],
              let idx = session.pendingPermissions.firstIndex(where: { $0.id == requestId })
        else { return }
        let pending = session.pendingPermissions.remove(at: idx)
        let response: PermissionResponse = allow
            ? .allow(message: "User approved via ZackEyes")
            : .deny(message: "User denied via ZackEyes")
        pending.responder(.permission(response))
        // Still waiting if another request is queued behind this one.
        session.state = session.pendingPermissions.isEmpty ? .working : .waiting
        session.lastActiveAt = Date()
        sessions[sessionId] = session
    }

    /// Resolve the primary pending permission (convenience for single-session UI).
    public func resolvePrimaryPermission(allow: Bool) {
        guard let primary = primarySession, let shown = primary.pendingPermission else { return }
        resolvePermission(sessionId: primary.id, requestId: shown.id, allow: allow)
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
    public func allowAlways(sessionId: String, requestId: UUID) {
        guard var session = sessions[sessionId],
              let pending = session.pendingPermissions.first(where: { $0.id == requestId })
        else { return }
        if !Self.isHighRisk(pending.toolName) {
            session.autoAllowedTools.insert(pending.toolName)
            sessions[sessionId] = session
        }
        // Send the .allow for that same request + drop it from the queue.
        resolvePermission(sessionId: sessionId, requestId: requestId, allow: true)
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
    /// Drop the one request whose bridge went away. Other requests on the same
    /// session are still waiting on the user and must survive (#199) — keying
    /// this by sessionId alone used to wipe a live prompt belonging to a
    /// different request.
    public func abandonPermission(sessionId: String, requestId: UUID) {
        guard var session = sessions[sessionId],
              let idx = session.pendingPermissions.firstIndex(where: { $0.id == requestId })
        else { return }
        session.pendingPermissions.remove(at: idx)
        if session.pendingPermissions.isEmpty {
            session.state = .working  // back to normal
        }
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

        // Dedup: same label AND same message still showing from within the
        // window = the same ongoing limit, not a fresh event. Keying on the
        // message too (not just the label) avoids collapsing two DISTINCT
        // failures that share a generic label (e.g. both "Codex error"); a real
        // usage-limit retry burst carries an identical message (same reset
        // time) within the window, so burst-dedup is unaffected (CodeRabbit PR
        // review). `session.lastAssistantMessage` here is the prior error's
        // message — recordCodexError stamps it below.
        let isNew: Bool
        if let priorLabel = session.errorMessage, priorLabel == label,
           session.lastAssistantMessage == message,
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

    // MARK: - Listening ports (#76)

    /// Which sessions may have their process subtree scanned for listening
    /// ports, and under which root pid.
    ///
    /// Only pids that came from a hook's `_bridge_ppid` qualify. This is the
    /// same gate liveness uses, for the same reason (CLAUDE.md invariant #7 /
    /// #217): `activateDetectedSessions` fills `claudePid` by guessing *some*
    /// agent process sharing the cwd, and that guess is good enough to jump a
    /// terminal but not to own a port. Scanning a guessed sibling's subtree
    /// would print its dev server on this session's card — a wrong answer
    /// stated confidently, which is worse than no badge.
    ///
    /// Pure function so the gate is testable without real processes.
    public static func portScanRoots(_ sessions: [SessionInfo]) -> [String: Int32] {
        var roots: [String: Int32] = [:]
        for session in sessions {
            guard session.claudePidFromHook, let pid = session.claudePid, pid > 0
            else { continue }
            roots[session.id] = Int32(pid)
        }
        return roots
    }

    /// Store a completed port scan. Every known session is updated, including
    /// those absent from `portsBySession` — an absent session was not measured
    /// this tick, and showing its previous ports would claim a dev server is
    /// up when we no longer have grounds to say so.
    ///
    /// Callers must therefore only invoke this with the result of a scan that
    /// actually ran; a failed snapshot must skip the call entirely rather than
    /// pass `[:]`, otherwise a transient kernel hiccup blanks every badge.
    public func applyListeningPorts(_ portsBySession: [String: [Int]]) {
        for (id, session) in sessions {
            let ports = portsBySession[id] ?? []
            guard session.listeningPorts != ports else { continue }
            var updated = session
            updated.listeningPorts = ports
            sessions[id] = updated
        }
    }

    /// Store a completed git scan, keyed by cwd (#77).
    ///
    /// Unlike `applyListeningPorts`, a session missing from the map keeps its
    /// previous snapshot rather than being cleared. The two differ because the
    /// claims differ: "listening on :3000" is about a process that may have
    /// just exited, so silence must retract it; "on branch feat/x with 3
    /// changes" describes a directory that does not stop existing because one
    /// git invocation timed out. Blanking it would make the badge flicker.
    public func applyGitSnapshots(_ snapshotsByCwd: [String: GitStatusReader.Snapshot]) {
        for (id, session) in sessions {
            guard let cwd = session.cwd, let snapshot = snapshotsByCwd[cwd] else { continue }
            guard session.git != snapshot else { continue }
            var updated = session
            updated.git = snapshot
            sessions[id] = updated
        }
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
            session.claudePidFromHook = sessions[d.id]?.claudePidFromHook ?? false
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
    /// #186 — drop the compaction marker + baseline after the inference path
    /// fired its notification, so the same collapsed reading (or a repeat)
    /// can't fire twice.
    /// #42 — record how a click-to-jump ended.
    ///
    /// Success clears any previous failure marker, so a card that failed once
    /// and then worked does not keep accusing itself.
    public func recordJumpOutcome(
        sessionId: String,
        failure: JumpFailureReason?,
        at date: Date = Date()
    ) {
        guard var session = sessions[sessionId] else { return }
        session.jumpFailureReason = failure
        session.jumpFailedAt = failure == nil ? nil : date
        sessions[sessionId] = session
    }

    public func clearCompactMarker(sessionId: String) {
        guard var session = sessions[sessionId] else { return }
        // #37 — this is #186's inferred-completion path, so it is a real
        // finished compaction and counts as one.
        session.recordCompactFinished()
        sessions[sessionId] = session
    }

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
        // Guard against negated phrasing — an assistant message like "your usage
        // limit has not been reached yet" must NOT raise the banner (Gemini PR
        // review). A plain `!contains("not reached")` misses "not BEEN reached",
        // so match a negation ("not" / "n't") within a short span before the
        // trigger word instead. The real codex error ("You've hit your usage
        // limit") has no such negation, so it still matches.
        let negatedUsageLimit = lower.range(
            of: "(?:\\bnot\\b|n['\u{2019}]t)[^.]{0,25}?(?:reached|exceeded|hit)",
            options: .regularExpression
        ) != nil
        if lower.contains("usage limit") &&
            (lower.contains("reached") || lower.contains("exceeded")
                || lower.contains("hit")),
           !negatedUsageLimit {
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
    /// Identifies this specific request. One session can have several in
    /// flight, each owning its own bridge connection and responder, so
    /// resolving or abandoning must name which one (#199).
    public let id: UUID
    public let toolName: String
    public let toolInput: [String: Any]
    public let cwd: String?
    public let responder: @Sendable (BridgeResponse) -> Void

    public init(
        id: UUID = UUID(),
        toolName: String,
        toolInput: [String: Any],
        cwd: String?,
        responder: @escaping @Sendable (BridgeResponse) -> Void
    ) {
        self.id = id
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
