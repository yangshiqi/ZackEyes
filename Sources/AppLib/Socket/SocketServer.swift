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
    private var onEvent: ((BridgeEvent, (@Sendable (PermissionResponse) -> Void)?) -> Void)?

    // MARK: - Init

    public init(path: String = "/tmp/zackeyes.sock") {
        self.path = path
    }

    // MARK: - Public API

    public func setEventHandler(
        _ handler: @escaping @MainActor (BridgeEvent, (@Sendable (PermissionResponse) -> Void)?) -> Void
    ) {
        self.onEvent = handler
    }

    /// Unlink any stale socket, create AF_UNIX/SOCK_STREAM, bind, listen, then launch accept loop.
    public func start() throws {
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

            Task {
                await handleConnection(fd: clientFd)
            }
        }
    }

    private nonisolated func handleConnection(fd: Int32) async {
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

        if event.bridgeEvent == "PermissionRequest" {
            // DO NOT close fd — the responder closure owns it
            let capturedFd = fd

            final class ResponseTracker: @unchecked Sendable {
                var completed = false
            }
            let tracker = ResponseTracker()

            let responder: @Sendable (PermissionResponse) -> Void = { response in
                defer { tracker.completed = true }
                guard let responseData = try? JSONEncoder().encode(response) else {
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
                self?.onEvent?(event, responder)
            }
            // Keep task alive while bridge waits (bridge timeout is 15s, we wait 20s max)
            for _ in 0..<200 {
                if tracker.completed { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            // If responder was never called, close the fd ourselves
            if !tracker.completed { close(capturedFd) }
        } else {
            // Fire-and-forget: dispatch event, close immediately
            await MainActor.run { [weak self] in
                self?.onEvent?(event, nil)
            }
            close(fd)
        }
    }
}
