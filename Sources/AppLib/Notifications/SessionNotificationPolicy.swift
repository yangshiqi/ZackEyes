import Shared

/// Keeps notification decisions separate from desktop delivery.
public enum SessionNotificationPolicy {
    public static func shouldNotifyFinished(event: BridgeEvent, priorState: SessionState?, session: SessionInfo) -> Bool {
        !event.isReplayed && event.bridgeEvent == "Stop" && session.errorMessage == nil
            && !(event.agent == .claude && event.agentId?.isEmpty == false)
            && (priorState == .working || priorState == .waiting)
            && (session.toolCallCount > 0 || session.lastUserPrompt != nil || event.lastAssistantMessage?.isEmpty == false)
    }

    public static func errorDetail(for session: SessionInfo) -> String? {
        session.errorDetail ?? session.lastAssistantMessage
    }
}
