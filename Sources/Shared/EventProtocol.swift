import Foundation

// MARK: - SessionState

public enum SessionState: String, Codable, Sendable {
    case idle
    case working
    case waiting
    case stopped
}

// MARK: - AgentKind

/// Which AI coding agent produced this hook event. Bridge stamps this onto
/// every payload via the `--agent` CLI flag (defaults to `.claude` so legacy
/// hook entries that predate the flag keep working).
public enum AgentKind: String, Codable, Sendable {
    case claude
    case codex
}

// MARK: - AnyCodable

/// Type-erased JSON value wrapper. Handles all JSON primitives, arrays, and objects.
// @unchecked Sendable is safe here because AnyCodable only stores JSON-compatible
// value types (Bool, Int, Double, String, Array, Dictionary) and NSNull (immutable).
// The JSONDecoder never produces mutable reference types.
public struct AnyCodable: Codable, @unchecked Sendable {
    public let value: Any

    public init(_ value: Any) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self.value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            self.value = bool
        } else if let int = try? container.decode(Int.self) {
            self.value = int
        } else if let double = try? container.decode(Double.self) {
            self.value = double
        } else if let string = try? container.decode(String.self) {
            self.value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            self.value = array.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            self.value = dict.mapValues { $0.value }
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "AnyCodable: unsupported type"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch value {
        case is NSNull:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            let codableArray = array.map { AnyCodable($0) }
            try container.encode(codableArray)
        case let dict as [String: Any]:
            let codableDict = dict.mapValues { AnyCodable($0) }
            try container.encode(codableDict)
        default:
            let context = EncodingError.Context(
                codingPath: encoder.codingPath,
                debugDescription: "AnyCodable: unsupported type \(type(of: value))"
            )
            throw EncodingError.invalidValue(value, context)
        }
    }
}

// MARK: - BridgeEvent

/// Represents a hook event sent from Claude Code via stdin to Bridge.
/// Decodes JSON with snake_case keys via explicit CodingKeys.
/// Unknown fields in the JSON are silently ignored (default Codable behavior).
public struct BridgeEvent: Codable, Sendable {
    public let bridgeEvent: String
    public let agent: AgentKind
    public let sessionId: String?
    public let hookEventName: String?
    public let cwd: String?
    public let toolName: String?
    public let toolInput: [String: AnyCodable]?
    public let permissionMode: String?
    public let transcriptPath: String?
    public let userPrompt: String?
    public let source: String?
    public let bridgePpid: Int?
    public let lastAssistantMessage: String?
    public let rateLimits: [String: AnyCodable]?
    public let contextWindow: [String: AnyCodable]?  // per-session context usage (Claude statusLine)
    public let model: [String: AnyCodable]?           // {id, display_name}
    public let cost: [String: AnyCodable]?            // {total_cost_usd, total_duration_ms, ...}

    public init(
        bridgeEvent: String,
        agent: AgentKind = .claude,
        sessionId: String? = nil,
        hookEventName: String? = nil,
        cwd: String? = nil,
        toolName: String? = nil,
        toolInput: [String: AnyCodable]? = nil,
        permissionMode: String? = nil,
        transcriptPath: String? = nil,
        userPrompt: String? = nil,
        source: String? = nil,
        bridgePpid: Int? = nil,
        lastAssistantMessage: String? = nil,
        rateLimits: [String: AnyCodable]? = nil,
        contextWindow: [String: AnyCodable]? = nil,
        model: [String: AnyCodable]? = nil,
        cost: [String: AnyCodable]? = nil
    ) {
        self.bridgeEvent = bridgeEvent
        self.agent = agent
        self.sessionId = sessionId
        self.hookEventName = hookEventName
        self.cwd = cwd
        self.toolName = toolName
        self.toolInput = toolInput
        self.permissionMode = permissionMode
        self.transcriptPath = transcriptPath
        self.userPrompt = userPrompt
        self.source = source
        self.bridgePpid = bridgePpid
        self.lastAssistantMessage = lastAssistantMessage
        self.rateLimits = rateLimits
        self.contextWindow = contextWindow
        self.model = model
        self.cost = cost
    }

    private enum CodingKeys: String, CodingKey {
        case bridgeEvent          = "_bridge_event"
        case agent                = "_bridge_agent"
        case sessionId            = "session_id"
        case hookEventName        = "hook_event_name"
        case cwd
        case toolName             = "tool_name"
        case toolInput            = "tool_input"
        case permissionMode       = "permission_mode"
        case transcriptPath       = "transcript_path"
        case userPrompt           = "prompt"
        case source
        case bridgePpid           = "_bridge_ppid"
        case lastAssistantMessage = "last_assistant_message"
        case rateLimits           = "rate_limits"
        case contextWindow        = "context_window"
        case model
        case cost
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.bridgeEvent = try c.decode(String.self, forKey: .bridgeEvent)
        // Legacy bridge entries (pre-agent flag) omit _bridge_agent. Default to
        // Claude — that's what those installs were originally doing.
        self.agent = (try? c.decodeIfPresent(AgentKind.self, forKey: .agent)) ?? .claude
        self.sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId)
        self.hookEventName = try c.decodeIfPresent(String.self, forKey: .hookEventName)
        self.cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        self.toolName = try c.decodeIfPresent(String.self, forKey: .toolName)
        self.toolInput = try c.decodeIfPresent([String: AnyCodable].self, forKey: .toolInput)
        self.permissionMode = try c.decodeIfPresent(String.self, forKey: .permissionMode)
        self.transcriptPath = try c.decodeIfPresent(String.self, forKey: .transcriptPath)
        self.userPrompt = try c.decodeIfPresent(String.self, forKey: .userPrompt)
        self.source = try c.decodeIfPresent(String.self, forKey: .source)
        self.bridgePpid = try c.decodeIfPresent(Int.self, forKey: .bridgePpid)
        self.lastAssistantMessage = try c.decodeIfPresent(String.self, forKey: .lastAssistantMessage)
        self.rateLimits = try c.decodeIfPresent([String: AnyCodable].self, forKey: .rateLimits)
        self.contextWindow = try c.decodeIfPresent([String: AnyCodable].self, forKey: .contextWindow)
        self.model = try c.decodeIfPresent([String: AnyCodable].self, forKey: .model)
        self.cost = try c.decodeIfPresent([String: AnyCodable].self, forKey: .cost)
    }
}

