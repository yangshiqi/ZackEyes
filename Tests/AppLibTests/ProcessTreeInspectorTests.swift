import Testing
import Foundation
import Darwin
@testable import AppLib

/// #81 — downward process-tree walk + LISTEN port discovery.
///
/// The tree walk is a pure function over a `[pid: ppid]` map, so most of this
/// runs on synthetic tables with no real processes involved. The libproc calls
/// themselves are covered by binding a real listening socket inside the test
/// process and asserting we can see it on our own pid.
struct ProcessTreeInspectorTests {

    // MARK: - Pure tree walk

    @Test func descendantsWalksASimpleChain() {
        // 10 → 11 → 12
        let snap = ProcessTreeInspector.Snapshot(parentOf: [11: 10, 12: 11])
        #expect(Set(snap.descendants(of: 10)) == [11, 12])
    }

    @Test func descendantsCollectsEveryBranch() {
        //      10
        //     /  \
        //    11   12
        //    |
        //    13
        let snap = ProcessTreeInspector.Snapshot(
            parentOf: [11: 10, 12: 10, 13: 11]
        )
        #expect(Set(snap.descendants(of: 10)) == [11, 12, 13])
        #expect(Set(snap.descendants(of: 11)) == [13])
    }

    @Test func descendantsExcludesTheRootItself() {
        let snap = ProcessTreeInspector.Snapshot(parentOf: [11: 10])
        #expect(!snap.descendants(of: 10).contains(10))
    }

    @Test func descendantsOfALeafIsEmpty() {
        let snap = ProcessTreeInspector.Snapshot(parentOf: [11: 10])
        #expect(snap.descendants(of: 11).isEmpty)
    }

    @Test func descendantsOfAnUnknownPidIsEmpty() {
        let snap = ProcessTreeInspector.Snapshot(parentOf: [11: 10])
        #expect(snap.descendants(of: 99999).isEmpty)
    }

    /// pid reuse can make the kernel's ppid links form a loop. The walk must
    /// terminate rather than spin — this test hangs forever on a naive BFS.
    @Test func descendantsTerminatesOnACycle() {
        let snap = ProcessTreeInspector.Snapshot(parentOf: [11: 12, 12: 11])
        #expect(Set(snap.descendants(of: 11)) == [12])
    }

    /// A process whose ppid is itself is the degenerate one-node cycle.
    @Test func descendantsTerminatesOnASelfParent() {
        let snap = ProcessTreeInspector.Snapshot(parentOf: [11: 11])
        #expect(snap.descendants(of: 11).isEmpty)
    }

    /// The cap is a runaway guard, not a correctness knob — but it must be
    /// honoured, because every returned pid costs an FD scan downstream.
    @Test func descendantsRespectsTheLimit() {
        // 0 → 1 → 2 → ... → 99, a 99-deep chain under root 0.
        var table: [Int32: Int32] = [:]
        for i in Int32(1)...99 { table[i] = i - 1 }
        let snap = ProcessTreeInspector.Snapshot(parentOf: table)
        #expect(snap.descendants(of: 0).count == 99)
        #expect(snap.descendants(of: 0, limit: 10).count == 10)
    }

    @Test func emptyTableYieldsNoDescendants() {
        let snap = ProcessTreeInspector.Snapshot(parentOf: [:])
        #expect(snap.descendants(of: 1).isEmpty)
    }

    // MARK: - Real libproc snapshot

    @Test func snapshotSeesThisProcessAndItsParent() throws {
        let snap = try #require(ProcessTreeInspector.captureSnapshot())
        let me = getpid()
        // Our own parent link must be present and must match getppid().
        #expect(snap.parentOf[me] == getppid())
    }

    /// Everything is a descendant of launchd. If the downward walk works on
    /// real kernel data at all, it finds us from pid 1.
    @Test func realTreeFromLaunchdReachesThisProcess() throws {
        let snap = try #require(ProcessTreeInspector.captureSnapshot())
        let reachable = Set(snap.descendants(of: 1, limit: 100_000))
        #expect(reachable.contains(getpid()))
    }

    // MARK: - Real LISTEN port discovery

    /// Bind a real listening socket in this very process, then assert libproc
    /// reports it back for our own pid. This is the end-to-end proof that the
    /// socket decoding (kind, TCP state, byte order) is right.
    @Test func findsAListeningSocketOpenedByThisProcess() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        try #require(fd >= 0)
        defer { close(fd) }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0   // let the kernel pick a free port

        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        try #require(bound == 0)
        try #require(listen(fd, 1) == 0)

        // Read back the port the kernel assigned.
        var actual = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        try #require(named == 0)
        let expectedPort = Int(UInt16(bigEndian: actual.sin_port))
        try #require(expectedPort > 0)

        let ports = ProcessTreeInspector.listeningPorts(pid: getpid())
        #expect(ports.contains(expectedPort),
                "expected to see :\(expectedPort) on our own pid, got \(ports)")
    }

    /// A socket that is merely open — never `listen()`ed — is not a server and
    /// must not surface as one.
    @Test func ignoresANonListeningSocket() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        try #require(fd >= 0)
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0

        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        try #require(bound == 0)
        // deliberately no listen()

        var actual = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        let boundPort = Int(UInt16(bigEndian: actual.sin_port))

        let ports = ProcessTreeInspector.listeningPorts(pid: getpid())
        #expect(!ports.contains(boundPort))
    }

    /// Silent degradation: a pid that cannot exist must yield an empty list,
    /// never a crash and never a partial-garbage result.
    @Test func unknownPidYieldsNoPorts() {
        #expect(ProcessTreeInspector.listeningPorts(pid: 0).isEmpty)
        #expect(ProcessTreeInspector.listeningPorts(pid: -1).isEmpty)
        #expect(ProcessTreeInspector.listeningPorts(pid: Int32.max).isEmpty)
    }

    // MARK: - Combined tree → ports

    @Test func treePortsIncludeTheRootsOwnListeners() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        try #require(fd >= 0)
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        try #require(listen(fd, 1) == 0)

        var actual = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        let expectedPort = Int(UInt16(bigEndian: actual.sin_port))

        let snap = try #require(ProcessTreeInspector.captureSnapshot())
        let ports = ProcessTreeInspector.listeningPorts(inTreeRootedAt: getpid(), snapshot: snap)
        #expect(ports.contains(expectedPort))
    }

    @Test func treePortsAreSortedAndDeduplicated() throws {
        let snap = try #require(ProcessTreeInspector.captureSnapshot())
        let ports = ProcessTreeInspector.listeningPorts(inTreeRootedAt: 1, snapshot: snap)
        #expect(ports == ports.sorted())
        #expect(Set(ports).count == ports.count)
    }

    /// #81's acceptance criterion on real kernel data: given a root pid, find
    /// what is running underneath it. Spawns an actual child and asserts the
    /// downward walk sees it — the synthetic-table tests above cannot catch a
    /// snapshot that silently omits live processes, which is exactly the bug
    /// `PROC_PIDTBSDINFO` shipped with (it hid every root-owned process).
    @Test func findsARealChildProcessInTheTree() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer {
            child.terminate()
            child.waitUntilExit()
        }

        let snap = try #require(ProcessTreeInspector.captureSnapshot())
        let kids = snap.descendants(of: getpid())
        #expect(kids.contains(child.processIdentifier),
                "spawned child \(child.processIdentifier) missing from \(kids)")
    }
}
