import Testing
import Foundation
import Shared
@testable import AppLib

@MainActor
struct CodexLifecycleTests {
    @Test func interruptionEndsWorkAndReleasesApprovals() {
        let store = SessionStore()
        store.handleEvent(BridgeEvent(bridgeEvent: "SessionStart", agent: .codex, sessionId: "s"))
        store.handleEvent(BridgeEvent(bridgeEvent: "PreCompact", agent: .codex, sessionId: "s", trigger: "auto"))
        let answered = Box<BridgeResponse>()
        store.handlePermissionRequest(sessionId: "s", permission: PendingPermission(
            toolName: "Bash", toolInput: [:], cwd: nil, responder: { answered.value = $0 }), agent: .codex)
        store.handleEvent(BridgeEvent(bridgeEvent: "Interrupt", agent: .codex, sessionId: "s"))
        #expect(store.sessions["s"]?.state == .idle)
        #expect(store.sessions["s"]?.isToolRunning == false)
        #expect(store.sessions["s"]?.pendingPermissions.isEmpty == true)
        #expect(store.sessions["s"]?.isCompacting == false)
        #expect(answered.value != nil)
    }

    @Test func endingSessionReleasesOutstandingApprovals() {
        let store = SessionStore()
        let answered = Box<BridgeResponse>()
        store.handlePermissionRequest(sessionId: "s", permission: PendingPermission(
            toolName: "Bash", toolInput: [:], cwd: nil, responder: { answered.value = $0 }), agent: .codex)
        store.handleEvent(BridgeEvent(bridgeEvent: "SessionEnd", agent: .codex, sessionId: "s"))
        #expect(store.sessions["s"] == nil)
        #expect(answered.value != nil)
    }

    @Test func installsEndAndInterruptionWithShortTimeoutAndRestorableBackup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("hooks.json")
        let original = Data(#"{"theme":"keep","hooks":{"Interrupt":[{"hooks":[{"type":"command","command":"other-tool"}]}]}}"#.utf8)
        try original.write(to: url)
        let installer = CodexHookInstaller(hooksPath: url.path, bridgePath: "/test/zackeyes/bridge")
        try installer.installHooks()
        let doc = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(doc["theme"] as? String == "keep")
        let hooks = try #require(doc["hooks"] as? [String: [[String: Any]]])
        for event in ["SessionEnd", "Interrupt"] {
            let ours = hooks[event]?.compactMap { $0["hooks"] as? [[String: Any]] }.flatMap { $0 }.first { ($0["command"] as? String)?.contains("zackeyes") == true }
            #expect(ours?["timeout"] as? Int == 3)
            #expect((ours?["command"] as? String)?.contains("--agent codex") == true)
        }
        let backup = try #require(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("hooks.json.backup.") })
        #expect(try Data(contentsOf: backup) == original)
        // Restore the exact original fixture, as required for installer verification.
        try original.write(to: url)
        #expect(try Data(contentsOf: url) == original)
    }
}
