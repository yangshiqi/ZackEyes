import Foundation
import RemoteCore
import Testing

@testable import AppLib

@Suite(.serialized) struct RemoteTransportTests {
    func script(_ body: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("ssh-fixture")
        try Data(("#!/usr/bin/python3\n" + body).utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
    @Test func drainsStderrAndCancellationReapsOwnedChild() async throws {
        let frame = String(
            decoding: try RemoteFrameCodec.encode(RemoteSnapshot(observedAt: Date(), sessions: [])), as: UTF8.self)
        let executable = try script(
            "import sys,time\nsys.stderr.write('e'*200000);sys.stderr.flush()\nsys.stdout.write(\(String(reflecting: frame)));sys.stdout.flush()\ntime.sleep(60)\n"
        )
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let connection = try RemoteSSHTransport(executable: executable).connect(
            RemoteHost(name: "Test", destination: "test"))
        var iterator = connection.snapshots.makeAsyncIterator()
        let snapshot = try await iterator.next()
        #expect(snapshot?.sessions.isEmpty == true)
        let start = Date()
        connection.cancel()
        await connection.waitForExit()
        #expect(Date().timeIntervalSince(start) < 3)
    }
    @Test @MainActor func shutdownWaitsForTermResistantChild() async throws {
        let frame = String(
            decoding: try RemoteFrameCodec.encode(RemoteSnapshot(observedAt: Date(), sessions: [])), as: UTF8.self)
        let executable = try script(
            "import sys,time,signal,os\nsignal.signal(signal.SIGTERM,signal.SIG_IGN)\nopen(__file__+'.pid','w').write(str(os.getpid()))\nsys.stdout.write(\(String(reflecting: frame)));sys.stdout.flush()\ntime.sleep(60)\n"
        )
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let transport = RemoteSSHTransport(executable: executable)
        let manager = RemoteHostManager(
            sessionStore: SessionStore(),
            store: RemoteHostStore(url: executable.deletingLastPathComponent().appendingPathComponent("hosts.json")),
            connect: { try transport.connect($0) })
        defer { manager.stop() }
        try manager.saveHost(RemoteHost(name: "Test", destination: "test"))
        manager.start()
        for _ in 0..<1000 where manager.statuses.first?.phase != .connected {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(manager.statuses.first?.phase == .connected)
        let pid = try #require(Int32(String(contentsOfFile: executable.path + ".pid", encoding: .utf8)))
        let start = Date()
        await manager.shutdown()
        #expect(Date().timeIntervalSince(start) < 3)
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
    }
    @Test func staleHeartbeatAndMalformedFramesTerminateProcess() async throws {
        for invalid in [false, true] {
            let frame =
                invalid
                ? "not-json\n"
                : String(
                    decoding: try RemoteFrameCodec.encode(RemoteSnapshot(observedAt: Date(), sessions: [])),
                    as: UTF8.self)
            let executable = try script(
                "import sys,time\nsys.stdout.write(\(String(reflecting: frame)));sys.stdout.flush()\ntime.sleep(60)\n")
            defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
            let connection = try RemoteSSHTransport(executable: executable, heartbeatTimeout: 0.2).connect(
                RemoteHost(name: "Test", destination: "test"))
            var failed = false
            do { for try await _ in connection.snapshots {} } catch { failed = true }
            await connection.waitForExit()
            #expect(failed)
        }
    }
    @Test func configurationRejectsSpecialAndOversizedFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("hosts.json")
        let store = RemoteHostStore(url: url)
        try Data(repeating: 32, count: 65537).write(to: url)
        #expect(throws: (any Error).self) { try store.load() }
        try FileManager.default.removeItem(at: url)
        #expect(mkfifo(url.path, 0o600) == 0)
        #expect(throws: (any Error).self) { try store.load() }
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ZACKEYES_REMOTE_SSH_CONFIG"] != nil))
    func actualLinuxSSHStreamAndDisconnect() async throws {
        let config = try #require(ProcessInfo.processInfo.environment["ZACKEYES_REMOTE_SSH_CONFIG"])
        let connection = try RemoteSSHTransport(
            executable: URL(fileURLWithPath: "/usr/bin/ssh"),
            configuration: URL(fileURLWithPath: config)
        ).connect(RemoteHost(name: "Linux", destination: "zackeyes-fixture"))
        var iterator = connection.snapshots.makeAsyncIterator()
        let first = try #require(await iterator.next())
        let second = try #require(await iterator.next())
        #expect(first.sessions.first?.state == .waiting)
        #expect(second.sessions.first?.projectName == "RemoteProject")
        #expect(!String(decoding: try RemoteFrameCodec.encode(second), as: UTF8.self).contains("PRIVATE"))
        connection.cancel()
        await connection.waitForExit()
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ZACKEYES_REMOTE_SSH_CONFIG"] != nil))
    @MainActor func actualSSHManagerReconnectsAfterRemoteExitAndRemovesOwnedProcess() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = try #require(ProcessInfo.processInfo.environment["ZACKEYES_REMOTE_SSH_CONFIG"])
        let transport = RemoteSSHTransport(
            executable: URL(fileURLWithPath: "/usr/bin/ssh"), configuration: URL(fileURLWithPath: config))
        let store = SessionStore()
        let manager = RemoteHostManager(
            sessionStore: store, store: RemoteHostStore(url: root.appendingPathComponent("hosts.json")),
            connect: { try transport.connect($0) })
        defer { manager.stop() }
        let host = RemoteHost(name: "Linux", destination: "zackeyes-fixture")
        try manager.saveHost(host)
        var sawFailure = false
        manager.onChange = { if manager.statuses.first?.phase == .failed { sawFailure = true } }
        manager.start()
        for _ in 0..<200 where manager.statuses.first?.phase != .connected {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(store.sessions.count == 1)
        let killer = Process()
        killer.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        killer.arguments = ["docker", "exec", "zackeyes-261-ssh-test", "pkill", "-x", "zackeyes"]
        try killer.run()
        killer.waitUntilExit()
        #expect(killer.terminationStatus == 0)
        for _ in 0..<200 where !sawFailure || manager.statuses.first?.phase != .connected {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(sawFailure)
        #expect(manager.statuses.first?.phase == .connected)
        #expect(store.sessions.count == 1)
        try manager.removeHost(host.id)
        #expect(store.sessions.isEmpty)
        try await Task.sleep(for: .milliseconds(1500))
        let ps = Process()
        let pipe = Pipe()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-ax", "-o", "command="]
        ps.standardOutput = pipe
        try ps.run()
        let commands = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        ps.waitUntilExit()
        #expect(!commands.components(separatedBy: "\n").contains { $0.contains("/usr/bin/ssh -F " + config) })
    }

}

@MainActor struct RemoteReconnectTests {
    @Test func retriesAreCappedAndSuccessResetsBackoff() async throws {
        for sendsSnapshot in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let recorder = RetryRecorder()
            let manager = RemoteHostManager(
                sessionStore: SessionStore(), store: RemoteHostStore(url: root.appendingPathComponent("hosts.json")),
                connect: { _ in
                    let stream = AsyncThrowingStream<RemoteSnapshot, Error> { c in
                        if sendsSnapshot { c.yield(RemoteSnapshot(observedAt: Date(), sessions: [])) }
                        c.finish(throwing: RemoteHostError.disconnected("Dropped"))
                    }
                    return RemoteConnection(snapshots: stream, cancel: {}, waitForExit: {})
                },
                sleep: { delay in
                    recorder.record(delay)
                    if recorder.delays.count >= 7 { throw CancellationError() }
                    await Task.yield()
                })
            try manager.saveHost(RemoteHost(name: "Test", destination: "test"))
            manager.start()
            for _ in 0..<100 where recorder.delays.count < 7 { try await Task.sleep(for: .milliseconds(10)) }
            #expect(recorder.delays == (sendsSnapshot ? Array(repeating: 2.0, count: 7) : [2, 4, 8, 16, 32, 60, 60]))
            manager.stop()
        }
    }
    private final class RetryRecorder: @unchecked Sendable {
        let lock = NSLock()
        private var values: [TimeInterval] = []
        var delays: [TimeInterval] { lock.withLock { values } }
        func record(_ value: TimeInterval) { lock.withLock { values.append(value) } }
    }
}
