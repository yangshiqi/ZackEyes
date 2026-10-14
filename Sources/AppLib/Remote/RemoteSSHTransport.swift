import Foundation
import RemoteCore

/// The manager owns cancellation and awaits teardown before replacing a connection.
public struct RemoteConnection: Sendable {
    public let snapshots: AsyncThrowingStream<RemoteSnapshot, Error>
    public let cancel: @Sendable () -> Void
    public let waitForExit: @Sendable () async -> Void
    public init(
        snapshots: AsyncThrowingStream<RemoteSnapshot, Error>,
        cancel: @escaping @Sendable () -> Void, waitForExit: @escaping @Sendable () async -> Void
    ) {
        self.snapshots = snapshots
        self.cancel = cancel
        self.waitForExit = waitForExit
    }
}

public struct RemoteSSHTransport: Sendable {
    let executable: URL
    let configuration: URL?
    let heartbeatTimeout: TimeInterval
    public init() {
        executable = URL(fileURLWithPath: "/usr/bin/ssh")
        configuration = nil
        heartbeatTimeout = 30
    }
    init(executable: URL, configuration: URL? = nil, heartbeatTimeout: TimeInterval = 30) {
        self.executable = executable
        self.configuration = configuration
        self.heartbeatTimeout = heartbeatTimeout
    }
    public static func arguments(for host: RemoteHost) throws -> [String] {
        try RemoteHostStore.validate([host])
        return [
            "-T", "-o", "BatchMode=yes", "-o", "PreferredAuthentications=publickey",
            "-o", "PasswordAuthentication=no", "-o", "KbdInteractiveAuthentication=no",
            "-o", "StrictHostKeyChecking=yes", "-o", "UpdateHostKeys=no",
            "-o", "ControlMaster=no", "-o", "ControlPath=none", "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3",
            host.destination, "exec \"$HOME/.local/bin/zackeyes\" --stream",
        ]
    }
    public func connect(_ host: RemoteHost) throws -> RemoteConnection {
        var arguments = try Self.arguments(for: host)
        if let configuration { arguments.insert(contentsOf: ["-F", configuration.path], at: 0) }
        return try OwnedSSHProcess(executable: executable, arguments: arguments, timeout: heartbeatTimeout).start()
    }
}

/// Blocking pipe I/O stays on dedicated queues; a lock protects cancellation,
/// heartbeat and exit waiters shared with the main-actor host manager.
private final class OwnedSSHProcess: @unchecked Sendable {
    private let process = Process()
    private let output = Pipe()
    private let errors = Pipe()
    private let input = Pipe()
    private let lock = NSLock()
    private var cancelled = false
    private var exited = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var lastFrame = Date()
    private var stderr = Data()
    private var timer: DispatchSourceTimer?
    private var continuation: AsyncThrowingStream<RemoteSnapshot, Error>.Continuation?
    private let timeout: TimeInterval
    init(executable: URL, arguments: [String], timeout: TimeInterval) {
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        self.timeout = timeout
    }
    func start() throws -> RemoteConnection {
        let stream = AsyncThrowingStream<RemoteSnapshot, Error>(bufferingPolicy: .bufferingNewest(1)) {
            continuation = $0
        }
        try process.run()
        try? input.fileHandleForWriting.close()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "zackeyes.ssh.heartbeat"))
        self.timer = timer
        timer.schedule(deadline: .now() + timeout, repeating: min(timeout, 5))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let stale = self.lock.withLock { Date().timeIntervalSince(self.lastFrame) >= self.timeout }
            if stale {
                self.continuation?.finish(throwing: RemoteHostError.disconnected("No SSH heartbeat. Retrying…"))
                self.cancel()
            }
        }
        timer.resume()
        let stderrDone = DispatchGroup()
        stderrDone.enter()
        DispatchQueue(label: "zackeyes.ssh.stderr").async { [self] in
            defer { stderrDone.leave() }
            while let data = try? Self.readAvailable(errors.fileHandleForReading.fileDescriptor), !data.isEmpty {
                lock.withLock { stderr.append(data.prefix(max(0, 65536 - stderr.count))) }
            }
        }
        DispatchQueue(label: "zackeyes.ssh.stdout").async { [self] in
            var framer = RemoteLineFramer()
            do {
                while true {
                    let data = try Self.readAvailable(output.fileHandleForReading.fileDescriptor)
                    if data.isEmpty { break }
                    for snapshot in try framer.push(data) {
                        lock.withLock { lastFrame = Date() }
                        continuation?.yield(snapshot)
                    }
                }
                try framer.finish()
            } catch {
                continuation?.finish(
                    throwing: RemoteHostError.disconnected("Invalid remote stream. Check the remote ZackEyes version."))
                cancel()
            }
            // EOF can precede process termination. Stop the owned child even
            // when a server closes stdout but keeps the SSH channel open.
            cancel()
            process.waitUntilExit()
            stderrDone.wait()
            timer.cancel()
            let message = lock.withLock { String(decoding: stderr, as: UTF8.self) }
            let reason: String
            if message.contains("Host key verification failed") || message.contains("REMOTE HOST IDENTIFICATION") {
                reason = "SSH host key is not trusted. Verify it in your terminal."
            } else if message.contains("Permission denied") {
                reason = "SSH key authentication failed. Check your key or SSH agent."
            } else if message.contains("No such file") || message.contains("not found") {
                reason = "Install the remote stream binary at ~/.local/bin/zackeyes."
            } else {
                reason = "SSH stream disconnected. Check the host and remote installation."
            }
            continuation?.finish(throwing: RemoteHostError.disconnected(reason))
            let pending = lock.withLock {
                exited = true
                let result = waiters
                waiters.removeAll()
                return result
            }
            for waiter in pending { waiter.resume() }
            try? output.fileHandleForReading.close()
            try? errors.fileHandleForReading.close()
        }
        return RemoteConnection(
            snapshots: stream, cancel: { [self] in cancel() },
            waitForExit: { [self] in
                await withCheckedContinuation { waiter in
                    let done = lock.withLock {
                        if exited { return true }
                        waiters.append(waiter)
                        return false
                    }
                    if done { waiter.resume() }
                }
            })
    }
    private static func readAvailable(_ fd: Int32) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 16384)
        while true {
            let count = read(fd, &bytes, bytes.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            return Data(bytes.prefix(count))
        }
    }
    func cancel() {
        let first = lock.withLock {
            if cancelled { return false }
            cancelled = true
            return true
        }
        guard first else { return }
        if process.isRunning { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [self] in
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }
}