// MARK: - PermissionResponse

/// Response sent back to Claude Code after a PermissionRequest hook.
/// Encodes to the exact structure Claude Code expects:
/// {"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow","message":"..."}}}
public struct PermissionResponse: Codable, Sendable {
    public let hookSpecificOutput: HookSpecificOutput

    public struct HookSpecificOutput: Codable, Sendable {
        public let hookEventName: String
        public let decision: Decision
    }

    public struct Decision: Codable, Sendable {
        public let behavior: String
        public let message: String?
        public let updatedInput: [String: AnyCodable]?

        public init(behavior: String, message: String? = nil, updatedInput: [String: AnyCodable]? = nil) {
            self.behavior = behavior
            self.message = message
            self.updatedInput = updatedInput
        }
    }

    public static func allow(message: String) -> PermissionResponse {
        PermissionResponse(
            hookSpecificOutput: HookSpecificOutput(
                hookEventName: "PermissionRequest",
                decision: Decision(behavior: "allow", message: message)
            )
        )
    }

    public static func deny(message: String) -> PermissionResponse {
        PermissionResponse(
            hookSpecificOutput: HookSpecificOutput(
                hookEventName: "PermissionRequest",
                decision: Decision(behavior: "deny", message: message)
            )
        )
    }
}

// MARK: - PreToolUseHookResponse

/// Response sent to Claude Code from a PreToolUse hook to either auto-allow
/// (with optional `updatedInput`) or auto-answer an `AskUserQuestion` tool
/// call by populating `updatedInput.answers`. CC consumes `answers` directly
/// and skips its own terminal UI for AskUserQuestion when this is set.
public struct PreToolUseHookResponse: Codable, Sendable {
    public let hookSpecificOutput: HookSpecificOutput

    public struct HookSpecificOutput: Codable, Sendable {
        public let hookEventName: String  // always "PreToolUse"
        public let permissionDecision: String  // "allow"
        public let updatedInput: [String: AnyCodable]?

        public init(updatedInput: [String: AnyCodable]? = nil) {
            self.hookEventName = "PreToolUse"
            self.permissionDecision = "allow"
            self.updatedInput = updatedInput
        }
    }

    /// Build a response that auto-answers AskUserQuestion. CC keys `answers`
    /// by the exact `question` text (verified in spike 2026-04-25); values
    /// are single strings (multi-select uses comma-joined labels).
    public static func askUQAnswers(
        questions: [[String: Any]],
        answers: [String: String]
    ) -> PreToolUseHookResponse {
        return PreToolUseHookResponse(
            hookSpecificOutput: HookSpecificOutput(
                updatedInput: [
                    "questions": AnyCodable(questions),
                    "answers": AnyCodable(answers),
                ]
            )
        )
    }
}

// MARK: - BridgeEvent helpers

extension BridgeEvent {
    /// True when this event needs the bridge to wait for an app-side response
    /// (the connection stays open instead of fire-and-forget).
    ///
    /// AskUserQuestion is non-blocking on both PreToolUse and the
    /// PermissionRequest companion event. The popup is now a notice-only
    /// surface — it shows the question text and a "Click to answer in
    /// terminal" CTA, and tapping the session card jumps to the right
    /// terminal tab; the user answers in CC's native terminal AskUQ UI.
    /// Two reasons to keep AskUQ off the blocking path:
    ///
    /// 1. Auto-allowing the PermissionRequest would short-circuit CC's
    ///    terminal UI and cause it to return an empty answer immediately,
    ///    firing PostToolUse and clearing the popup before the user can
    ///    read or click the CTA.
    /// 2. Treating it as blocking on the app side puts the SocketServer
    ///    into a poll loop; when the bridge fire-and-forgets and closes
    ///    the connection, POLLHUP triggers `abandonPermission`, which
    ///    clears the popup mid-render.
    ///
    /// Regular PermissionRequest still blocks because Allow/Deny answers
    /// travel back through the socket.
    public var requiresBlockingResponse: Bool {
        bridgeEvent == "PermissionRequest" && toolName != "AskUserQuestion"
    }
}

// MARK: - BridgeResponse

/// Sum type for any response the app sends back to a blocking bridge call.
/// `PermissionRequest` and `PreToolUse + AskUserQuestion` use structurally
/// different JSON shapes; this enum keeps them straight at the call sites.
public enum BridgeResponse: Sendable {
    case permission(PermissionResponse)
    case preToolUse(PreToolUseHookResponse)

    public func encoded() throws -> Data {
        switch self {
        case .permission(let r): return try JSONEncoder().encode(r)
        case .preToolUse(let r): return try JSONEncoder().encode(r)
        }
    }
}
