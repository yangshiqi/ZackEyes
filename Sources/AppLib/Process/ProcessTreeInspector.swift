import Darwin
import Foundation

/// Reads the live process tree (`sysctl KERN_PROC_ALL`) and per-process
/// listening TCP ports (`proc_pidfdinfo`) straight from the kernel (#81).
///
/// ## Why not `ps` / `lsof`
///
/// The issue originally specced `ps -ww -eo pid,ppid,command` plus
/// `lsof -i -P -n -sTCP:LISTEN`, copying abtop's recipe, and paid for it with
/// a hard "never poll this" constraint. Measured on this codebase's target OS,
/// resolving every live agent session costs:
///
/// | approach              | process table | LISTEN ports | subprocesses |
/// |-----------------------|---------------|--------------|--------------|
/// | `ps` + `lsof -i`      | ~116ms        | ~180ms       | 2 fork+exec  |
/// | syscalls (this file)  | ~1.4ms        | ~1.2ms       | 0            |
///
/// At ~3ms with no fork/exec, this rides the existing 60s liveness sweep
/// instead of needing a lazy-trigger + cache layer, which is a large net
/// reduction in moving parts.
///
/// ## Known blind spot
///
/// `proc_pidfdinfo` refuses to describe the file descriptors of hardened /
/// SIP-protected processes even when they share our uid — on a sample machine
/// that hid 2 of 21 system-wide listeners (both `ControlCenter`). This does not
/// affect us: we only ever walk an agent's own descendant subtree, and system
/// daemons are never descendants of a `claude` / `codex` process.
///
/// ## What this deliberately does not do
///
/// A dev server whose spawning shell has exited gets reparented to launchd and
/// is no longer a descendant of anything. Such "orphan" ports cannot be
/// attributed to a session by any pid-based method, so they are out of scope
/// rather than guessed at.
public enum ProcessTreeInspector {

    /// Upper bound on descendants returned for one root. Every returned pid
    /// costs an FD scan, so this caps worst-case work rather than expressing
    /// any real limit — genuine agent subtrees are dozens of processes.
    public static let defaultDescendantLimit = 512

    /// Upper bound on file descriptors inspected per process. Listening
    /// sockets are opened early in a server's life and therefore live at low
    /// descriptor numbers, so this truncates only pathological cases (a
    /// browser-sized FD table) that we would learn nothing from anyway.
    static let maxDescriptorsPerProcess = 4096

    // MARK: - Snapshot

    /// A point-in-time view of the `pid → ppid` links, pre-inverted into a
    /// child index so repeated tree walks over the same snapshot are cheap.
    ///
    /// One snapshot is taken per sweep and shared across every session, so N
    /// sessions cost one process-table read, not N.
    public struct Snapshot: Sendable {
        /// `pid → ppid`, exactly as the kernel reported it.
        public let parentOf: [Int32: Int32]
        /// `ppid → [pid]`, derived once at init.
        private let childrenOf: [Int32: [Int32]]

        /// Number of processes in the snapshot.
        public var count: Int { parentOf.count }

        public init(parentOf: [Int32: Int32]) {
            self.parentOf = parentOf
            var index: [Int32: [Int32]] = [:]
            index.reserveCapacity(parentOf.count)
            for (pid, ppid) in parentOf {
                // A self-parented pid would make itself its own child and spin
                // the walk below; drop the edge here so the invariant holds for
                // every consumer of the index.
                guard pid != ppid else { continue }
                index[ppid, default: []].append(pid)
            }
            self.childrenOf = index
        }

        /// Every process below `root`, breadth-first, excluding `root` itself.
        ///
        /// Pure function over the snapshot — no syscalls, so the interesting
        /// cases (branching, cycles, caps) are testable on synthetic tables.
        ///
        /// pid reuse can leave the kernel's ppid links genuinely cyclic, so the
        /// walk is `visited`-guarded; without it a loop spins forever.
        public func descendants(
            of root: Int32,
            limit: Int = ProcessTreeInspector.defaultDescendantLimit
        ) -> [Int32] {
            guard limit > 0 else { return [] }
            var found: [Int32] = []
            var visited: Set<Int32> = [root]
            var queue: [Int32] = [root]
            var head = 0

            while head < queue.count {
                let current = queue[head]
                head += 1
                for child in childrenOf[current] ?? [] {
                    guard visited.insert(child).inserted else { continue }
                    found.append(child)
                    if found.count >= limit { return found }
                    queue.append(child)
                }
            }
            return found
        }
    }

    // MARK: - Capture

