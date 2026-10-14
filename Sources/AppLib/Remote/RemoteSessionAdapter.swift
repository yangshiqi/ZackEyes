import Foundation
import RemoteCore
import Shared

extension SessionStore {
    /// Complete replacement for exactly one host; no bridge events, responders,
    /// process identities, transcript paths, usage or journal side effects.
    public func replaceRemoteSessions(host: RemoteHost, snapshot: RemoteSnapshot) throws {
        try RemoteFrameCodec.validate(snapshot)
        var updated = sessions.filter { $0.value.remoteHostID != host.id }
        for remote in snapshot.sessions {
            let id = "remote:\(host.id.uuidString):\(remote.agent.rawValue):\(remote.id)"
            let state: SessionState
            switch remote.state {
            case .working: state = .working
            case .waiting: state = .waiting
            case .idle, .unknown, .error: state = .idle
            }
            var session = SessionInfo(
                id: id, cwd: remote.cwd, agent: remote.agent == .claude ? .claude : .codex,
                state: state, startedAt: remote.lastActivity)
            session.source = .remote
            session.remoteHostID = host.id
            session.remoteHostName = host.name
            session.remoteObservedState = remote.state
            session.lastActiveAt = remote.lastActivity
            session.currentToolName = remote.tool
            session.modelDisplayName = remote.model
            if remote.state == .error { session.errorMessage = "Remote agent reported an error" }
            updated[id] = session
        }
        sessions = updated
    }
    public func removeRemoteSessions(hostID: UUID) {
        guard sessions.values.contains(where: { $0.remoteHostID == hostID }) else { return }
        sessions = sessions.filter { $0.value.remoteHostID != hostID }
    }
}
