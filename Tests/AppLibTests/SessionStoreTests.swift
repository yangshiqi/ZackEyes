import Testing
import Foundation
@testable import AppLib
import Shared

@MainActor
struct SessionStoreTests {

    // 1. Initial state is idle
    @Test func initialStateIsIdle() {
        let store = SessionStore()
        #expect(store.state == .idle)
        #expect(store.sessionId == nil)
        #expect(store.currentToolName == nil)
        #expect(store.pendingPermission == nil)
    }

    // 2. SessionStart sets working
    @Test func sessionStartSetsWorking() {
        let store = SessionStore()
        let event = BridgeEvent(bridgeEvent: "SessionStart", sessionId: "s1", cwd: "/tmp")
        store.handleEvent(event)
        #expect(store.state == .working)
        #expect(store.sessionId == "s1")
        #expect(store.cwd == "/tmp")
    }

    // 3. PreToolUse updates tool name
    @Test func preToolUseUpdatesToolName() {
        let store = SessionStore()
        store.handleEvent(BridgeEvent(bridgeEvent: "SessionStart", sessionId: "s1", cwd: "/tmp"))
        store.handleEvent(BridgeEvent(bridgeEvent: "PreToolUse", toolName: "Bash"))
        #expect(store.currentToolName == "Bash")
        #expect(store.state == .working)
    }

    // 4. PermissionRequest sets waiting
    @Test func permissionRequestSetsWaiting() {
        let store = SessionStore()
        let permission = PendingPermission(
            toolName: "Bash",
            toolInput: [:],
            cwd: "/tmp",
            responder: { _ in }
        )
        store.handlePermissionRequest(permission)
        #expect(store.state == .waiting)
        #expect(store.pendingPermission != nil)
    }

    // 5. resolvePermission(allow: true) returns to working
    @Test func resolvePermissionAllowReturnsToWorking() {
        let store = SessionStore()
        store.handleEvent(BridgeEvent(bridgeEvent: "SessionStart", sessionId: "s1", cwd: "/tmp"))
        let permission = PendingPermission(
            toolName: "Bash",
            toolInput: [:],
            cwd: "/tmp",
            responder: { _ in }
        )
        store.handlePermissionRequest(permission)
        store.resolvePermission(allow: true)
        #expect(store.state == .working)
        #expect(store.pendingPermission == nil)
    }

    // 6. SessionEnd resets to idle
    @Test func sessionEndResetsToIdle() {
        let store = SessionStore()
        store.handleEvent(BridgeEvent(bridgeEvent: "SessionStart", sessionId: "s1", cwd: "/tmp"))
        store.handleEvent(BridgeEvent(bridgeEvent: "SessionEnd"))
        #expect(store.state == .idle)
        #expect(store.sessionId == nil)
        #expect(store.cwd == nil)
    }

    // 7. Stop sets stopped
    @Test func stopSetsStopped() {
        let store = SessionStore()
        store.handleEvent(BridgeEvent(bridgeEvent: "Stop"))
        #expect(store.state == .stopped)
    }
}
