import Foundation
import Shared

@MainActor
public final class SessionStore: ObservableObject {
    @Published public var state: SessionState = .idle
    @Published public var sessionId: String?
    @Published public var cwd: String?
    @Published public var currentToolName: String?
    @Published public var pendingPermission: PendingPermission?
    @Published public var sessionStartedAt: Date?
    @Published public var lastActiveAt: Date?
    @Published public var toolCallCount: Int = 0

    public init() {}

    public func handleEvent(_ event: BridgeEvent) {
        switch event.bridgeEvent {
        case "SessionStart":
            state = .working
            sessionId = event.sessionId
            cwd = event.cwd
            currentToolName = nil
            pendingPermission = nil
            sessionStartedAt = Date()
            lastActiveAt = Date()
            toolCallCount = 0
        case "SessionEnd":
            state = .idle
            sessionId = nil
            cwd = nil
            currentToolName = nil
            pendingPermission = nil
            sessionStartedAt = nil
            lastActiveAt = nil
            toolCallCount = 0
        case "PreToolUse":
            currentToolName = event.toolName
            toolCallCount += 1
            lastActiveAt = Date()
            if state == .idle { state = .working }
        case "PostToolUse":
            currentToolName = nil
            lastActiveAt = Date()
        case "Stop":
            // Stop = Claude finished current turn, session still active.
            // Keep sessionId/cwd (unlike SessionEnd which clears everything).
            state = .idle
            currentToolName = nil
            lastActiveAt = Date()
        default:
            break
        }
    }

    public func handlePermissionRequest(_ permission: PendingPermission) {
        state = .waiting
        pendingPermission = permission
    }

    public func resolvePermission(allow: Bool) {
        guard let pending = pendingPermission else { return }
        let response: PermissionResponse = allow
            ? .allow(message: "User approved via ZackEyes")
            : .deny(message: "User denied via ZackEyes")
        pending.responder(response)
        pendingPermission = nil
        state = sessionId != nil ? .working : .idle
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
