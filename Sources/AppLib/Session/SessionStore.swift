import Foundation
import Shared

@MainActor
public final class SessionStore: ObservableObject {
    @Published public var state: SessionState = .idle
    @Published public var sessionId: String?
    @Published public var cwd: String?
    @Published public var currentToolName: String?
    @Published public var pendingPermission: PendingPermission?

    public init() {}

    public func handleEvent(_ event: BridgeEvent) {
        switch event.bridgeEvent {
        case "SessionStart":
            state = .working
            sessionId = event.sessionId
            cwd = event.cwd
            currentToolName = nil
            pendingPermission = nil
        case "SessionEnd":
            state = .idle
            sessionId = nil
            cwd = nil
            currentToolName = nil
            pendingPermission = nil
        case "PreToolUse":
            currentToolName = event.toolName
            if state == .idle { state = .working }
        case "PostToolUse":
            currentToolName = nil
        case "Stop":
            // Stop = Claude finished current turn, session still active.
            // Keep sessionId/cwd (unlike SessionEnd which clears everything).
            state = .idle
            currentToolName = nil
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
