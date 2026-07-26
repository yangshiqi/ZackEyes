import Foundation
import Shared

#if canImport(Darwin)
import Darwin
#endif

// MARK: - SocketError

public enum SocketError: Error {
    case createFailed
    case bindFailed
    case listenFailed
}

// MARK: - SocketServer

@MainActor
public final class SocketServer {

    private let path: String
    private var serverFd: Int32 = -1
    private var isRunning = false
    /// The `UUID` is the blocking request's identity — minted here, alongside
    /// the responder that answers it, and echoed back by
    /// `onPermissionAbandoned` so the app can tell WHICH request died (#199).
    /// `nil` for non-blocking events, which have no responder either.
    private var onEvent: ((BridgeEvent, (@Sendable (BridgeResponse) -> Void)?, UUID?) -> Void)?
    private var onPermissionAbandoned: ((String, UUID) -> Void)?

    // MARK: - Init

    public init(path: String = SocketConfig.defaultPath) {
        self.path = path
    }

    /// Reject any peer whose effective uid differs from ours (scan findings
    /// F-001/F-002). On macOS, AF_UNIX socket file permissions are NOT enforced
    /// on connect, so a kernel-verified peer-credential check (`getpeereid`) is
    /// the reliable boundary that stops other local users from speaking the
    /// tool-authorization protocol. Same-uid processes are out of scope — a
    /// same-uid attacker already has full access to the user's session.
    nonisolated static func peerIsAuthorized(peerEUID: uid_t, ownEUID: uid_t) -> Bool {
        peerEUID == ownEUID
    }

    // MARK: - Public API

    public func setEventHandler(
        _ handler: @escaping @MainActor (BridgeEvent, (@Sendable (BridgeResponse) -> Void)?, UUID?) -> Void
    ) {
        self.onEvent = handler
    }

    /// Called when the bridge disconnects without a response (user answered in
    /// terminal, bridge timed out, etc.). Carries the request's id so only that
    /// request is dropped — a session may have others still waiting (#199).
    public func setPermissionAbandonedHandler(
        _ handler: @escaping @MainActor (String, UUID) -> Void
    ) {
        self.onPermissionAbandoned = handler
    }

    /// Unlink any stale socket, create AF_UNIX/SOCK_STREAM, bind, listen, then launch accept loop.
    public func start() throws {
        // Ensure the socket's parent dir exists and is owner-only (#136): the
        // socket now lives in ~/.zackeyes (0700) rather than world-writable /tmp
        // so another uid can't pre-bind / squat it.
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir)

