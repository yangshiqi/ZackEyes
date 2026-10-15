import Foundation
import RemoteCore
import Testing

@testable import AppLib

@MainActor struct RemoteSessionTests {
    @Test func remotePolicyUsesTheSameRiskClassificationAsLocalCodex() throws {
        let frame = Data("""
        {"version":1,"observed_at":"2026-10-15T08:00:00Z","truncated":false,"sessions":[
          {"id":"yolo","agent":"codex","state":"working","last_activity":"2026-10-15T08:00:00Z",
           "approval_policy":"never","sandbox_type":"danger-full-access","reasoning_effort":"high"}]}
        """.utf8)
        let store = SessionStore()
        let host = RemoteHost(name: "Remote", destination: "remote")
        try store.replaceRemoteSessions(host: host, snapshot: RemoteFrameCodec.decode(frame))
        let session = try #require(store.sessions.values.first)
        #expect(session.permissionRisk == .yolo)
        #expect(session.reasoningEffort == "high")
        #expect(session.pendingPermission == nil)
        #expect(session.claudePid == nil)
    }

    @Test func oldAndPartialPoliciesNeverInventARiskBadge() throws {
        let store = SessionStore()
        let host = RemoteHost(name: "Remote", destination: "remote")
        for policy in [
            RemoteSessionSnapshot(id: "s", agent: .codex, state: .working, lastActivity: Date()),
            RemoteSessionSnapshot(id: "s", agent: .codex, state: .working, lastActivity: Date(), approvalPolicy: "never"),
            RemoteSessionSnapshot(id: "s", agent: .codex, state: .working, lastActivity: Date(),
                                  approvalPolicy: "on-request", sandboxType: "workspace-write")
        ] {
            try store.replaceRemoteSessions(host: host, snapshot: RemoteSnapshot(observedAt: Date(), sessions: [policy]))
            #expect(store.sessions.values.first?.permissionRisk == nil)
        }
    }

    @Test func replacementIsHostScopedAndCannotAcquireLocalCapabilities() throws {
        let store = SessionStore()
        store.sessions["same"] = SessionInfo(id: "same", cwd: "/local")
        let first = RemoteHost(name: "First", destination: "first")
        let second = RemoteHost(name: "Second", destination: "second")
        let snapshot = RemoteSnapshot(
            observedAt: Date(),
            sessions: [
                RemoteSessionSnapshot(id: "same", agent: .claude, state: .waiting, cwd: "/local", lastActivity: Date()),
                RemoteSessionSnapshot(id: "same", agent: .codex, state: .unknown, cwd: "/local", lastActivity: Date()),
            ])
        try store.replaceRemoteSessions(host: first, snapshot: snapshot)
        try store.replaceRemoteSessions(host: second, snapshot: snapshot)
        #expect(store.sessions.count == 5)
        let remote = store.sessions.values.filter { $0.source == .remote }
        #expect(remote.count == 4)
        #expect(
            remote.allSatisfy {
                $0.pendingPermission == nil && $0.claudePid == nil && $0.transcriptPath == nil
                    && $0.lastUserPrompt == nil
            })
        #expect(SessionStore.portScanRoots(Array(remote)).isEmpty)
        #expect(GitStatusReader.scanCwds(Array(remote)).isEmpty)
        #expect(store.aggregateState == .waiting)
        try store.replaceRemoteSessions(host: first, snapshot: RemoteSnapshot(observedAt: Date(), sessions: []))
        #expect(store.sessions.count == 3)
        store.removeRemoteSessions(hostID: second.id)
        #expect(store.sessions.count == 1)
        #expect(store.sessions["same"]?.source == .live)
    }
    @Test func managerReplacesConnectionAndClearsCardsOnRemoval() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let channel = TestRemoteChannel()
        let store = SessionStore()
        let manager = RemoteHostManager(
            sessionStore: store,
            store: RemoteHostStore(url: root.appendingPathComponent("hosts.json")), connect: { _ in channel.open() })
        let host = RemoteHost(name: "Server", destination: "server")
        try manager.saveHost(host)
        manager.start()
        try await until { channel.opened == 1 }
        channel.send(
            RemoteSnapshot(
                observedAt: Date(),
                sessions: [RemoteSessionSnapshot(id: "s", agent: .codex, state: .working, lastActivity: Date())]))
        try await until { store.sessions.count == 1 }
        #expect(manager.statuses.first?.phase == .connected)
        var edited = host
        edited.name = "Renamed"
        try manager.saveHost(edited)
        try await until { channel.opened == 2 }
        #expect(channel.maximumActive == 1)
        try manager.removeHost(host.id)
        try await until { channel.active == 0 }
        #expect(store.sessions.isEmpty)
        #expect(manager.statuses.isEmpty)
        manager.stop()
    }
    @Test func connectionOnlyVisibilityAndRemoteWaitingText() {
        let model = NotchViewModel(sessionStore: SessionStore())
        let host = RemoteHost(name: "Server", destination: "server")
        model.remoteHosts = [RemoteHostStatus(host: host, phase: .connecting)]
        #expect(model.hasActivityForVisibility)
        model.remoteHosts = [RemoteHostStatus(host: host, phase: .connected)]
        #expect(!model.hasActivityForVisibility)
        model.remoteHosts = [RemoteHostStatus(host: host, phase: .failed, message: "Offline")]
        #expect(model.hasActivityForVisibility)
        #expect(model.canStartDemo)
        let snapshot = RemoteSnapshot(
            observedAt: Date(),
            sessions: [RemoteSessionSnapshot(id: "s", agent: .claude, state: .waiting, lastActivity: Date())])
        try? model.sessionStore.replaceRemoteSessions(host: host, snapshot: snapshot)
        #expect(!model.canStartDemo)
        #expect(model.statusText == "needs remote attention")
    }
    func until(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(predicate())
    }
}

private final class TestRemoteChannel: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<RemoteSnapshot, Error>.Continuation?
    private var opens = 0
    private var count = 0
    private var maximum = 0
    var opened: Int { lock.withLock { opens } }
    var active: Int { lock.withLock { count } }
    var maximumActive: Int { lock.withLock { maximum } }
    func open() -> RemoteConnection {
        let stream = AsyncThrowingStream<RemoteSnapshot, Error> { c in
            lock.withLock {
                continuation = c
                opens += 1
                count += 1
                maximum = max(maximum, count)
            }
        }
        let token = CancellationToken()
        return RemoteConnection(
            snapshots: stream,
            cancel: { [self] in
                if token.take() {
                    lock.withLock {
                        count -= 1
                        continuation?.finish()
                    }
                }
            }, waitForExit: {})
    }
    func send(_ snapshot: RemoteSnapshot) { lock.withLock { continuation?.yield(snapshot) } }
    private final class CancellationToken: @unchecked Sendable {
        let lock = NSLock()
        var used = false
        func take() -> Bool {
            lock.withLock {
                if used { return false }
                used = true
                return true
            }
        }
    }
}
