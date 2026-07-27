import Foundation
import Testing
@testable import AppLib
import Shared

struct SessionListPresentationTests {
    @Test
    func groupsAttentionRunningAndRecentWithoutChangingOrder() {
        var pending = session("pending", state: .working, age: 4)
        pending.pendingPermissions = [PendingPermission(
            toolName: "Read", toolInput: [:], cwd: "/tmp", responder: { _ in }
        )]
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
        #expect(SessionListPresentation.shouldAutoExpandRecent(in: sections))
    }

    @Test
    func recentDoesNotAutoExpandAlongsideActiveWork() {
        let sections = SessionListPresentation.sections(from: [
            session("running", state: .working, age: 1),
            session("done", state: .stopped, age: 0),
        ])

        #expect(sections.map(\.group) == [.running, .recent])
        #expect(!SessionListPresentation.shouldAutoExpandRecent(in: sections))
    }

    @Test @MainActor
    func sharedAttentionPolicySortsIdleErrorAheadOfWaiting() {
        var error = session("error", state: .idle, age: 1)
        error.errorMessage = "API error"
        let waiting = session("waiting", state: .waiting, age: 2)
        let running = session("running", state: .working, age: 3)

        #expect(error.needsAttention)
        #expect(waiting.needsAttention)
        #expect(!running.needsAttention)

        let store = SessionStore()
        store.sessions = [error.id: error, waiting.id: waiting, running.id: running]
        let sections = SessionListPresentation.sections(from: store.orderedSessions)

        #expect(sections.map(\.group) == [.needsYou, .running])
        #expect(sections[0].sessions.map(\.id) == ["error", "waiting"])
    }

    @Test
    func duplicateProjectTitlesGainStableShortSessionIds() {
        let first = SessionInfo(id: "abcd-1111", cwd: "/tmp/project")
        let second = SessionInfo(id: "efgh-2222", cwd: "/work/project")
        let unique = SessionInfo(id: "ijkl-3333", cwd: "/tmp/other")
        let sessions = [first, second, unique]
        let duplicates = SessionListPresentation.duplicateDisplayNames(in: sessions)

        #expect(duplicates == ["project"])
        #expect(SessionListPresentation.title(
            for: first, duplicateDisplayNames: duplicates
        ) == "project · abcd")
        #expect(SessionListPresentation.title(
            for: unique, duplicateDisplayNames: duplicates
        ) == "other")
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
