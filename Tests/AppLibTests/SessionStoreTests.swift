import Testing
import Foundation
@testable import AppLib
import Shared

@MainActor
struct SessionStoreTests {

    // 1. Initial state is empty
    @Test func initialStateIsEmpty() {
        let store = SessionStore()
        #expect(store.sessions.isEmpty)
        #expect(store.primarySession == nil)
        #expect(store.aggregateState == .idle)
    }

    // 2. SessionStart creates a session
    @Test func sessionStartCreatesSession() {
        let store = SessionStore()
        let event = BridgeEvent(bridgeEvent: "SessionStart", sessionId: "s1", cwd: "/tmp")
        store.handleEvent(event)
        #expect(store.sessions.count == 1)
        #expect(store.sessions["s1"]?.state == .working)
        #expect(store.sessions["s1"]?.cwd == "/tmp")
        #expect(store.aggregateState == .working)
    }

    // 3. PreToolUse increments tool count
    @Test func preToolUseIncrementsToolCount() {
        let store = SessionStore()
        store.handleEvent(BridgeEvent(bridgeEvent: "SessionStart", sessionId: "s1", cwd: "/tmp"))
        store.handleEvent(BridgeEvent(bridgeEvent: "PreToolUse", sessionId: "s1", toolName: "Bash"))
        #expect(store.sessions["s1"]?.currentToolName == "Bash")
        #expect(store.sessions["s1"]?.toolCallCount == 1)
        store.handleEvent(BridgeEvent(bridgeEvent: "PreToolUse", sessionId: "s1", toolName: "Write"))
        #expect(store.sessions["s1"]?.toolCallCount == 2)
    }

    // 4. PermissionRequest sets waiting on the right session
    @Test func permissionRequestSetsWaiting() {
        let store = SessionStore()
        store.handleEvent(BridgeEvent(bridgeEvent: "SessionStart", sessionId: "s1", cwd: "/tmp"))
        let permission = PendingPermission(
            toolName: "Bash",
            toolInput: [:],
            cwd: "/tmp",
            responder: { _ in }
        )
        store.handlePermissionRequest(sessionId: "s1", permission: permission)
        #expect(store.sessions["s1"]?.state == .waiting)
        #expect(store.sessions["s1"]?.pendingPermission != nil)
        #expect(store.aggregateState == .waiting)
    }

    // 5. resolvePrimaryPermission allow returns to working
    @Test func resolvePermissionAllowReturnsToWorking() {
        let store = SessionStore()
        store.handleEvent(BridgeEvent(bridgeEvent: "SessionStart", sessionId: "s1", cwd: "/tmp"))
        let permission = PendingPermission(
            toolName: "Bash",
            toolInput: [:],
            cwd: "/tmp",
            responder: { _ in }
        )
        store.handlePermissionRequest(sessionId: "s1", permission: permission)
        store.resolvePrimaryPermission(allow: true)
        #expect(store.sessions["s1"]?.state == .working)
        #expect(store.sessions["s1"]?.pendingPermission == nil)
    }

    // 6. SessionEnd removes the session
    @Test func sessionEndRemovesSession() {
        let store = SessionStore()
        store.handleEvent(BridgeEvent(bridgeEvent: "SessionStart", sessionId: "s1", cwd: "/tmp"))
        store.handleEvent(BridgeEvent(bridgeEvent: "SessionEnd", sessionId: "s1"))
        #expect(store.sessions.isEmpty)
    }

    // 7. Stop sets idle but keeps session
    @Test func stopSetsIdleKeepsSession() {
        let store = SessionStore()
        store.handleEvent(BridgeEvent(bridgeEvent: "SessionStart", sessionId: "s1", cwd: "/tmp"))
        store.handleEvent(BridgeEvent(bridgeEvent: "Stop", sessionId: "s1"))
        #expect(store.sessions["s1"]?.state == .idle)
        #expect(store.sessions.count == 1)  // session still exists
    }

