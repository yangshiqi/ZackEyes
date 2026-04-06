import Foundation

// MARK: - SessionState

public enum SessionState: String, Codable, Sendable {
    case idle
    case working
    case waiting
    case stopped
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
    public let sessionId: String?
    public let hookEventName: String?
    public let cwd: String?
    public let toolName: String?
    public let toolInput: [String: AnyCodable]?
    public let permissionMode: String?
    public let transcriptPath: String?

    public init(
        bridgeEvent: String,
        sessionId: String? = nil,
        hookEventName: String? = nil,
        cwd: String? = nil,
        toolName: String? = nil,
        toolInput: [String: AnyCodable]? = nil,
        permissionMode: String? = nil,
        transcriptPath: String? = nil
    ) {
        self.bridgeEvent = bridgeEvent
        self.sessionId = sessionId
        self.hookEventName = hookEventName
        self.cwd = cwd
        self.toolName = toolName
        self.toolInput = toolInput
        self.permissionMode = permissionMode
        self.transcriptPath = transcriptPath
    }

    private enum CodingKeys: String, CodingKey {
        case bridgeEvent      = "_bridge_event"
        case sessionId        = "session_id"
        case hookEventName    = "hook_event_name"
        case cwd
        case toolName         = "tool_name"
        case toolInput        = "tool_input"
        case permissionMode   = "permission_mode"
        case transcriptPath   = "transcript_path"
    }
}

// MARK: - PermissionResponse

/// Response sent back to Claude Code after a permission request hook.
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
        public let message: String
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