    /// Read the whole process table in a single syscall. Returns nil when the
    /// kernel refuses to describe it at all — callers treat that as "no
    /// information this tick" and retry on the next one, never as "nothing is
    /// running".
    ///
    /// Uses `sysctl KERN_PROC_ALL`, the same source `ps` reads, rather than
    /// `proc_listpids` + `proc_pidinfo(PROC_PIDTBSDINFO)`. The latter needs
    /// same-uid or root per process and returns a short read otherwise — on a
    /// sample machine that hid 349 of 974 processes (36%), including
    /// `/usr/bin/login`, which is setuid root and sits in the ancestry of
    /// every terminal session. That fragmented the tree into islands. sysctl
    /// returns all 972 in one call, and costs less than the N-call version it
    /// replaces.
    public static func captureSnapshot() -> Snapshot? {
        guard let table = processTable() else { return nil }
        return Snapshot(parentOf: table)
    }

    /// `pid → ppid` for every process on the system. Nil on failure.
    private static func processTable() -> [Int32: Int32]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]

        var sizingBytes = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &sizingBytes, nil, 0) == 0,
              sizingBytes > 0
        else { return nil }

        // Processes can spawn between the sizing call and the fetch, which
        // would make the fetch fail with ENOMEM. Ask for headroom so the
        // common case needs only one attempt.
        let stride = MemoryLayout<kinfo_proc>.stride
        let capacity = sizingBytes / stride + 64
        var buffer = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
        var fetchedBytes = capacity * stride
        guard sysctl(&mib, UInt32(mib.count), &buffer, &fetchedBytes, nil, 0) == 0
        else { return nil }

        let count = min(fetchedBytes / stride, capacity)
        guard count > 0 else { return nil }

        var table: [Int32: Int32] = [:]
        table.reserveCapacity(count)
        for entry in buffer[0..<count] {
            let pid = entry.kp_proc.p_pid
            guard pid > 0 else { continue }
            table[pid] = entry.kp_eproc.e_ppid
        }
        return table.isEmpty ? nil : table
    }

    // MARK: - Listening ports

    /// TCP ports this single process is listening on, sorted and deduplicated.
    ///
    /// Returns an empty array for any failure — a dead pid, a process we may
    /// not inspect, or a kernel that declines. Callers cannot distinguish
    /// "no ports" from "could not tell", which is the intended contract: a
    /// missing badge is the correct rendering for both.
    public static func listeningPorts(pid: Int32) -> [Int] {
        guard pid > 0 else { return [] }

        let sizingBytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard sizingBytes > 0 else { return [] }

        let slots = min(
            Int(sizingBytes) / MemoryLayout<proc_fdinfo>.size,
            maxDescriptorsPerProcess
        )
        guard slots > 0 else { return [] }

        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: slots)
        let filledBytes = proc_pidinfo(
            pid, PROC_PIDLISTFDS, 0, &descriptors,
            Int32(slots * MemoryLayout<proc_fdinfo>.size)
        )
        guard filledBytes > 0 else { return [] }

        let filled = min(Int(filledBytes) / MemoryLayout<proc_fdinfo>.size, slots)
        var ports: Set<Int> = []
        for descriptor in descriptors[0..<filled]
        where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            if let port = listeningPort(pid: pid, fd: descriptor.proc_fd) {
                ports.insert(port)
            }
        }
        return ports.sorted()
    }

    /// The port `fd` is listening on, or nil if it is not a listening TCP socket.
    private static func listeningPort(pid: Int32, fd: Int32) -> Int? {
        var info = socket_fdinfo()
        let size = Int32(MemoryLayout<socket_fdinfo>.size)
        guard proc_pidfdinfo(pid, fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
              info.psi.soi_kind == Int32(SOCKINFO_TCP)
        else { return nil }

        // TSI_S_LISTEN. A bound-but-not-listening socket is a client that
        // happens to have picked a local port, not a server.
        guard info.psi.soi_proto.pri_tcp.tcpsi_state == 1 else { return nil }

        // insi_lport is stored in network byte order.
        let port = Int(UInt16(
            bigEndian: UInt16(truncatingIfNeeded:
                info.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport)
        ))
        return port > 0 ? port : nil
    }

    /// TCP ports listened on anywhere in the subtree rooted at `root`,
    /// including `root` itself — the answer to "what is this session holding
    /// open". Sorted and deduplicated.
    public static func listeningPorts(
        inTreeRootedAt root: Int32,
        snapshot: Snapshot,
        limit: Int = defaultDescendantLimit
    ) -> [Int] {
        var ports = Set(listeningPorts(pid: root))
        for pid in snapshot.descendants(of: root, limit: limit) {
            ports.formUnion(listeningPorts(pid: pid))
        }
        return ports.sorted()
    }
}