    // 8. Multiple sessions tracked independently
    @Test func multipleSessionsTrackedIndependently() {
        let store = SessionStore()
        store.handleEvent(BridgeEvent(bridgeEvent: "SessionStart", sessionId: "s1", cwd: "/project-a"))
        store.handleEvent(BridgeEvent(bridgeEvent: "SessionStart", sessionId: "s2", cwd: "/project-b"))
        store.handleEvent(BridgeEvent(bridgeEvent: "PreToolUse", sessionId: "s1", toolName: "Bash"))
        store.handleEvent(BridgeEvent(bridgeEvent: "PreToolUse", sessionId: "s2", toolName: "Write"))
        store.handleEvent(BridgeEvent(bridgeEvent: "PreToolUse", sessionId: "s2", toolName: "Edit"))

        #expect(store.sessions.count == 2)
        #expect(store.sessions["s1"]?.toolCallCount == 1)
        #expect(store.sessions["s2"]?.toolCallCount == 2)
        #expect(store.sessions["s1"]?.currentToolName == "Bash")
        #expect(store.sessions["s2"]?.currentToolName == "Edit")
    }

    // 9. Primary session prioritizes pending permission
    @Test func primarySessionPrioritizesPending() {
        let store = SessionStore()
        store.handleEvent(BridgeEvent(bridgeEvent: "SessionStart", sessionId: "s1", cwd: "/a"))
        store.handleEvent(BridgeEvent(bridgeEvent: "SessionStart", sessionId: "s2", cwd: "/b"))
        // s2 is more recent (working), but s1 gets a pending permission
        let permission = PendingPermission(toolName: "Bash", toolInput: [:], cwd: "/a", responder: { _ in })
        store.handlePermissionRequest(sessionId: "s1", permission: permission)
        #expect(store.primarySession?.id == "s1")
    }

    // 10b. removeSessions deletes the requested ids, but refuses to clear
    //       a session that has an active pendingPermission, and silently
    //       ignores ids that don't exist in the store.
    @Test func removeSessionsRespectsPendingPermissionAndUnknownIds() {
        let store = SessionStore()
        store.handleEvent(BridgeEvent(bridgeEvent: "SessionStart", sessionId: "a", cwd: "/tmp"))
        store.handleEvent(BridgeEvent(bridgeEvent: "SessionStart", sessionId: "b", cwd: "/tmp"))
        store.handleEvent(BridgeEvent(bridgeEvent: "SessionStart", sessionId: "c", cwd: "/tmp"))

        // c has a pending permission — should survive a remove request
        let permission = PendingPermission(toolName: "Bash", toolInput: [:], cwd: "/tmp", responder: { _ in })
        store.handlePermissionRequest(sessionId: "c", permission: permission)

        store.removeSessions(ids: ["a", "c", "ghost"])

        #expect(store.sessions["a"] == nil)            // removed
        #expect(store.sessions["b"] != nil)            // not requested
        #expect(store.sessions["c"] != nil)            // pending — refused
        #expect(store.sessions.count == 2)             // ghost id is a no-op
    }

    // 10. Aggregate state reflects worst status across sessions
    @Test func aggregateStateReflectsWorstStatus() {
        let store = SessionStore()
        store.handleEvent(BridgeEvent(bridgeEvent: "SessionStart", sessionId: "s1", cwd: "/a"))
        store.handleEvent(BridgeEvent(bridgeEvent: "Stop", sessionId: "s1"))
        #expect(store.aggregateState == .idle)
        store.handleEvent(BridgeEvent(bridgeEvent: "SessionStart", sessionId: "s2", cwd: "/b"))
        #expect(store.aggregateState == .working)
        let permission = PendingPermission(toolName: "Bash", toolInput: [:], cwd: "/b", responder: { _ in })
        store.handlePermissionRequest(sessionId: "s2", permission: permission)
        #expect(store.aggregateState == .waiting)
    }
}