        // Unlink stale socket file if present
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.createFailed }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: maxLen + 1) { buf in
                _ = path.withCString { strncpy(buf, $0, maxLen) }
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            throw SocketError.bindFailed
        }

        // F-002 defense in depth: restrict the socket node to the owner. BSD
        // does not enforce this on connect (the getpeereid check in acceptLoop
        // is the real gate), but it signals intent and helps on platforms that
        // do enforce socket-file permissions.
        _ = path.withCString { chmod($0, 0o600) }

        guard Darwin.listen(fd, 5) == 0 else {
            close(fd)
            throw SocketError.listenFailed
        }

        serverFd = fd
        isRunning = true

        Task { [weak self] in
            await self?.acceptLoop()
        }
    }

    /// Stop the server: close server fd and unlink the socket path.
    public func stop() {
        isRunning = false
        if serverFd >= 0 {
            close(serverFd)
            serverFd = -1
        }
        unlink(path)
    }

    // MARK: - Private

    private nonisolated func acceptLoop() async {
        while await MainActor.run(body: { isRunning }) {
            let sfd = await MainActor.run(body: { serverFd })
            guard sfd >= 0 else { break }

            let clientFd = Darwin.accept(sfd, nil, nil)
            guard clientFd >= 0 else {
                // accept failed — server may have been stopped
                continue
            }

            // F-001/F-002: authenticate the peer before processing anything.
            // Only this user may drive the tool-authorization protocol; reject
            // and close connections from any other local uid (or if creds are
            // unreadable). The legitimate bridge runs as the same user.
            var peerEUID = uid_t(0)
            var peerEGID = gid_t(0)
            guard getpeereid(clientFd, &peerEUID, &peerEGID) == 0,
                  Self.peerIsAuthorized(peerEUID: peerEUID, ownEUID: geteuid()) else {
                close(clientFd)
                continue
            }

            Task {
                await handleConnection(fd: clientFd)
            }
        }
    }

    private nonisolated func handleConnection(fd: Int32) async {
        // #129/F-019 — idle read timeout: the bridge writes its newline-delimited
        // payload immediately, so a peer that connects then stalls must not pin
        // this handler forever. read() returns <= 0 after the timeout → break.
        var rcvTimeout = timeval(tv_sec: 5, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &rcvTimeout,
                       socklen_t(MemoryLayout<timeval>.size))
        var accumulated = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while accumulated.count < 65536 {
            let bytesRead = read(fd, &buffer, buffer.count)
            if bytesRead <= 0 { break }
            accumulated.append(contentsOf: buffer[0..<bytesRead])
            if accumulated.contains(UInt8(ascii: "\n")) { break }
        }
        guard !accumulated.isEmpty else {
            close(fd)
            return
        }
        let data = accumulated

        let trimmedData = data.last == UInt8(ascii: "\n") ? data.dropLast() : data

        guard let event = try? JSONDecoder().decode(BridgeEvent.self, from: Data(trimmedData)) else {
            close(fd)
            return
        }

        if event.requiresBlockingResponse {
            // DO NOT close fd — the responder closure owns it
            let capturedFd = fd
            // This connection IS the request. Its id travels with the responder
            // so the app can answer or discard exactly this one (#199).
            let requestId = UUID()

            final class ResponseTracker: @unchecked Sendable {
                var completed = false
            }
            let tracker = ResponseTracker()

            let responder: @Sendable (BridgeResponse) -> Void = { response in
                defer { tracker.completed = true }
                guard let responseData = try? response.encoded() else {
                    close(capturedFd)
                    return
                }
                var payload = responseData
                payload.append(UInt8(ascii: "\n"))
                payload.withUnsafeBytes { ptr in
                    _ = write(capturedFd, ptr.baseAddress!, ptr.count)
                }
                close(capturedFd)  // Close AFTER writing response
            }
            await MainActor.run { [weak self] in
                self?.onEvent?(event, responder, requestId)
            }
            // Wait forever for either:
            //   1. User responded via ZackEyes (tracker.completed == true)
            //   2. The bridge disconnected — this happens either because the
            //      bridge timed out, OR because Claude Code killed the bridge
            //      when the user answered in the terminal instead of ZackEyes.
            //
            // No wall-clock ceiling: a permission prompt may legitimately sit
            // on screen for minutes while the user thinks. The bridge side
            // now also has no timeout (see BridgeLib/SocketClient.swift),
            // so both ends will wait as long as the user needs. If the task
            // itself is cancelled (app shutdown), Task.isCancelled breaks us
            // out cleanly.
            var bridgeDisconnected = false
            while !tracker.completed && !Task.isCancelled {
                var pfd = pollfd(fd: capturedFd, events: Int16(POLLHUP), revents: 0)
                if poll(&pfd, 1, 0) > 0 && (pfd.revents & Int16(POLLHUP)) != 0 {
                    bridgeDisconnected = true
                    break
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            // If responder was never called, close the fd ourselves
            if !tracker.completed { close(capturedFd) }
            // Notify that the permission was abandoned (user didn't click in ZackEyes)
            if !tracker.completed, let sid = event.sessionId {
                _ = bridgeDisconnected
                await MainActor.run { [weak self] in
                    self?.onPermissionAbandoned?(sid, requestId)
                }
            }
        } else {
            // Fire-and-forget: dispatch event, close immediately
            await MainActor.run { [weak self] in
                self?.onEvent?(event, nil, nil)
            }
            close(fd)
        }
    }
}
