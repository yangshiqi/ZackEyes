import Foundation

#if canImport(Darwin)
import Darwin
#endif

public struct BridgeSocketClient: Sendable {

    private let path: String

    public init(path: String) {
        self.path = path
    }

    // MARK: - Private helpers

    /// Creates a connected AF_UNIX/SOCK_STREAM socket.
    /// Returns a valid file descriptor on success, or -1 on any failure.
    private func connect() -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        // Copy path into the fixed-size sun_path char array
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
        guard path.utf8.count <= maxLen else {
            close(fd)
            return -1
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: maxLen + 1) { buf in
                _ = path.withCString { strncpy(buf, $0, maxLen) }
            }
        }

        let result = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard result == 0 else {
            close(fd)
            return -1
        }
        // Authenticate the SERVER peer: reject a socket owned by another uid (a
        // squatter on a shared host). Mirrors the server's getpeereid gate on the
        // client side, so the bridge never leaks the payload to — or accepts a
        // forged decision from — a different user's process (#136 / F-006).
        var peerEUID = uid_t(0)
        var peerEGID = gid_t(0)
        guard getpeereid(fd, &peerEUID, &peerEGID) == 0, peerEUID == geteuid() else {
            close(fd)
            return -1
        }
        return fd
    }

    // MARK: - Public API

    /// Connect, write all data, close. Returns true iff all bytes were written.
    @discardableResult
    public func sendFireAndForget(data: Data) -> Bool {
        let fd = connect()
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var totalWritten = 0
        let count = data.count
        let written: Bool = data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> Bool in
            guard let base = buf.baseAddress else { return false }
            while totalWritten < count {
                let n = write(fd, base.advanced(by: totalWritten), count - totalWritten)
                if n <= 0 { return false }
                totalWritten += n
            }
            return true
        }
        return written && totalWritten == count
    }

    /// Connect, write data, wait for response via poll(), read, close.
    /// Returns the response Data, or nil on any error, timeout, or peer disconnect.
    /// Pass `timeoutSeconds <= 0` to wait without a timeout.
    public func sendAndWaitForResponse(data: Data, timeoutSeconds: Int) -> Data? {
        let fd = connect()
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        // Write all data
        var totalWritten = 0
        let count = data.count
        let sendOK: Bool = data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> Bool in
            guard let base = buf.baseAddress else { return false }
            while totalWritten < count {
                let n = write(fd, base.advanced(by: totalWritten), count - totalWritten)
                if n <= 0 { return false }
                totalWritten += n
            }
            return true
        }
        guard sendOK else { return nil }

        // Wait for either a response or peer disconnect (POLLHUP).
        // poll() takes milliseconds; -1 means wait forever. Even though we
        // only request POLLIN, the kernel always reports POLLHUP/POLLERR/
        // POLLNVAL in revents when relevant — that's how peer-close wakes
        // us up early instead of stalling on the SO_RCVTIMEO budget.
        let pollTimeoutMs: Int32 = timeoutSeconds > 0 ? Int32(timeoutSeconds * 1000) : -1
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let pollResult = poll(&pfd, 1, pollTimeoutMs)
        guard pollResult > 0 else { return nil }
        guard (pfd.revents & Int16(POLLIN)) != 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: 65536)
        let n = read(fd, &buffer, buffer.count)
        return n > 0 ? Data(buffer[0..<n]) : nil
    }
}
