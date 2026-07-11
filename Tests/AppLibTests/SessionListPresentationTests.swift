import Foundation
import Testing
@testable import AppLib
import Shared

struct SessionListPresentationTests {
    @Test
    func groupsAttentionRunningAndRecentWithoutChangingOrder() {
        var pending = session("pending", state: .working, age: 4)
        pending.pendingPermission = PendingPermission(
            toolName: "Read", toolInput: [:], cwd: "/tmp", responder: { _ in }
        )
        var error = session("error", state: .working, age: 3)
        error.errorMessage = "API error"
        let waiting = session("waiting", state: .waiting, age: 2)
        let running = session("running", state: .working, age: 1)
        let idle = session("idle", state: .idle, age: 0)

        let sections = SessionListPresentation.sections(
            from: [pending, error, waiting, running, idle]
        )

        #expect(sections.map(\.group) == [.needsYou, .running, .recent])
        #expect(sections[0].sessions.map(\.id) == ["pending", "error", "waiting"])
        #expect(sections[1].sessions.map(\.id) == ["running"])
        #expect(sections[2].sessions.map(\.id) == ["idle"])
    }

    @Test
    func omitsEmptyGroups() {
        let sections = SessionListPresentation.sections(
            from: [session("done", state: .stopped, age: 0)]
        )
        #expect(sections.map(\.group) == [.recent])
    }

    private func session(_ id: String, state: SessionState, age: TimeInterval) -> SessionInfo {
        SessionInfo(
            id: id,
            cwd: "/tmp/\(id)",
            state: state,
            startedAt: Date(timeIntervalSince1970: age)
        )
    }
}
