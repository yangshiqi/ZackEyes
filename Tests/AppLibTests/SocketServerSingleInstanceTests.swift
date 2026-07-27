import Testing
import Foundation
import Shared
@testable import AppLib

/// #205 — `start()` unlinked the socket path unconditionally, so a second
/// ZackEyes silently took the endpoint from the first. Hooks then reached
/// whichever process won the race, the loser kept an accept loop on a node
/// nothing could dial, and neither the user nor the health check had any sign of
/// it: the loser still showed a menu bar icon and a notch panel.
///
/// The guard is `flock`, which is arbitrated per PROCESS — so these drive a real
/// second process. An in-process test would re-enter the same lock and prove
/// nothing about the case that matters.
@MainActor
struct SocketServerSingleInstanceTests {

    private func tempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "/zackeyes-single-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Holds the lock from another process for as long as it is alive.
    ///
    /// Built with `/usr/bin/python3` rather than `flock(1)`, which stock macOS
    /// does not ship — a test that silently skips on the developer's machine is
    /// no test at all.
    private func spawnLockHolder(lockPath: String, seconds: Int = 30) throws -> Process {
        let program = """
        import fcntl, sys, time
        fd = open(sys.argv[1], 'a+')
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        sys.stderr.write('locked\\n'); sys.stderr.flush()
        time.sleep(float(sys.argv[2]))
        """
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        task.arguments = ["-c", program, lockPath, "\(seconds)"]
        let ready = Pipe()
        task.standardError = ready
        try task.run()
        // Wait for it to say it holds the lock, rather than guessing with sleep.
        _ = ready.fileHandleForReading.availableData
        return task
    }

    @Test func refusesToStartWhileAnotherProcessHoldsTheLock() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/s.sock"

        let holder = try spawnLockHolder(lockPath: path + ".lock")
        defer { holder.terminate() }

        #expect(throws: SocketError.alreadyRunning) {
            try SocketServer(path: path).start()
        }
    }

    /// The whole point of using a lock: a crashed instance leaves no claim
    /// behind, so the next launch must be able to start.
    @Test func startsAfterTheLockHolderDies() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/s.sock"
        let holder = try spawnLockHolder(lockPath: path + ".lock", seconds: 30)
        holder.terminate()
        holder.waitUntilExit()

        let server = SocketServer(path: path)
        #expect(throws: Never.self) { try server.start() }
        server.stop()
    }

    /// A socket node left on disk by a crash — with no live holder — must be
    /// reclaimed rather than blocking startup forever.
    @Test func reclaimsASocketNodeLeftBehindByACrash() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/s.sock"

        let stale = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: maxLen + 1) { buf in
                _ = path.withCString { strncpy(buf, $0, maxLen) }
            }
        }
        _ = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(stale, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        close(stale)
        #expect(FileManager.default.fileExists(atPath: path))

        let server = SocketServer(path: path)
        #expect(throws: Never.self) { try server.start() }
        server.stop()
    }

    @Test func startsNormallyWhenNothingIsThere() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let server = SocketServer(path: dir + "/s.sock")
        #expect(throws: Never.self) { try server.start() }
        server.stop()
    }
}
