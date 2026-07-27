import Foundation
import Testing
@testable import AppLib
import Shared

struct CompactAttentionTests {
    @Test
    func errorTakesPriorityAndCountIncludesAllAttentionSessions() {
        var error = SessionInfo(id: "error", cwd: "/tmp", state: .working)
        error.errorMessage = "failed"
        var pending = SessionInfo(id: "pending", cwd: "/tmp", state: .working)
        pending.pendingPermissions = [PendingPermission(
            toolName: "Read", toolInput: [:], cwd: "/tmp", responder: { _ in }
        )]

        #expect(CompactAttention.make(from: [error, pending]) == CompactAttention(
            kind: .error,
            count: 2
        ))
    }

    @Test
    func waitingCountsAsPendingAndWorkingAloneIsCalm() {
        let waiting = SessionInfo(id: "waiting", cwd: "/tmp", state: .waiting)
        let working = SessionInfo(id: "working", cwd: "/tmp", state: .working)

        #expect(CompactAttention.make(from: [waiting]).kind == .pending)
        #expect(CompactAttention.make(from: [working]) == CompactAttention(
            kind: .none,
            count: 0
        ))
    }
}
