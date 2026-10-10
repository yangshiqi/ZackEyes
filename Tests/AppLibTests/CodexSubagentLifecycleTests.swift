import Testing
import Foundation
import Shared
@testable import AppLib

@MainActor
struct CodexSubagentLifecycleTests {
    @Test func childLifecycleDoesNotFinishParentOrCopyReply() {
        let store = SessionStore()
        store.handleEvent(BridgeEvent(bridgeEvent: "SessionStart", agent: .codex, sessionId: "parent"))
        store.sessions["parent"]?.lastAssistantMessage = "parent reply"
        store.handleEvent(BridgeEvent(bridgeEvent: "SubagentStart", agent: .codex, sessionId: "parent", agentId: "child", agentType: "worker"))
        #expect(store.sessions["parent"]?.activeSubagents.map(\.id) == ["child"])
        store.handleEvent(BridgeEvent(bridgeEvent: "SubagentStart", agent: .codex, sessionId: "parent", agentId: "child", agentType: "worker"))
        #expect(store.sessions["parent"]?.activeSubagents.count == 1)
        store.handleEvent(BridgeEvent(bridgeEvent: "SubagentStop", agent: .codex, sessionId: "parent", lastAssistantMessage: "child reply", agentId: "child"))
        #expect(store.sessions["parent"]?.activeSubagents.isEmpty == true)
        #expect(store.sessions["parent"]?.state == .working)
        #expect(store.sessions["parent"]?.lastAssistantMessage == "parent reply")
        #expect(store.sessions["child"] == nil)
    }

    @Test func childStartCanBootstrapParentAndMissingIdIsIgnored() {
        let store = SessionStore()
        store.handleEvent(BridgeEvent(bridgeEvent: "SubagentStart", agent: .codex, sessionId: "parent", cwd: "/tmp", agentId: "child"))
        #expect(store.sessions["parent"]?.agent == .codex)
        #expect(store.sessions["parent"]?.activeSubagents.count == 1)
        store.handleEvent(BridgeEvent(bridgeEvent: "SubagentStart", agent: .codex, sessionId: "parent"))
        #expect(store.sessions["parent"]?.activeSubagents.count == 1)
    }

    @Test func installerRegistersSubagentLifecycle() {
        #expect(CodexHookInstaller.hookEvents.contains("SubagentStart"))
        #expect(CodexHookInstaller.hookEvents.contains("SubagentStop"))
    }
}

@Test func spawnedRolloutsAreNotDiscoveredAsUserSessions() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let day = root.appendingPathComponent("2026/10/08")
    try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
    let child = day.appendingPathComponent("rollout-2026-10-08T00-00-00-11111111-1111-1111-1111-111111111111.jsonl")
    let user = day.appendingPathComponent("rollout-2026-10-08T00-00-00-22222222-2222-2222-2222-222222222222.jsonl")
    try #"{"type":"session_meta","payload":{"cwd":"/tmp","source":{"subagent":{"thread_spawn":{"parent_thread_id":"parent","depth":1,"agent_role":"worker"}}}}}"#.write(to: child, atomically: true, encoding: .utf8)
    try #"{"type":"session_meta","payload":{"cwd":"/tmp","source":"cli"}}"#.write(to: user, atomically: true, encoding: .utf8)
    let found = CodexJsonlTailer.discoverRecentRollouts(rootDir: root, cutoff: .distantPast)
    #expect(found.map(\.lastPathComponent) == [user.lastPathComponent])
    let scanner = SessionScanner(projectsDir: root.appendingPathComponent("absent"), codexSessionsDir: root)
    #expect(scanner.scan().map(\.id) == ["22222222-2222-2222-2222-222222222222"])
}

@Test func rootParentThreadMetadataAlsoFiltersSpawnedRollouts() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
    defer { try? FileManager.default.removeItem(at: file) }
    try #"{"type":"session_meta","payload":{"parent_thread_id":"parent","source":"cli"}}"#.write(to: file, atomically: true, encoding: .utf8)
    #expect(CodexJsonlTailer.parseSessionMetaParentThreadId(at: file) == "parent")
}
